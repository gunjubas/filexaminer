#!/usr/bin/env bash
set -euo pipefail

# Phase 5: Optional Action Execution.
# Executes approved decisions only when explicitly enabled.

PLAN_FILE="_meta/phase4/approved_action_plan.jsonl"
OUT_DIR="_meta/phase5"
QUARANTINE_ROOT="$OUT_DIR/quarantine_store"
ARCHIVE_ROOT="$OUT_DIR/archive_store"
SESSIONS_DIR="$OUT_DIR/sessions"

EXECUTE_MODE=0
SESSION_ID="$(date -u +%Y%m%dT%H%M%SZ)"
HOSTNAME_VALUE="$(hostname 2>/dev/null || echo unknown-host)"

usage() {
  cat <<'EOF'
Usage:
  bash phase5.sh [--plan PATH] [--session-id ID] [--execute]

Defaults:
  --plan _meta/phase4/approved_action_plan.jsonl
  mode: dry-run simulation (no filesystem mutation)

Execution guardrails:
  1) pass --execute
  2) set environment FILEXMINER_ENABLE_PHASE5=1

Only records with .approved == true are eligible for execution.
Records with .dry_run == true are never executed.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      PLAN_FILE="${2:?missing value for --plan}"
      shift 2
      ;;
    --session-id)
      SESSION_ID="${2:?missing value for --session-id}"
      shift 2
      ;;
    --execute)
      EXECUTE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[!] Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

echo "[*] Phase 5 starting (optional action execution)"
date
echo "    session: $SESSION_ID"
echo "    plan: $PLAN_FILE"

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "[!] Missing approved plan: $PLAN_FILE"
  echo "    Create it from Phase 4 action_plan.jsonl and mark approved items with .approved=true."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[!] jq is required."
  exit 1
fi

if [[ "$EXECUTE_MODE" -eq 1 && "${FILEXMINER_ENABLE_PHASE5:-0}" != "1" ]]; then
  echo "[!] Execution denied."
  echo "    To execute approved actions, set FILEXMINER_ENABLE_PHASE5=1 and pass --execute."
  exit 1
fi

MODE_LABEL="dry-run"
if [[ "$EXECUTE_MODE" -eq 1 ]]; then
  MODE_LABEL="execute"
fi

SESSION_DIR="$SESSIONS_DIR/$SESSION_ID"
mkdir -p "$OUT_DIR" "$SESSIONS_DIR" "$SESSION_DIR" "$QUARANTINE_ROOT" "$ARCHIVE_ROOT"

ACTIONS_TSV="$SESSION_DIR/actions.tsv"
ACTIONS_JSONL="$SESSION_DIR/actions.jsonl"
SUMMARY_TSV="$SESSION_DIR/summary.tsv"
SUMMARY_MD="$SESSION_DIR/summary.md"
MANIFEST_JSON="$SESSION_DIR/manifest.json"

echo "timestamp_utc|session_id|mode|plan_line|plan_line_sha256|approved|input_dry_run|scope|target_path|resolved_path|proposed_action|status|details|source_rule|classification|confidence|reason|approved_by|approved_at|approval_note" > "$ACTIONS_TSV"
: > "$ACTIONS_JSONL"

plan_hash="$(sha256sum "$PLAN_FILE" | awk '{print $1}')"

timestamp_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

