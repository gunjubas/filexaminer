#!/usr/bin/env bash
set -euo pipefail

# Phase 3: Semantic Classification (read-only, config-driven).
# Consumes immutable index + Phase 2 outputs and emits classifications only.

INDEX_FILE="_meta/files.index"
PHASE2_DIR="_meta/phase2"
DIR_STATS_FILE="$PHASE2_DIR/directory_stats.tsv"
DIRS_ALL_FILE="$PHASE2_DIR/directories.all.tsv"
RULES_FILE="config/phase3_rules.yaml"
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
DEFAULTS_TSV="$TMP_DIR/defaults.tsv"

echo "[*] Phase 3 starting (semantic classification, no actions)"
date

for required in "$INDEX_FILE" "$DIR_STATS_FILE" "$DIRS_ALL_FILE" "$RULES_FILE"; do
  if [[ ! -f "$required" ]]; then
    echo "[!] Missing required input: $required"
    echo "    Ensure Phase 1 and Phase 2 completed first."
    exit 1
  fi
done

if ! command -v yq >/dev/null 2>&1; then
  echo "[!] yq is required to parse YAML rules: $RULES_FILE"
  exit 1
fi

mkdir -p "$OUT_DIR"

echo "[*] Loading rule configuration..."
yq -r '.classes[]' "$RULES_FILE" > "$CLASSES_TSV"
{
  echo "unknown_class|$(yq -r '.defaults.unknown_class' "$RULES_FILE")"
  echo "directory_min_score|$(yq -r '.defaults.directory_min_score' "$RULES_FILE")"
  echo "file_min_score|$(yq -r '.defaults.file_min_score' "$RULES_FILE")"
  echo "medium_confidence_margin|$(yq -r '.defaults.medium_confidence_margin' "$RULES_FILE")"
  echo "high_confidence_score|$(yq -r '.defaults.high_confidence_score' "$RULES_FILE")"
  echo "high_confidence_margin|$(yq -r '.defaults.high_confidence_margin' "$RULES_FILE")"
} > "$DEFAULTS_TSV"

> "$DIR_RULES_TSV"
dir_rule_count="$(yq -r '.directory_rules | length' "$RULES_FILE")"
for ((i = 0; i < dir_rule_count; i++)); do
  rid="$(yq -r ".directory_rules[$i].id" "$RULES_FILE")"
  rclass="$(yq -r ".directory_rules[$i].class" "$RULES_FILE")"
  rweight="$(yq -r ".directory_rules[$i].weight" "$RULES_FILE")"
  rminf="$(yq -r ".directory_rules[$i].min_file_count // \"\"" "$RULES_FILE")"
  rmaxm="$(yq -r ".directory_rules[$i].max_mime_diversity // \"\"" "$RULES_FILE")"
  rdot="$(yq -r ".directory_rules[$i].requires_dot_directory // \"\"" "$RULES_FILE")"
  rreason="$(yq -r ".directory_rules[$i].reason" "$RULES_FILE")"

  rterms_csv=""
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    while IFS= read -r term; do
      [[ -z "$term" ]] && continue
      if [[ -z "$rterms_csv" ]]; then
        rterms_csv="$term"
      else
        rterms_csv="$rterms_csv,$term"
      fi
    done < <(yq -r ".directory_term_catalog[\"$ref\"][]?" "$RULES_FILE")
  done < <(yq -r ".directory_rules[$i].path_template_refs[]?" "$RULES_FILE")

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rid" "$rclass" "$rweight" "$rterms_csv" "$rminf" "$rmaxm" "$rdot" "$rreason" >> "$DIR_RULES_TSV"
done

