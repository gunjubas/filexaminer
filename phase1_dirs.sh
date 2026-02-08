#!/usr/bin/env bash
set -euo pipefail

# Legacy compatibility wrapper.
# Canonical Phase 2 entrypoint is phase2.sh.
echo "[*] phase1_dirs.sh is deprecated; delegating to phase2.sh"
exec "$(dirname "$0")/phase2.sh"
