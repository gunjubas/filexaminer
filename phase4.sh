#!/usr/bin/env bash
set -euo pipefail

# Phase 4: Decision Layer (dry-run only, no execution).

INDEX_FILE="_meta/files.index"
PHASE2_DIR="_meta/phase2"
PHASE3_DIR="_meta/phase3"
DIR_CLASS_FILE="$PHASE3_DIR/directory_classification.tsv"
FILE_CLASS_FILE="$PHASE3_DIR/file_classification.tsv"
RULES_FILE="config/phase4_policies.json"
OUT_DIR="_meta/phase4"

PROPOSED_ACTIONS_FILE="$OUT_DIR/proposed_actions.tsv"
ACTION_PLAN_JSONL="$OUT_DIR/action_plan.jsonl"
SUMMARY_FILE="$OUT_DIR/action_summary.tsv"
REVIEW_FILE="$OUT_DIR/review_required.tsv"
HUMAN_SUMMARY_FILE="$OUT_DIR/human_summary.md"
PREVIEW_FILE="$OUT_DIR/example_preview.txt"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PRESERVE_TSV="$TMP_DIR/preservation.tsv"
DIR_RULES_TSV="$TMP_DIR/directory_rules.tsv"
FILE_RULES_TSV="$TMP_DIR/file_rules.tsv"
PROTECTED_CLASSES_TSV="$TMP_DIR/protected_classes.tsv"
DIR_ACTIONS_RAW="$TMP_DIR/directory_actions.raw"
FILE_ACTIONS_RAW="$TMP_DIR/file_actions.raw"

echo "[*] Phase 4 starting (decision layer, dry-run only)"
date

for required in "$INDEX_FILE" "$PHASE2_DIR/directory_stats.tsv" "$DIR_CLASS_FILE" "$FILE_CLASS_FILE" "$RULES_FILE"; do
  if [[ ! -f "$required" ]]; then
    echo "[!] Missing required input: $required"
    echo "    Ensure Phases 1-3 completed first."
    exit 1
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "[!] jq is required to parse policy configuration: $RULES_FILE"
  exit 1
fi

mkdir -p "$OUT_DIR"

