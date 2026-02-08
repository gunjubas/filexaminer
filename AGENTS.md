# Repository Guidelines

## Project Structure & Module Organization
This repository is a Bash-based pipeline for filesystem analysis and cleanup.
- `phase1.sh`: builds file inventory artifacts in `_meta/` (`files.raw`, `files.mime`, `files.index`).
- `phase2.sh`: canonical Phase 2 discovery/enrichment entrypoint; writes reports in `_meta/phase2/`.
- `phase1_dirs.sh`: legacy compatibility wrapper that delegates to `phase2.sh`.
- `README.md`: short project purpose statement.

Generated data directories (`_meta/`, `dir_discovery/`, `99_QUARANTINE/`) are runtime outputs, not source modules.

## Build, Test, and Development Commands
No build system is required; scripts run directly with Bash.
- `bash phase1.sh`: run file inventory from repository root.
- `bash phase2.sh`: run read-only discovery and enrichment (expects `_meta/files.index`).
- `bash phase1_dirs.sh`: legacy alias for `phase2.sh`.
- `bash -n phase1.sh phase1_dirs.sh phase2.sh`: syntax check before commit.
- `shellcheck phase1.sh phase1_dirs.sh phase2.sh`: static linting (install `shellcheck` if missing).

## Coding Style & Naming Conventions
- Use Bash with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Indent with 2 spaces inside functions and control blocks.
- Use uppercase variable names for global config (`ROOT_DIR`, `META_DIR`) and lowercase for locals.
- Keep pipeline outputs deterministic and delimiter-safe (`|`-separated records are current convention).
- Script names should be phase-oriented and descriptive, e.g. `phase3_report.sh`.

## Testing Guidelines
There is no formal test framework yet. Minimum validation for contributions:
- Run `bash -n` on changed scripts.
- Run `shellcheck` and resolve actionable warnings.
- Execute the affected phase end-to-end on a small sample tree and verify output files are created.
- For parsing logic, include at least one path containing spaces to catch quoting issues.

## Commit & Pull Request Guidelines
- Commit messages are short, imperative, and scoped (current pattern: `Initial commit`, `Add phase scripts`).
- Keep commits focused on one logical change.
- PRs should include:
  - what phase/script changed,
  - commands used for validation,
  - any data format or output-path changes,
  - sample output snippets when behavior changes.

## Security & Safety Notes
- Treat these scripts as potentially destructive when moving files.
- Prefer reversible actions (quarantine + move logs) over deletion.
- Never run cleanup phases on production/home data without a backup.
