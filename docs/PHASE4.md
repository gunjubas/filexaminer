# Phase 4: Decision Layer (Dry-Run Only)

Phase 4 converts enrichment and semantic classification into proposed actions only. It does not execute actions and does not mutate the filesystem.

## Inputs
- `_meta/files.index` (immutable evidence index)
- `_meta/phase2/directory_stats.tsv`
- `_meta/phase3/directory_classification.tsv`
- `_meta/phase3/file_classification.tsv`
- `config/phase4_policies.json` (decision and preservation policy)

## Guarantees
- Dry-run only.
- Unknown classification (`unknown / mixed`) always maps to `ignore`.
- Preservation policies override all action rules.
- `user content` and `identity / trust` are never auto-deleted.

## Action Types
Proposals may contain:
- `delete directory`
- `quarantine files`
- `archive data`
- `ignore`

No proposal is executed in Phase 4.

## Run
```bash
bash phase4.sh
```

## Outputs
All artifacts are written to `_meta/phase4/`:
- `proposed_actions.tsv`
  - unified, explainable proposal list with confidence, matched rule id, and evidence fields.
- `action_plan.jsonl`
  - machine-readable plan for downstream approval workflows.
- `action_summary.tsv`
  - grouped counts by scope, action, classification, confidence.
- `review_required.tsv`
  - items requiring human review.
- `human_summary.md`
  - concise narrative summary with policy guarantees and top items.
- `example_preview.txt`
  - first rows from key outputs for inspection.
