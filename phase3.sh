#!/usr/bin/env bash
set -euo pipefail

# Phase 3: Semantic Classification (read-only, config-driven).
# Consumes immutable index + Phase 2 outputs and emits classifications only.

INDEX_FILE="_meta/files.index"
PHASE2_DIR="_meta/phase2"
DIR_STATS_FILE="$PHASE2_DIR/directory_stats.tsv"
DIRS_ALL_FILE="$PHASE2_DIR/directories.all.tsv"
RULES_FILE="config/phase3_rules.json"
OUT_DIR="_meta/phase3"

DIR_CLASS_FILE="$OUT_DIR/directory_classification.tsv"
FILE_CLASS_FILE="$OUT_DIR/file_classification.tsv"
SUMMARY_FILE="$OUT_DIR/classification_summary.tsv"
REVIEW_FILE="$OUT_DIR/review_queue.tsv"
PREVIEW_FILE="$OUT_DIR/example_preview.txt"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CLASSES_TSV="$TMP_DIR/classes.tsv"
DIR_RULES_TSV="$TMP_DIR/dir_rules.tsv"
FILE_RULES_TSV="$TMP_DIR/file_rules.tsv"
DIR_CLASS_RAW="$TMP_DIR/directory_classification.raw"
FILE_CLASS_RAW="$TMP_DIR/file_classification.raw"
SUMMARY_RAW="$TMP_DIR/classification_summary.raw"
REVIEW_RAW="$TMP_DIR/review_queue.raw"

echo "[*] Phase 3 starting (semantic classification, no actions)"
date

for required in "$INDEX_FILE" "$DIR_STATS_FILE" "$DIRS_ALL_FILE" "$RULES_FILE"; do
  if [[ ! -f "$required" ]]; then
    echo "[!] Missing required input: $required"
    echo "    Ensure Phase 1 and Phase 2 completed first."
    exit 1
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "[!] jq is required to parse rule configuration: $RULES_FILE"
  exit 1
fi

mkdir -p "$OUT_DIR"

