#!/usr/bin/env bash
set -euo pipefail

# Phase 2: Discovery & Enrichment (read-only).
# This phase consumes _meta/files.index and only writes derived reports.

INDEX_FILE="_meta/files.index"
OUT_DIR="_meta/phase2"

DIRS_RAW="$OUT_DIR/directories.raw"
DIRS_ALL="$OUT_DIR/directories.all.tsv"
DIR_STATS_RAW="$OUT_DIR/directory_stats.raw"
DIR_STATS="$OUT_DIR/directory_stats.tsv"
DOT_DIRS="$OUT_DIR/dot_directories.tsv"
DOT_NAMES="$OUT_DIR/dot_directory_names.tsv"
PREVIEW="$OUT_DIR/example_preview.txt"

echo "[*] Phase 2 starting (discovery + enrichment, read-only)"
date

if [[ ! -f "$INDEX_FILE" ]]; then
  echo "[!] Missing index: $INDEX_FILE"
  echo "    Run Phase 1 first."
  exit 1
fi

mkdir -p "$OUT_DIR"

echo "[*] Building directory inventory..."
awk -F'|' '
{
  path=$1
  n=split(path, parts, "/")
  dir=""
  for (i=2; i<n; i++) {
    dir = dir "/" parts[i]
    print dir
  }
}
' "$INDEX_FILE" | LC_ALL=C sort -u > "$DIRS_RAW"

{
  echo "directory_path|depth|is_dot_directory"
  awk -F'/' '
  BEGIN { OFS="|" }
  {
    depth = NF - 1
    is_dot = 0
    for (i=2; i<=NF; i++) {
      if (substr($i, 1, 1) == ".") {
        is_dot = 1
        break
      }
    }
    print $0, depth, is_dot
  }
  ' "$DIRS_RAW"
} > "$DIRS_ALL"

echo "[*] Aggregating directory statistics..."
awk -F'|' '
BEGIN { OFS="|" }
{
  path=$1
  size=$2 + 0
  date=$3
  mime=$4

  n=split(path, parts, "/")
  dir=""
  for (i=2; i<n; i++) {
    dir = dir "/" parts[i]

    file_count[dir]++
    total_size[dir] += size

    if (!(dir in oldest_date) || date < oldest_date[dir]) oldest_date[dir] = date
    if (!(dir in newest_date) || date > newest_date[dir]) newest_date[dir] = date

    key = dir SUBSEP mime
    if (!(key in seen_mime)) {
      seen_mime[key] = 1
      mime_diversity[dir]++
    }
  }
}
END {
  for (d in file_count) {
    print d, file_count[d], total_size[d], oldest_date[d], newest_date[d], mime_diversity[d] + 0
  }
}
' "$INDEX_FILE" | LC_ALL=C sort -t'|' -k1,1 > "$DIR_STATS_RAW"

{
  echo "directory_path|file_count|total_size_bytes|oldest_file_date|newest_file_date|mime_diversity"
  cat "$DIR_STATS_RAW"
} > "$DIR_STATS"

echo "[*] Extracting dot-directory prevalence..."
{
  echo "directory_path|depth|descendant_file_count|descendant_total_size_bytes|mime_diversity"
  awk -F'|' '
  NR==FNR {
    if (NR == 1) next
    is_dot[$1] = $3
    depth[$1] = $2
    next
  }
  FNR == 1 { next }
  {
    if (is_dot[$1] == 1) {
      print $1 "|" depth[$1] "|" $2 "|" $3 "|" $6
    }
  }
  ' "$DIRS_ALL" "$DIR_STATS"
} > "$DOT_DIRS.tmp"

{
  awk 'NR==1 { print; next }' "$DOT_DIRS.tmp"
  awk 'NR>1 { print }' "$DOT_DIRS.tmp" | LC_ALL=C sort -t'|' -k3,3nr -k1,1
} > "$DOT_DIRS"
rm -f "$DOT_DIRS.tmp"

{
  echo "dot_directory_name|occurrence_count|aggregate_descendant_file_count|aggregate_descendant_total_size_bytes"
  awk -F'|' '
  NR == 1 { next }
  {
    n = split($1, parts, "/")
    name = parts[n]
    occurrences[name]++
    agg_files[name] += $3
    agg_bytes[name] += $4
  }
  END {
    for (name in occurrences) {
      print name "|" occurrences[name] "|" agg_files[name] "|" agg_bytes[name]
    }
  }
  ' "$DOT_DIRS" | LC_ALL=C sort -t'|' -k2,2nr -k1,1
} > "$DOT_NAMES"

echo "[*] Writing example preview..."
{
  echo "Phase 2 Example Preview"
  echo "======================="
  echo
  echo "[directories.all.tsv]"
  awk 'NR<=6' "$DIRS_ALL"
  echo
  echo "[directory_stats.tsv]"
  awk 'NR<=6' "$DIR_STATS"
  echo
  echo "[dot_directories.tsv]"
  awk 'NR<=6' "$DOT_DIRS"
  echo
  echo "[dot_directory_names.tsv]"
  awk 'NR<=6' "$DOT_NAMES"
} > "$PREVIEW"

echo "[*] Phase 2 complete"
echo "    Outputs:"
echo "      - $DIRS_ALL"
echo "      - $DIR_STATS"
echo "      - $DOT_DIRS"
echo "      - $DOT_NAMES"
echo "      - $PREVIEW"
date