> "$FILE_RULES_TSV"
file_rule_count="$(yq -r '.file_rules | length' "$RULES_FILE")"
for ((i = 0; i < file_rule_count; i++)); do
  rid="$(yq -r ".file_rules[$i].id" "$RULES_FILE")"
  rclass="$(yq -r ".file_rules[$i].class" "$RULES_FILE")"
  rweight="$(yq -r ".file_rules[$i].weight" "$RULES_FILE")"
  rreason="$(yq -r ".file_rules[$i].reason" "$RULES_FILE")"

  path_terms_csv=""
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    while IFS= read -r term; do
      [[ -z "$term" ]] && continue
      if [[ -z "$path_terms_csv" ]]; then
        path_terms_csv="$term"
      else
        path_terms_csv="$path_terms_csv,$term"
      fi
    done < <(yq -r ".file_path_term_catalog[\"$ref\"][]?" "$RULES_FILE")
  done < <(yq -r ".file_rules[$i].path_template_refs[]?" "$RULES_FILE")

  filename_terms_csv=""
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    while IFS= read -r term; do
      [[ -z "$term" ]] && continue
      if [[ -z "$filename_terms_csv" ]]; then
        filename_terms_csv="$term"
      else
        filename_terms_csv="$filename_terms_csv,$term"
      fi
    done < <(yq -r ".file_name_term_catalog[\"$ref\"][]?" "$RULES_FILE")
  done < <(yq -r ".file_rules[$i].filename_template_refs[]?" "$RULES_FILE")

  filename_suffix_csv=""
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    while IFS= read -r term; do
      [[ -z "$term" ]] && continue
      if [[ -z "$filename_suffix_csv" ]]; then
        filename_suffix_csv="$term"
      else
        filename_suffix_csv="$filename_suffix_csv,$term"
      fi
    done < <(yq -r ".file_suffix_catalog[\"$ref\"][]?" "$RULES_FILE")
  done < <(yq -r ".file_rules[$i].suffix_template_refs[]?" "$RULES_FILE")

  mime_prefix_csv="$(yq -r ".file_rules[$i].mime_prefixes // [] | join(\",\")" "$RULES_FILE")"
  mime_equals_csv="$(yq -r ".file_rules[$i].mime_equals // [] | join(\",\")" "$RULES_FILE")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rid" "$rclass" "$rweight" "$path_terms_csv" "$filename_terms_csv" "$filename_suffix_csv" "$mime_prefix_csv" "$mime_equals_csv" "$rreason" >> "$FILE_RULES_TSV"
done

UNKNOWN_CLASS="$(awk -F'|' '$1=="unknown_class"{print $2}' "$DEFAULTS_TSV")"
DIR_MIN_SCORE="$(awk -F'|' '$1=="directory_min_score"{print $2}' "$DEFAULTS_TSV")"
FILE_MIN_SCORE="$(awk -F'|' '$1=="file_min_score"{print $2}' "$DEFAULTS_TSV")"
MEDIUM_MARGIN="$(awk -F'|' '$1=="medium_confidence_margin"{print $2}' "$DEFAULTS_TSV")"
HIGH_SCORE="$(awk -F'|' '$1=="high_confidence_score"{print $2}' "$DEFAULTS_TSV")"
HIGH_MARGIN="$(awk -F'|' '$1=="high_confidence_margin"{print $2}' "$DEFAULTS_TSV")"

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
function csv_contains(haystack, csv,    n, i, parts, needle, h) {
  if (csv == "") return 1
  h = tolower(haystack)
  n = split(csv, parts, ",")
  for (i = 1; i <= n; i++) {
    needle = tolower(parts[i])
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", needle)
    if (needle != "" && index(h, needle) > 0) return 1
  }
  return 0
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
    rterms[rule_count] = a[4]
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

    if (!csv_contains(path, rterms[i])) ok = 0
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
function csv_contains(haystack, csv,    n, i, parts, needle, h) {
  if (csv == "") return 1
  h = tolower(haystack)
  n = split(csv, parts, ",")
  for (i = 1; i <= n; i++) {
    needle = tolower(parts[i])
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", needle)
    if (needle != "" && index(h, needle) > 0) return 1
  }
  return 0
}
function csv_suffix(haystack, csv,    n, i, parts, s, hlen, slen, h) {
  if (csv == "") return 1
  h = tolower(haystack)
  hlen = length(h)
  n = split(csv, parts, ",")
  for (i = 1; i <= n; i++) {
    s = tolower(parts[i])
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    if (s == "") continue
    slen = length(s)
    if (slen <= hlen && substr(h, hlen - slen + 1, slen) == s) return 1
  }
  return 0
}
function csv_prefix(haystack, csv,    n, i, parts, p, plen, h) {
  if (csv == "") return 1
  h = tolower(haystack)
  n = split(csv, parts, ",")
  for (i = 1; i <= n; i++) {
    p = tolower(parts[i])
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
    if (p == "") continue
    plen = length(p)
    if (substr(h, 1, plen) == p) return 1
  }
  return 0
}
function csv_exact(haystack, csv,    n, i, parts, e, h) {
  if (csv == "") return 1
  h = tolower(haystack)
  n = split(csv, parts, ",")
  for (i = 1; i <= n; i++) {
    e = tolower(parts[i])
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", e)
    if (e != "" && h == e) return 1
  }
  return 0
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
    rpath_terms[rule_count] = a[4]
    rfilename_terms[rule_count] = a[5]
    rfilename_suffixes[rule_count] = a[6]
    rmime_prefixes[rule_count] = a[7]
    rmime_equals[rule_count] = a[8]
    rreason[rule_count] = a[9]
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

    if (!csv_contains(path, rpath_terms[i])) ok = 0
    if (!csv_contains(path, rfilename_terms[i])) ok = 0
    if (!csv_suffix(path, rfilename_suffixes[i])) ok = 0
    if (!(csv_prefix(mime, rmime_prefixes[i]) || csv_exact(mime, rmime_equals[i]))) ok = 0

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
