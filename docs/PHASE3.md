# Phase 3: Semantic Classification (No Actions)

Phase 3 consumes immutable evidence (`_meta/files.index`) plus Phase 2 discovery outputs and emits semantic classifications only.

## Scope
- Directory-first classification using explicit, weighted rules.
- File-level fallback only for directories that remain `unknown / mixed`.
- Confidence and explanations for every proposed classification.
- Human review queue for low-certainty outcomes.

## Non-Goals
- No delete/move/quarantine/deduplication.
- No lifecycle execution.
- No mutation of `_meta/files.index`.

## Rule Source
Rules are configuration-driven in `config/phase3_rules.yaml`:
- Classes:
  - `ephemeral / regenerable`
  - `derived but costly`
  - `user content`
  - `identity / trust`
  - `unknown / mixed`
- Thresholds and confidence policy live under `defaults`.
- Match logic is regex-free in the rule file: human-readable term lists are used for path terms, filename terms/suffixes, and MIME prefixes/exact values.
- Rule templates are organized as term catalogs and reused via YAML anchors for readability.

## Run
```bash
bash phase3.sh
```

## Outputs
All outputs are written under `_meta/phase3/`:
- `directory_classification.tsv`
  - directory-level class proposals, scores, confidence, matched rule ids, explanation.
- `file_classification.tsv`
  - fallback proposals for files inside unknown directories only.
- `classification_summary.tsv`
  - aggregate counts/bytes by scope, class, confidence.
- `review_queue.tsv`
  - items requiring human review (`unknown / mixed` or low certainty).
- `example_preview.txt`
  - first rows from each output for quick inspection.

If certainty is insufficient (low score, tie, or low margin), Phase 3 explicitly outputs `unknown / mixed`.