echo "[*] Loading decision policies..."
jq -r '.protected_classes[]' "$RULES_FILE" > "$PROTECTED_CLASSES_TSV"
jq -r '
  .preservation_policies[]
  | [
      .id,
      .scope,
      (.path_regex // ""),
      (.mime_regex // ""),
      .reason
    ] | @tsv
' "$RULES_FILE" > "$PRESERVE_TSV"
jq -r '
  .directory_decision_rules[]
  | [
      .id,
      .classification,
      .min_confidence,
      .action,
      (.priority|tostring),
      (.min_file_count // ""),
      (.min_total_size_bytes // ""),
      (.max_mime_diversity // ""),
      .reason
    ] | @tsv
' "$RULES_FILE" > "$DIR_RULES_TSV"
jq -r '
  .file_decision_rules[]
  | [
      .id,
      .classification,
      .min_confidence,
      .action,
      (.priority|tostring),
      (.path_regex // ""),
      (.mime_regex // ""),
      .reason
    ] | @tsv
' "$RULES_FILE" > "$FILE_RULES_TSV"

UNKNOWN_CLASS="$(jq -r '.defaults.unknown_class' "$RULES_FILE")"
UNKNOWN_ACTION="$(jq -r '.defaults.unknown_action' "$RULES_FILE")"
FALLBACK_ACTION="$(jq -r '.defaults.output_action_on_no_rule' "$RULES_FILE")"
DRY_RUN="$(jq -r '.defaults.dry_run' "$RULES_FILE")"
LOW_RANK="$(jq -r '.confidence_rank.low' "$RULES_FILE")"
MEDIUM_RANK="$(jq -r '.confidence_rank.medium' "$RULES_FILE")"
HIGH_RANK="$(jq -r '.confidence_rank.high' "$RULES_FILE")"

echo "[*] Proposing directory actions (dry-run)..."
awk -F'|' \
  -v OFS='|' \
  -v preserve_file="$PRESERVE_TSV" \
  -v rules_file="$DIR_RULES_TSV" \
  -v protected_file="$PROTECTED_CLASSES_TSV" \
  -v unknown_class="$UNKNOWN_CLASS" \
  -v unknown_action="$UNKNOWN_ACTION" \
  -v fallback_action="$FALLBACK_ACTION" \
  -v dry_run="$DRY_RUN" \
  -v low_rank="$LOW_RANK" \
  -v medium_rank="$MEDIUM_RANK" \
  -v high_rank="$HIGH_RANK" '
function confidence_rank(v) {
  if (v == "high") return high_rank + 0
  if (v == "medium") return medium_rank + 0
  return low_rank + 0
}
function is_protected_class(c) {
  return (c in protected_class) ? 1 : 0
}
function required_conf_rank(v) {
  if (v == "high") return high_rank + 0
  if (v == "medium") return medium_rank + 0
  return low_rank + 0
}
BEGIN {
  while ((getline line < protected_file) > 0) {
    protected_class[line] = 1
  }
  close(protected_file)

  while ((getline line < preserve_file) > 0) {
    split(line, a, "\t")
    pid[++pcount] = a[1]
    pscope[pcount] = a[2]
    ppath[pcount] = a[3]
    pmime[pcount] = a[4]
    preason[pcount] = a[5]
  }
  close(preserve_file)

  while ((getline line < rules_file) > 0) {
    split(line, a, "\t")
    rid[++rcount] = a[1]
    rclass[rcount] = a[2]
    rminc[rcount] = a[3]
    raction[rcount] = a[4]
    rpriority[rcount] = a[5] + 0
    rminf[rcount] = a[6]
    rminb[rcount] = a[7]
    rmaxm[rcount] = a[8]
    rreason[rcount] = a[9]
  }
  close(rules_file)

  print "scope|target_path|proposed_action|classification|confidence|matched_rule_id|explanation|preservation_override|review_required|dry_run|file_count|total_size_bytes|oldest_file_date|newest_file_date|mime_diversity"
}
NR == 1 { next }
{
  scope = "directory"
  path = $1
  class = $2
  confidence = $3
  file_count = $10 + 0
  total_size = $11 + 0
  oldest = $12
  newest = $13
  mime_div = $14 + 0

  action = fallback_action
  matched_rule = ""
  explanation = "no matching decision rule; defaulting to ignore"
  preservation_override = 0

  preserve_match_id = ""
  preserve_reason = ""
  for (i = 1; i <= pcount; i++) {
    if (pscope[i] != "directory" && pscope[i] != "all") continue
    if (ppath[i] != "" && path !~ ppath[i]) continue
    preservation_override = 1
    preserve_match_id = pid[i]
    preserve_reason = preason[i]
    break
  }

  if (class == unknown_class) {
    action = unknown_action
    matched_rule = "policy.unknown"
    explanation = "classification is unknown / mixed; no action proposed"
  } else if (preservation_override == 1) {
    action = "ignore"
    matched_rule = preserve_match_id
    explanation = "preservation policy override: " preserve_reason
  } else if (is_protected_class(class)) {
    action = "ignore"
    matched_rule = "policy.protected_class"
    explanation = "protected class (" class ") cannot be auto-deleted"
  } else {
    best_priority = -1
    best_rule = ""
    best_action = ""
    best_reason = ""
    for (i = 1; i <= rcount; i++) {
      if (rclass[i] != class) continue
      if (confidence_rank(confidence) < required_conf_rank(rminc[i])) continue
      if (rminf[i] != "" && file_count < (rminf[i] + 0)) continue
      if (rminb[i] != "" && total_size < (rminb[i] + 0)) continue
      if (rmaxm[i] != "" && mime_div > (rmaxm[i] + 0)) continue

      if (rpriority[i] > best_priority) {
        best_priority = rpriority[i]
        best_rule = rid[i]
        best_action = raction[i]
        best_reason = rreason[i]
      }
    }

    if (best_rule != "") {
      action = best_action
      matched_rule = best_rule
      explanation = best_reason
    }
  }

  # Safety guardrails.
  if (class == unknown_class) action = unknown_action
  if (is_protected_class(class) && action == "delete directory") {
    action = "ignore"
    matched_rule = "policy.protected_class"
    explanation = "protected class (" class ") cannot be auto-deleted"
  }

  review_required = 0
  if (action != "ignore" || confidence == "low" || class == unknown_class || preservation_override == 1) review_required = 1

  print scope, path, action, class, confidence, matched_rule, explanation, preservation_override, review_required, dry_run, file_count, total_size, oldest, newest, mime_div
}
' "$DIR_CLASS_FILE" > "$DIR_ACTIONS_RAW"

echo "[*] Proposing file actions (fallback, dry-run)..."
awk -F'|' \
  -v OFS='|' \
  -v preserve_file="$PRESERVE_TSV" \
  -v rules_file="$FILE_RULES_TSV" \
  -v protected_file="$PROTECTED_CLASSES_TSV" \
  -v unknown_class="$UNKNOWN_CLASS" \
  -v unknown_action="$UNKNOWN_ACTION" \
  -v fallback_action="$FALLBACK_ACTION" \
  -v dry_run="$DRY_RUN" \
  -v low_rank="$LOW_RANK" \
  -v medium_rank="$MEDIUM_RANK" \
  -v high_rank="$HIGH_RANK" '
function confidence_rank(v) {
  if (v == "high") return high_rank + 0
  if (v == "medium") return medium_rank + 0
  return low_rank + 0
}
function required_conf_rank(v) {
  if (v == "high") return high_rank + 0
  if (v == "medium") return medium_rank + 0
  return low_rank + 0
}
function is_protected_class(c) {
  return (c in protected_class) ? 1 : 0
}
BEGIN {
  while ((getline line < protected_file) > 0) {
    protected_class[line] = 1
  }
  close(protected_file)

  while ((getline line < preserve_file) > 0) {
    split(line, a, "\t")
    pid[++pcount] = a[1]
    pscope[pcount] = a[2]
    ppath[pcount] = a[3]
    pmime[pcount] = a[4]
    preason[pcount] = a[5]
  }
  close(preserve_file)

  while ((getline line < rules_file) > 0) {
    split(line, a, "\t")
    rid[++rcount] = a[1]
    rclass[rcount] = a[2]
    rminc[rcount] = a[3]
    raction[rcount] = a[4]
    rpriority[rcount] = a[5] + 0
    rpath[rcount] = a[6]
    rmime[rcount] = a[7]
    rreason[rcount] = a[8]
  }
  close(rules_file)

  print "scope|target_path|proposed_action|classification|confidence|matched_rule_id|explanation|preservation_override|review_required|dry_run|size_bytes|date|mime|parent_directory"
}
NR == 1 { next }
{
  scope = "file"
  path = $1
  parent = $2
  class = $3
  confidence = $4
  size = $11 + 0
  date = $12
  mime = $13

  action = fallback_action
  matched_rule = ""
  explanation = "no matching decision rule; defaulting to ignore"
  preservation_override = 0

  preserve_match_id = ""
  preserve_reason = ""
  for (i = 1; i <= pcount; i++) {
    if (pscope[i] != "file" && pscope[i] != "all") continue
    if (ppath[i] != "" && path !~ ppath[i]) continue
    if (pmime[i] != "" && mime !~ pmime[i]) continue
    preservation_override = 1
    preserve_match_id = pid[i]
    preserve_reason = preason[i]
    break
  }

  if (class == unknown_class) {
    action = unknown_action
    matched_rule = "policy.unknown"
    explanation = "classification is unknown / mixed; no action proposed"
  } else if (preservation_override == 1) {
    action = "ignore"
    matched_rule = preserve_match_id
    explanation = "preservation policy override: " preserve_reason
  } else if (is_protected_class(class)) {
    action = "ignore"
    matched_rule = "policy.protected_class"
    explanation = "protected class (" class ") cannot be auto-deleted"
  } else {
    best_priority = -1
    best_rule = ""
    best_action = ""
    best_reason = ""
    for (i = 1; i <= rcount; i++) {
      if (rclass[i] != class) continue
      if (confidence_rank(confidence) < required_conf_rank(rminc[i])) continue
      if (rpath[i] != "" && path !~ rpath[i]) continue
      if (rmime[i] != "" && mime !~ rmime[i]) continue

      if (rpriority[i] > best_priority) {
        best_priority = rpriority[i]
        best_rule = rid[i]
        best_action = raction[i]
        best_reason = rreason[i]
      }
    }

    if (best_rule != "") {
      action = best_action
      matched_rule = best_rule
      explanation = best_reason
    }
  }

  # Safety guardrails.
  if (class == unknown_class) action = unknown_action
  if (is_protected_class(class) && action == "delete directory") {
    action = "ignore"
    matched_rule = "policy.protected_class"
    explanation = "protected class (" class ") cannot be auto-deleted"
  }

  review_required = 0
  if (action != "ignore" || confidence == "low" || class == unknown_class || preservation_override == 1) review_required = 1

  print scope, path, action, class, confidence, matched_rule, explanation, preservation_override, review_required, dry_run, size, date, mime, parent
}
' "$FILE_CLASS_FILE" > "$FILE_ACTIONS_RAW"

echo "[*] Building combined action list..."
{
  echo "scope|target_path|proposed_action|classification|confidence|matched_rule_id|explanation|preservation_override|review_required|dry_run|evidence_size_bytes|evidence_date|evidence_mime|parent_directory|evidence_file_count|evidence_total_size_bytes|evidence_oldest_date|evidence_newest_date|evidence_mime_diversity"
  awk -F'|' -v OFS='|' '
    NR==1 { next }
    { print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,"","","","",$11,$12,$13,$14,$15 }
  ' "$DIR_ACTIONS_RAW"
  awk -F'|' -v OFS='|' '
    NR==1 { next }
    { print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,"","","","","" }
  ' "$FILE_ACTIONS_RAW"
} > "$PROPOSED_ACTIONS_FILE.tmp"

{
  awk 'NR==1 { print; next }' "$PROPOSED_ACTIONS_FILE.tmp"
  awk 'NR>1 { print }' "$PROPOSED_ACTIONS_FILE.tmp" | LC_ALL=C sort -t'|' -k1,1 -k2,2
} > "$PROPOSED_ACTIONS_FILE"
rm -f "$PROPOSED_ACTIONS_FILE.tmp"

echo "[*] Building machine-readable action plan..."
awk -F'|' '
NR==1 { next }
{
  print
}
' "$PROPOSED_ACTIONS_FILE" | jq -R -c '
  split("|")
  | {
      scope: .[0],
      target_path: .[1],
      proposed_action: .[2],
      classification: .[3],
      confidence: .[4],
      matched_rule_id: .[5],
      explanation: .[6],
      preservation_override: (.[7] == "1"),
      review_required: (.[8] == "1"),
      dry_run: (.[9] == "true"),
      evidence: {
        size_bytes: (if .[10] == "" then null else (.[10] | tonumber) end),
        date: (if .[11] == "" then null else .[11] end),
        mime: (if .[12] == "" then null else .[12] end),
        parent_directory: (if .[13] == "" then null else .[13] end),
        file_count: (if .[14] == "" then null else (.[14] | tonumber) end),
        total_size_bytes: (if .[15] == "" then null else (.[15] | tonumber) end),
        oldest_file_date: (if .[16] == "" then null else .[16] end),
        newest_file_date: (if .[17] == "" then null else .[17] end),
        mime_diversity: (if .[18] == "" then null else (.[18] | tonumber) end)
      }
    }
' > "$ACTION_PLAN_JSONL"

echo "[*] Building summaries..."
{
  echo "scope|proposed_action|classification|confidence|item_count"
  awk -F'|' '
  NR==1 { next }
  {
    key = $1 "|" $3 "|" $4 "|" $5
    count[key]++
  }
  END {
    for (k in count) {
      split(k, p, "|")
      print p[1] "|" p[2] "|" p[3] "|" p[4] "|" count[k]
    }
  }
  ' "$PROPOSED_ACTIONS_FILE" | LC_ALL=C sort -t'|' -k1,1 -k2,2 -k3,3 -k4,4
} > "$SUMMARY_FILE"

{
  echo "scope|target_path|proposed_action|classification|confidence|matched_rule_id|explanation"
  awk -F'|' '
  NR==1 { next }
  $9 == 1 { print $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7 }
  ' "$PROPOSED_ACTIONS_FILE" | LC_ALL=C sort -t'|' -k1,1 -k2,2
} > "$REVIEW_FILE"

{
  total_actions=$(awk -F'|' 'NR>1 {n++} END {print n+0}' "$PROPOSED_ACTIONS_FILE")
  non_ignore=$(awk -F'|' 'NR>1 && $3 != "ignore" {n++} END {print n+0}' "$PROPOSED_ACTIONS_FILE")
  review_count=$(awk -F'|' 'NR>1 && $9 == 1 {n++} END {print n+0}' "$PROPOSED_ACTIONS_FILE")

  echo "# Phase 4 Dry-Run Decision Summary"
  echo
  echo "- Total proposed items: $total_actions"
  echo "- Non-ignore proposals: $non_ignore"
  echo "- Review-required items: $review_count"
  echo
  echo "## Policy Guarantees"
  echo "- Dry-run only: no filesystem mutation performed."
  echo "- Unknown classification yields no action ($UNKNOWN_ACTION)."
  echo "- user content and identity / trust are protected from auto-delete."
  echo "- Preservation policies override all rule proposals."
  echo
  echo "## Top Proposed Actions (non-ignore)"
  awk -F'|' '
  NR==1 { next }
  $3 != "ignore" {
    print "- [" $1 "] " $2 " -> " $3 " (" $4 ", " $5 ", rule=" $6 ")"
    if (++shown >= 20) exit
  }
  ' "$PROPOSED_ACTIONS_FILE"
  echo
  echo "## Review Queue Sample"
  awk -F'|' '
  NR==1 { next }
  $9 == 1 {
    print "- [" $1 "] " $2 " :: " $7
    if (++shown >= 20) exit
  }
  ' "$PROPOSED_ACTIONS_FILE"
} > "$HUMAN_SUMMARY_FILE"

echo "[*] Writing preview..."
{
  echo "Phase 4 Example Preview"
  echo "======================="
  echo
  echo "[proposed_actions.tsv]"
  awk 'NR<=10' "$PROPOSED_ACTIONS_FILE"
  echo
  echo "[action_summary.tsv]"
  awk 'NR<=10' "$SUMMARY_FILE"
  echo
  echo "[review_required.tsv]"
  awk 'NR<=10' "$REVIEW_FILE"
  echo
  echo "[human_summary.md]"
  awk 'NR<=30' "$HUMAN_SUMMARY_FILE"
} > "$PREVIEW_FILE"

echo "[*] Phase 4 complete"
echo "    Outputs:"
echo "      - $PROPOSED_ACTIONS_FILE"
echo "      - $ACTION_PLAN_JSONL"
echo "      - $SUMMARY_FILE"
echo "      - $REVIEW_FILE"
echo "      - $HUMAN_SUMMARY_FILE"
echo "      - $PREVIEW_FILE"
date
