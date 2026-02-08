# filexaminer
Filexaminer is a forensic, policy-driven data governance system for large personal archives. It treats filesystems as evidence, not trash bins, and replaces ad-hoc cleanup with structured discovery, classification, and reversible action.

## Current workflow
- Phase 1 (`bash phase1.sh`): immutable inventory generation in `_meta/files.index`.
- Phase 2 (`bash phase2.sh`): read-only discovery and enrichment reports in `_meta/phase2/`.
- Phase 3 (`bash phase3.sh`): semantic classification reports only in `_meta/phase3/`.
- Phase 4 (`bash phase4.sh`): dry-run decision proposals only in `_meta/phase4/`.
- Phase 5 (`bash phase5.sh`): optional execution of approved plans with forensic logs in `_meta/phase5/`.

See `docs/PHASE2.md` for Phase 2 scope, guarantees, and report schemas.
See `docs/PHASE3.md` for Phase 3 classification rules, confidence model, and outputs.
See `docs/PHASE4.md` for decision policies, overrides, and dry-run plan outputs.
See `docs/PHASE5.md` for execution gating, approval format, idempotency, and audit logs.