echo "[*] Loading rule configuration..."
jq -r '.classes[]' "$RULES_FILE" > "$CLASSES_TSV"
jq -r '
  .directory_rules[]
  | [
      .id,
      .class,
      (.weight|tostring),
      (.path_regex // ""),
      (.min_file_count // ""),
      (.max_mime_diversity // ""),
      (.requires_dot_directory // ""),
      .reason
    ] | @tsv
' "$RULES_FILE" > "$DIR_RULES_TSV"
jq -r '
  .file_rules[]
  | [
      .id,
      .class,
      (.weight|tostring),
      (.path_regex // ""),
      (.mime_regex // ""),
      .reason
    ] | @tsv
' "$RULES_FILE" > "$FILE_RULES_TSV"

UNKNOWN_CLASS="$(jq -r '.defaults.unknown_class' "$RULES_FILE")"
DIR_MIN_SCORE="$(jq -r '.defaults.directory_min_score' "$RULES_FILE")"
FILE_MIN_SCORE="$(jq -r '.defaults.file_min_score' "$RULES_FILE")"
MEDIUM_MARGIN="$(jq -r '.defaults.medium_confidence_margin' "$RULES_FILE")"
HIGH_SCORE="$(jq -r '.defaults.high_confidence_score' "$RULES_FILE")"
HIGH_MARGIN="$(jq -r '.defaults.high_confidence_margin' "$RULES_FILE")"

echo "[*] Directory-level classification..."
awk -F'|' \
  -v OFS='|' \
  -v class_file="$CLASSES_TSV" \
  -v rules_file="$DIR_RULES_TSV" \
  -v unknown_class="$UNKNOWN_CLASS" \
  -v min_score="$DIR_MIN_SCORE" \
  -v medium_margin="$MEDIUM_MARGIN" \
  -v high_score="$HIGH_SCORE" \
  -v high_margin="$HIGH_MARGIN" '
function append_value(base, value, sep,    out) {
  out = base
  if (value == "") return out
  if (out == "") return value
  return out sep value
}
BEGIN {
  while ((getline line < class_file) > 0) {
    class_name = line
    class_order[++class_count] = class_name
  }
  close(class_file)

  while ((getline line < rules_file) > 0) {
    split(line, a, "\t")
    rid[++rule_count] = a[1]
    rclass[rule_count] = a[2]
    rweight[rule_count] = a[3] + 0
    rpath[rule_count] = a[4]
    rminf[rule_count] = a[5]
    rmaxm[rule_count] = a[6]
    rdot[rule_count] = a[7]
    rreason[rule_count] = a[8]
  }
  close(rules_file)

  print "directory_path|classification|confidence|top_score|runner_up_score|score_margin|matched_rule_ids|explanation|review_required|file_count|total_size_bytes|oldest_file_date|newest_file_date|mime_diversity"
}
NR == FNR {
  if (FNR == 1) next
  is_dot[$1] = $3 + 0
  next
}
FNR == 1 { next }
{
  path = $1
  file_count = $2 + 0
  total_size = $3 + 0
  oldest = $4
  newest = $5
  mime_div = $6 + 0

  delete score
  delete matched_ids
  delete matched_reasons
  for (i = 1; i <= class_count; i++) {
    c = class_order[i]
    score[c] = 0
    matched_ids[c] = ""
    matched_reasons[c] = ""
  }

  for (i = 1; i <= rule_count; i++) {
    c = rclass[i]
    ok = 1

    if (rpath[i] != "" && path !~ rpath[i]) ok = 0
    if (rminf[i] != "" && file_count < (rminf[i] + 0)) ok = 0
    if (rmaxm[i] != "" && mime_div > (rmaxm[i] + 0)) ok = 0
    if (rdot[i] != "" && is_dot[path] != (rdot[i] + 0)) ok = 0

    if (ok) {
      score[c] += rweight[i]
      matched_ids[c] = append_value(matched_ids[c], rid[i], ",")
      matched_reasons[c] = append_value(matched_reasons[c], rreason[i], "; ")
    }
  }

  top_class = unknown_class
  top_score = -1
  second_score = -1
  tie_count = 0
  for (i = 1; i <= class_count; i++) {
    c = class_order[i]
    s = score[c] + 0
    if (s > top_score) {
      second_score = top_score
      top_score = s
      top_class = c
      tie_count = 1
    } else if (s == top_score) {
      tie_count++
    } else if (s > second_score) {
      second_score = s
    }
  }
  if (second_score < 0) second_score = 0
  margin = top_score - second_score

  final_class = unknown_class
  confidence = "low"
  explanation = ""

  if (top_score < min_score) {
    explanation = "insufficient evidence: top score below minimum threshold"
  } else if (tie_count > 1) {
    explanation = "insufficient certainty: score tie between classes"
  } else if (margin < medium_margin) {
    explanation = "insufficient certainty: low margin over runner-up class"
  } else {
    final_class = top_class
    if (top_score >= high_score && margin >= high_margin) {
      confidence = "high"
    } else {
      confidence = "medium"
    }
    explanation = matched_reasons[top_class]
  }

  if (final_class == unknown_class) {
    matched = ""
    review_required = 1
  } else {
    matched = matched_ids[top_class]
    review_required = (confidence == "low") ? 1 : 0
  }

  print path, final_class, confidence, top_score, second_score, margin, matched, explanation, review_required, file_count, total_size, oldest, newest, mime_div
}
' "$DIRS_ALL_FILE" "$DIR_STATS_FILE" > "$DIR_CLASS_RAW"

{
  awk 'NR==1 { print; next }' "$DIR_CLASS_RAW"
  awk 'NR>1 { print }' "$DIR_CLASS_RAW" | LC_ALL=C sort -t'|' -k1,1
} > "$DIR_CLASS_FILE"

echo "[*] File-level fallback classification for unknown directories..."
awk -F'|' \
  -v OFS='|' \
  -v dir_class_file="$DIR_CLASS_FILE" \
  -v class_file="$CLASSES_TSV" \
  -v rules_file="$FILE_RULES_TSV" \
  -v unknown_class="$UNKNOWN_CLASS" \
  -v min_score="$FILE_MIN_SCORE" \
  -v medium_margin="$MEDIUM_MARGIN" \
  -v high_score="$HIGH_SCORE" \
  -v high_margin="$HIGH_MARGIN" '
function append_value(base, value, sep,    out) {
  out = base
  if (value == "") return out
  if (out == "") return value
  return out sep value
}
function parent_dir(path,    n, parts, i, out) {
  n = split(path, parts, "/")
  out = ""
  for (i = 2; i < n; i++) out = out "/" parts[i]
  if (out == "") out = "/"
  return out
}
BEGIN {
  while ((getline line < dir_class_file) > 0) {
    if (line ~ /^directory_path\|/) continue
    split(line, a, "|")
    if (a[2] == unknown_class) unknown_dirs[a[1]] = 1
  }
  close(dir_class_file)

  while ((getline line < class_file) > 0) {
    class_order[++class_count] = line
  }
  close(class_file)

  while ((getline line < rules_file) > 0) {
    split(line, a, "\t")
    rid[++rule_count] = a[1]
    rclass[rule_count] = a[2]
    rweight[rule_count] = a[3] + 0
    rpath[rule_count] = a[4]
    rmime[rule_count] = a[5]
    rreason[rule_count] = a[6]
  }
  close(rules_file)

  print "file_path|parent_directory|classification|confidence|top_score|runner_up_score|score_margin|matched_rule_ids|explanation|review_required|size_bytes|date|mime"
}
{
  path = $1
  size = $2 + 0
  date = $3
  mime = $4
  pdir = parent_dir(path)

  if (!(pdir in unknown_dirs)) next

  delete score
  delete matched_ids
  delete matched_reasons
  for (i = 1; i <= class_count; i++) {
    c = class_order[i]
    score[c] = 0
    matched_ids[c] = ""
    matched_reasons[c] = ""
  }

  for (i = 1; i <= rule_count; i++) {
    c = rclass[i]
    ok = 1

    if (rpath[i] != "" && path !~ rpath[i]) ok = 0
    if (rmime[i] != "" && mime !~ rmime[i]) ok = 0

    if (ok) {
      score[c] += rweight[i]
      matched_ids[c] = append_value(matched_ids[c], rid[i], ",")
      matched_reasons[c] = append_value(matched_reasons[c], rreason[i], "; ")
    }
  }

  top_class = unknown_class
  top_score = -1
  second_score = -1
  tie_count = 0
  for (i = 1; i <= class_count; i++) {
    c = class_order[i]
    s = score[c] + 0
    if (s > top_score) {
      second_score = top_score
      top_score = s
      top_class = c
      tie_count = 1
    } else if (s == top_score) {
      tie_count++
    } else if (s > second_score) {
      second_score = s
    }
  }
  if (second_score < 0) second_score = 0
  margin = top_score - second_score

  final_class = unknown_class
  confidence = "low"
  explanation = ""

  if (top_score < min_score) {
    explanation = "insufficient evidence: top score below minimum threshold"
  } else if (tie_count > 1) {
    explanation = "insufficient certainty: score tie between classes"
  } else if (margin < medium_margin) {
    explanation = "insufficient certainty: low margin over runner-up class"
  } else {
    final_class = top_class
    if (top_score >= high_score && margin >= high_margin) {
      confidence = "high"
    } else {
      confidence = "medium"
    }
    explanation = matched_reasons[top_class]
  }

  if (final_class == unknown_class) {
    matched = ""
    review_required = 1
  } else {
    matched = matched_ids[top_class]
    review_required = (confidence == "low") ? 1 : 0
  }

  print path, pdir, final_class, confidence, top_score, second_score, margin, matched, explanation, review_required, size, date, mime
}
' "$INDEX_FILE" > "$FILE_CLASS_RAW"

{
  awk 'NR==1 { print; next }' "$FILE_CLASS_RAW"
  awk 'NR>1 { print }' "$FILE_CLASS_RAW" | LC_ALL=C sort -t'|' -k1,1
} > "$FILE_CLASS_FILE"

echo "[*] Building human-review summaries..."
awk -F'|' -v OFS='|' '
NR == 1 { next }
{
  key = "directory|" $2 "|" $3
  count[key]++
  bytes[key] += $11
}
END {
  print "scope|classification|confidence|item_count|aggregate_size_bytes"
  for (k in count) {
    split(k, p, "|")
    print p[1], p[2], p[3], count[k], bytes[k] + 0
  }
}
' "$DIR_CLASS_FILE" > "$SUMMARY_RAW"

awk -F'|' -v OFS='|' '
NR == 1 { next }
{
  key = "file_fallback|" $3 "|" $4
  count[key]++
  bytes[key] += $11
}
END {
  for (k in count) {
    split(k, p, "|")
    print p[1], p[2], p[3], count[k], bytes[k] + 0
  }
}
' "$FILE_CLASS_FILE" >> "$SUMMARY_RAW"

{
  awk 'NR==1 { print; next }' "$SUMMARY_RAW"
  awk 'NR>1 { print }' "$SUMMARY_RAW" | LC_ALL=C sort -t'|' -k1,1 -k2,2 -k3,3
} > "$SUMMARY_FILE"

{
  echo "scope|path|proposed_classification|confidence|explanation"
  awk -F'|' '
  NR == 1 { next }
  $9 == 1 { print "directory|" $1 "|" $2 "|" $3 "|" $8 }
  ' "$DIR_CLASS_FILE"
  awk -F'|' '
  NR == 1 { next }
  $10 == 1 { print "file_fallback|" $1 "|" $3 "|" $4 "|" $9 }
  ' "$FILE_CLASS_FILE"
} > "$REVIEW_RAW"

{
  awk 'NR==1 { print; next }' "$REVIEW_RAW"
  awk 'NR>1 { print }' "$REVIEW_RAW" | LC_ALL=C sort -t'|' -k1,1 -k2,2
} > "$REVIEW_FILE"

echo "[*] Writing example preview..."
{
  echo "Phase 3 Example Preview"
  echo "======================="
  echo
  echo "[directory_classification.tsv]"
  awk 'NR<=8' "$DIR_CLASS_FILE"
  echo
  echo "[file_classification.tsv]"
  awk 'NR<=8' "$FILE_CLASS_FILE"
  echo
  echo "[classification_summary.tsv]"
  awk 'NR<=8' "$SUMMARY_FILE"
  echo
  echo "[review_queue.tsv]"
  awk 'NR<=8' "$REVIEW_FILE"
} > "$PREVIEW_FILE"

echo "[*] Phase 3 complete"
echo "    Outputs:"
echo "      - $DIR_CLASS_FILE"
echo "      - $FILE_CLASS_FILE"
echo "      - $SUMMARY_FILE"
echo "      - $REVIEW_FILE"
echo "      - $PREVIEW_FILE"
date
