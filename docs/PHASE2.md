# Phase 2: Discovery & Enrichment

Phase 2 reads `_meta/files.index` and creates derived metadata only. It does not modify source files and does not modify `_meta/files.index`.

## What Phase 2 Does
- Discovers all ancestor directories implied by indexed file paths.
- Computes directory-level signals:
  - `file_count`
  - `total_size_bytes`
  - `oldest_file_date`
  - `newest_file_date`
  - `mime_diversity`
- Identifies dot-directories and summarizes prevalence by full path and by dot-directory name.
- Writes deterministic reports under `_meta/phase2/`.

## What Phase 2 Does Not Do
- No classification labels.
- No lifecycle decisions.
- No deletion, move, quarantine, or deduplication.
- No filesystem mutation beyond writing Phase 2 report files.

## Run
```bash
bash phase2.sh
```

## Outputs
- `_meta/phase2/directories.all.tsv`
  - `directory_path|depth|is_dot_directory`
- `_meta/phase2/directory_stats.tsv`
  - `directory_path|file_count|total_size_bytes|oldest_file_date|newest_file_date|mime_diversity`
- `_meta/phase2/dot_directories.tsv`
  - `directory_path|depth|descendant_file_count|descendant_total_size_bytes|mime_diversity`
- `_meta/phase2/dot_directory_names.tsv`
  - `dot_directory_name|occurrence_count|aggregate_descendant_file_count|aggregate_descendant_total_size_bytes`
- `_meta/phase2/example_preview.txt`
  - first rows from each report for quick inspection.

All reports are stable-sorted with `LC_ALL=C` for reproducibility.
