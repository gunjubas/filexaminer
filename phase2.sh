#!/usr/bin/env bash
set -euo pipefail

INDEX="_meta/files.index"
ACTIONS="_meta/actions"
QUARANTINE="99_QUARANTINE"

mkdir -p "$ACTIONS"
mkdir -p "$QUARANTINE"

echo "[*] Phase 2 cleanup started"
date

#######################################
# Helper: move with logging
#######################################
move_with_log() {
  local name="$1"
  local dest="$2"
  local filter_cmd="$3"

  local paths_file="$ACTIONS/${name}.paths"
  local moves_file="$ACTIONS/${name}.moves"

  mkdir -p "$QUARANTINE/$dest"

  echo "[*] Processing: $name"

  # Extract candidate paths
  eval "$filter_cmd" > "$paths_file"

  local count
  count=$(wc -l < "$paths_file" || echo 0)

  echo "    Found $count files"

  if [ "$count" -eq 0 ]; then
    echo "    Nothing to do"
    return
  fi

  # Move files
  cat "$paths_file" \
    | xargs -I{} mv "{}" "$QUARANTINE/$dest/"

  # Log moves
  awk -v d="$QUARANTINE/$dest" '{print $0 "|" d}' \
    "$paths_file" > "$moves_file"

  echo "    Moved and logged"
}

#######################################
# Phase 2.1 — Zero-size files
#######################################
move_with_log \
  "zero