to_local_path() {
  local target="$1"
  if [[ "$target" == ./* ]]; then
    printf '%s\n' "$target"
    return
  fi
  if [[ "$target" == /* ]]; then
    printf '.%s\n' "$target"
    return
  fi
  printf './%s\n' "$target"
}

to_rel_path() {
  local local_path="$1"
  local rel="$local_path"
  rel="${rel#./}"
  rel="${rel#/}"
  printf '%s\n' "$rel"
}

path_is_safe() {
  local p="$1"
  if [[ "$p" == *"/../"* || "$p" == ../* || "$p" == *"/.." || "$p" == ".." ]]; then
    return 1
  fi
  return 0
}

log_action() {
  local ts="$1"
  local plan_line="$2"
  local line_hash="$3"
  local approved="$4"
  local input_dry_run="$5"
  local scope="$6"
  local target_path="$7"
  local resolved_path="$8"
  local proposed_action="$9"
  local status="${10}"
  local details="${11}"
  local source_rule="${12}"
  local classification="${13}"
  local confidence="${14}"
  local reason="${15}"
  local approved_by="${16}"
  local approved_at="${17}"
  local approval_note="${18}"

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$ts" "$SESSION_ID" "$MODE_LABEL" "$plan_line" "$line_hash" "$approved" "$input_dry_run" "$scope" "$target_path" "$resolved_path" "$proposed_action" "$status" "$details" "$source_rule" "$classification" "$confidence" "$reason" "$approved_by" "$approved_at" "$approval_note" \
    >> "$ACTIONS_TSV"

  jq -n -c \
    --arg timestamp_utc "$ts" \
    --arg session_id "$SESSION_ID" \
    --arg mode "$MODE_LABEL" \
    --argjson plan_line "$plan_line" \
    --arg plan_line_sha256 "$line_hash" \
    --argjson approved "$approved" \
    --argjson input_dry_run "$input_dry_run" \
    --arg scope "$scope" \
    --arg target_path "$target_path" \
    --arg resolved_path "$resolved_path" \
    --arg proposed_action "$proposed_action" \
    --arg status "$status" \
    --arg details "$details" \
    --arg source_rule "$source_rule" \
    --arg classification "$classification" \
    --arg confidence "$confidence" \
    --arg reason "$reason" \
    --arg approved_by "$approved_by" \
    --arg approved_at "$approved_at" \
    --arg approval_note "$approval_note" \
    '{
      timestamp_utc,
      session_id,
      mode,
      plan_line,
      plan_line_sha256,
      approved,
      input_dry_run,
      scope,
      target_path,
      resolved_path,
      proposed_action,
      status,
      details,
      source_rule,
      classification,
      confidence,
      reason,
      approved_by,
      approved_at,
      approval_note
    }' >> "$ACTIONS_JSONL"
}

handle_ignore() {
  local local_path="$1"
  if [[ -e "$local_path" ]]; then
    printf 'ignored; target exists\n'
  else
    printf 'ignored; target missing\n'
  fi
}

handle_delete_directory() {
  local local_path="$1"

  if [[ ! -e "$local_path" ]]; then
    printf 'missing_target; nothing to delete\n'
    return
  fi
  if [[ ! -d "$local_path" ]]; then
    printf 'skipped_not_directory; target is not a directory\n'
    return
  fi
  if [[ "$EXECUTE_MODE" -eq 0 ]]; then
    printf 'would_delete_directory; dry-run simulation\n'
    return
  fi

  if rm -rf -- "$local_path"; then
    printf 'deleted_directory; directory removed\n'
  else
    printf 'error_delete_failed; rm failed\n'
  fi
}

handle_quarantine_file() {
  local local_path="$1"
  local rel="$2"
  local dest="$QUARANTINE_ROOT/$rel"

  if [[ ! -e "$local_path" ]]; then
    if [[ -e "$dest" ]]; then
      printf 'already_quarantined; source missing and destination exists (%s)\n' "$dest"
    else
      printf 'missing_target; source file not found\n'
    fi
    return
  fi
  if [[ -d "$local_path" ]]; then
    printf 'skipped_not_file; expected file for file-scope quarantine\n'
    return
  fi
  if [[ "$EXECUTE_MODE" -eq 0 ]]; then
    printf 'would_quarantine_file; dry-run simulation to %s\n' "$dest"
    return
  fi
  if [[ -e "$dest" ]]; then
    printf 'destination_exists; quarantine destination already exists (%s)\n' "$dest"
    return
  fi

  mkdir -p "$(dirname "$dest")"
  if mv -- "$local_path" "$dest"; then
    printf 'quarantined_file; moved to %s\n' "$dest"
  else
    printf 'error_quarantine_failed; mv failed\n'
  fi
}

handle_quarantine_directory() {
  local local_path="$1"

  if [[ ! -e "$local_path" ]]; then
    printf 'missing_target; source directory not found\n'
    return
  fi
  if [[ ! -d "$local_path" ]]; then
    printf 'skipped_not_directory; expected directory\n'
    return
  fi

  local moved=0
  local skipped=0
  local failures=0
  local -a files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$local_path" -type f -print0 2>/dev/null || true)

  if [[ "${#files[@]}" -eq 0 ]]; then
    printf 'already_quarantined_or_empty; no files found under directory\n'
    return
  fi

  local f rel dest
  for f in "${files[@]}"; do
    rel="$(to_rel_path "$f")"
    dest="$QUARANTINE_ROOT/$rel"

    if [[ "$EXECUTE_MODE" -eq 0 ]]; then
      ((moved+=1))
      continue
    fi

    if [[ -e "$dest" ]]; then
      ((skipped+=1))
      continue
    fi

    mkdir -p "$(dirname "$dest")"
    if mv -- "$f" "$dest"; then
      ((moved+=1))
    else
      ((failures+=1))
    fi
  done

  if [[ "$EXECUTE_MODE" -eq 0 ]]; then
    printf 'would_quarantine_directory; %d file(s) would be moved\n' "$moved"
    return
  fi

  if [[ "$failures" -gt 0 ]]; then
    printf 'partial_quarantine; moved=%d skipped_existing=%d failures=%d\n' "$moved" "$skipped" "$failures"
  else
    printf 'quarantined_directory; moved=%d skipped_existing=%d\n' "$moved" "$skipped"
  fi
}

handle_archive_file() {
  local local_path="$1"
  local rel="$2"
  local dest="$ARCHIVE_ROOT/$rel"

  if [[ ! -e "$local_path" ]]; then
    if [[ -e "$dest" ]]; then
      printf 'already_archived; source missing and archive copy exists (%s)\n' "$dest"
    else
      printf 'missing_target; source file not found\n'
    fi
    return
  fi
  if [[ -d "$local_path" ]]; then
    printf 'skipped_not_file; expected file for file-scope archive\n'
    return
  fi
  if [[ "$EXECUTE_MODE" -eq 0 ]]; then
    printf 'would_archive_file; dry-run simulation to %s\n' "$dest"
    return
  fi
  if [[ -e "$dest" ]]; then
    printf 'already_archived; destination exists (%s)\n' "$dest"
    return
  fi

  mkdir -p "$(dirname "$dest")"
  if cp -a -- "$local_path" "$dest"; then
    printf 'archived_file; copied to %s\n' "$dest"
  else
    printf 'error_archive_failed; cp failed\n'
  fi
}

handle_archive_directory() {
  local local_path="$1"
  local rel="$2"
  local slug
  slug="$(printf '%s' "$rel" | tr '/ ' '__')"
  if [[ -z "$slug" ]]; then
    slug="root"
  fi
  local hash
  hash="$(printf '%s' "$rel" | sha256sum | awk '{print $1}')"
  local dest="$ARCHIVE_ROOT/${slug}.${hash}.tar"

  if [[ ! -e "$local_path" ]]; then
    if [[ -e "$dest" ]]; then
      printf 'already_archived; source missing and archive exists (%s)\n' "$dest"
    else
      printf 'missing_target; source directory not found\n'
    fi
    return
  fi
  if [[ ! -d "$local_path" ]]; then
    printf 'skipped_not_directory; expected directory\n'
    return
  fi
  if [[ "$EXECUTE_MODE" -eq 0 ]]; then
    printf 'would_archive_directory; dry-run simulation to %s\n' "$dest"
    return
  fi
  if [[ -e "$dest" ]]; then
    printf 'already_archived; archive exists (%s)\n' "$dest"
    return
  fi

  mkdir -p "$(dirname "$dest")"
  if tar -cf "$dest" -- "$local_path"; then
    printf 'archived_directory; tar created at %s\n' "$dest"
  else
    printf 'error_archive_failed; tar failed\n'
  fi
}

echo "[*] Processing plan..."
line_no=0
processed=0
approved_count=0
executed_count=0

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  ((line_no+=1))
  if [[ -z "$raw_line" ]]; then
    continue
  fi

  if ! jq -e . >/dev/null 2>&1 <<<"$raw_line"; then
    ts="$(timestamp_utc)"
    line_hash="$(printf '%s' "$raw_line" | sha256sum | awk '{print $1}')"
    log_action "$ts" "$line_no" "$line_hash" "false" "false" "unknown" "" "" "ignore" "invalid_json" "invalid JSON line in plan file" "" "" "" "" "" "" ""
    continue
  fi

  parsed="$(jq -r '[.scope // "", .target_path // "", .proposed_action // "", .classification // "", .confidence // "", .matched_rule_id // "", .explanation // "", (.dry_run // false | tostring), (.approved // false | tostring), (.approved_by // ""), (.approved_at // ""), (.approval_note // "")] | @tsv' <<<"$raw_line")"
  IFS=$'\t' read -r scope target_path proposed_action classification confidence source_rule reason input_dry_run approved approved_by approved_at approval_note <<<"$parsed"

  ((processed+=1))
  line_hash="$(printf '%s' "$raw_line" | sha256sum | awk '{print $1}')"
  ts="$(timestamp_utc)"

  resolved_path="$(to_local_path "$target_path")"
  details=""
  status=""

  if [[ "$approved" != "true" ]]; then
    status="skipped_unapproved"
    details="record is not approved; only approved actions are eligible"
    log_action "$ts" "$line_no" "$line_hash" "$approved" "$input_dry_run" "$scope" "$target_path" "$resolved_path" "$proposed_action" "$status" "$details" "$source_rule" "$classification" "$confidence" "$reason" "$approved_by" "$approved_at" "$approval_note"
    continue
  fi

  ((approved_count+=1))

  if [[ "$input_dry_run" == "true" ]]; then
    status="skipped_plan_dry_run"
    details="plan item marked dry_run=true; execution not permitted"
    log_action "$ts" "$line_no" "$line_hash" "$approved" "$input_dry_run" "$scope" "$target_path" "$resolved_path" "$proposed_action" "$status" "$details" "$source_rule" "$classification" "$confidence" "$reason" "$approved_by" "$approved_at" "$approval_note"
    continue
  fi

  if ! path_is_safe "$resolved_path"; then
    status="skipped_unsafe_path"
    details="resolved path contains parent traversal segments"
    log_action "$ts" "$line_no" "$line_hash" "$approved" "$input_dry_run" "$scope" "$target_path" "$resolved_path" "$proposed_action" "$status" "$details" "$source_rule" "$classification" "$confidence" "$reason" "$approved_by" "$approved_at" "$approval_note"
    continue
  fi

  rel_path="$(to_rel_path "$resolved_path")"

  case "$proposed_action" in
    "ignore")
      details="$(handle_ignore "$resolved_path")"
      status="${details%%;*}"
      ;;
    "delete directory")
      details="$(handle_delete_directory "$resolved_path")"
      status="${details%%;*}"
      ;;
    "quarantine files")
      if [[ "$scope" == "file" ]]; then
        details="$(handle_quarantine_file "$resolved_path" "$rel_path")"
      else
        details="$(handle_quarantine_directory "$resolved_path")"
      fi
      status="${details%%;*}"
      ;;
    "archive data")
      if [[ "$scope" == "file" ]]; then
        details="$(handle_archive_file "$resolved_path" "$rel_path")"
      else
        details="$(handle_archive_directory "$resolved_path" "$rel_path")"
      fi
      status="${details%%;*}"
      ;;
    *)
      status="skipped_unknown_action"
      details="unrecognized proposed_action: $proposed_action"
      ;;
  esac

  if [[ "$EXECUTE_MODE" -eq 1 ]]; then
    case "$status" in
      deleted_directory|quarantined_file|quarantined_directory|archived_file|archived_directory|partial_quarantine)
        ((executed_count+=1))
        ;;
    esac
  fi

  log_action "$ts" "$line_no" "$line_hash" "$approved" "$input_dry_run" "$scope" "$target_path" "$resolved_path" "$proposed_action" "$status" "$details" "$source_rule" "$classification" "$confidence" "$reason" "$approved_by" "$approved_at" "$approval_note"
done < "$PLAN_FILE"

echo "[*] Building session summaries..."
{
  echo "mode|status|count"
  awk -F'|' '
  NR==1 { next }
  {
    key = $3 "|" $12
    count[key]++
  }
  END {
    for (k in count) {
      split(k, p, "|")
      print p[1] "|" p[2] "|" count[k]
    }
  }' "$ACTIONS_TSV" | LC_ALL=C sort -t'|' -k1,1 -k2,2
} > "$SUMMARY_TSV"

{
  echo "# Phase 5 Session Summary"
  echo
  echo "- Session: $SESSION_ID"
  echo "- Mode: $MODE_LABEL"
  echo "- Plan file: $PLAN_FILE"
  echo "- Plan SHA-256: $plan_hash"
  echo "- Processed records: $processed"
  echo "- Approved records: $approved_count"
  echo "- Mutating operations completed: $executed_count"
  echo
  echo "## Status Counts"
  awk -F'|' 'NR==1 {next} {print "- " $2 ": " $3}' "$SUMMARY_TSV"
  echo
  echo "## Forensic Artifacts"
  echo "- $ACTIONS_TSV"
  echo "- $ACTIONS_JSONL"
  echo "- $SUMMARY_TSV"
  echo "- $MANIFEST_JSON"
} > "$SUMMARY_MD"

jq -n \
  --arg phase "phase5" \
  --arg session_id "$SESSION_ID" \
  --arg mode "$MODE_LABEL" \
  --arg plan_file "$PLAN_FILE" \
  --arg plan_sha256 "$plan_hash" \
  --arg host "$HOSTNAME_VALUE" \
  --arg started_at_utc "$SESSION_ID" \
  --arg generated_at_utc "$(timestamp_utc)" \
  --arg actions_tsv "$ACTIONS_TSV" \
  --arg actions_jsonl "$ACTIONS_JSONL" \
  --arg summary_tsv "$SUMMARY_TSV" \
  --arg summary_md "$SUMMARY_MD" \
  --arg quarantine_root "$QUARANTINE_ROOT" \
  --arg archive_root "$ARCHIVE_ROOT" \
  --argjson processed_records "$processed" \
  --argjson approved_records "$approved_count" \
  --argjson executed_mutations "$executed_count" \
  '{
    phase,
    session_id,
    mode,
    host,
    plan_file,
    plan_sha256,
    processed_records,
    approved_records,
    executed_mutations,
    started_at_utc,
    generated_at_utc,
    artifacts: {
      actions_tsv,
      actions_jsonl,
      summary_tsv,
      summary_md
    },
    stores: {
      quarantine_root,
      archive_root
    }
  }' > "$MANIFEST_JSON"

echo "[*] Phase 5 complete"
echo "    mode: $MODE_LABEL"
echo "    outputs:"
echo "      - $ACTIONS_TSV"
echo "      - $ACTIONS_JSONL"
echo "      - $SUMMARY_TSV"
echo "      - $SUMMARY_MD"
echo "      - $MANIFEST_JSON"
date
