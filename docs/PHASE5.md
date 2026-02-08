# Phase 5: Optional Action Execution

Phase 5 executes approved decisions from Phase 4. It is optional and disabled by default.

## Safety Model
- Execution is opt-in.
- Two explicit gates are required:
  1. pass `--execute`
  2. set `FILEXMINER_ENABLE_PHASE5=1`
- Only records with `.approved == true` are eligible.
- Records with `.dry_run == true` are never executed.
- Missing targets do not fail the run; they are logged as `missing_target`.

## Input
- Approved plan JSONL (default): `_meta/phase4/approved_action_plan.jsonl`

Each plan line should carry Phase 4 fields plus approval metadata, for example:
```json
{"scope":"directory","target_path":"/tmp/cache","proposed_action":"quarantine files","matched_rule_id":"dir_ephemeral_medium_conf_quarantine_candidate","classification":"ephemeral / regenerable","confidence":"medium","explanation":"...", "dry_run":false, "approved":true, "approved_by":"analyst", "approved_at":"2026-02-08T12:00:00Z", "approval_note":"ticket-123"}
```

## Run
- Dry-run simulation (default, no mutation):
```bash
bash phase5.sh --plan _meta/phase4/approved_action_plan.jsonl
```

- Execute approved actions:
```bash
FILEXMINER_ENABLE_PHASE5=1 bash phase5.sh --execute --plan _meta/phase4/approved_action_plan.jsonl
```

## Idempotency and Forensics
- Re-running the same plan is safe:
  - already moved/archived items are detected and logged.
  - missing targets are logged and skipped.
- Every record is logged with:
  - timestamp
  - source rule
  - classification/confidence
  - approval metadata
  - status/details
  - plan line hash for reconstruction

## Outputs
- Session artifacts are written under `_meta/phase5/sessions/<session_id>/`:
  - `actions.tsv`
  - `actions.jsonl`
  - `summary.tsv`
  - `summary.md`
  - `manifest.json`
- Data stores:
  - `_meta/phase5/quarantine_store/`
  - `_meta/phase5/archive_store/`
