#!/usr/bin/env bash
set -euo pipefail

# =========================
# Phase 1: File Inventory
# =========================

ROOT_DIR="."
META_DIR="_meta"

RAW_FILE="$META_DIR/files.raw"
MIME_FILE="$META_DIR/files.mime"
INDEX_FILE="$META_DIR/files.index"

echo "[*] Phase 1 starting"
date

mkdir -p "$META_DIR"

# -------------------------
# 1. Collect path | size | date
# -------------------------
echo "[*] Collecting file paths, sizes, dates..."

find "$ROOT_DIR" -type f -exec stat -c '%n|%s|%y' {} \; \
  | awk -F'|' '{print $1 "|" $2 "|" substr($3,1,10)}' \
  > "$RAW_FILE"

echo "[*] files.raw lines: $(wc -l < "$RAW_FILE")"

# -------------------------
# 2. Collect MIME types
# -------------------------
echo "[*] Collecting MIME types..."

cut -d'|' -f1 "$RAW_FILE" \
  | file --mime-type -f - \
  | sed 's/: /|/' \
  > "$MIME_FILE"

echo "[*] files.mime lines: $(wc -l < "$MIME_FILE")"

# -------------------------
# 3. Merge raw + mime safely
# -------------------------
echo "[*] Merging into index..."

awk -F'|' '
  NR==FNR {
    path[NR]=$1
    size[NR]=$2
    date[NR]=$3
    next
  }
  {
    mime=$NF
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", mime)
    print path[FNR] "|" size[FNR] "|" date[FNR] "|" mime
  }
' "$RAW_FILE" "$MIME_FILE" > "$INDEX_FILE"

# -------------------------
# 4. Verify structure
# -------------------------
echo "[*] Verifying index structure..."

FIELDS=$(awk -F'|' '{print NF}' "$INDEX_FILE" | sort | uniq)

if [ "$FIELDS" != "4" ]; then
  echo "[!] ERROR: Index does not have exactly 4 fields"
  exit 1
fi

echo "[*] files.index lines: $(wc -l < "$INDEX_FILE")"
echo "[*] Phase 1 complete"
date

