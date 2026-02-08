#!/usr/bin/env bash
set -euo pipefail

INDEX="files.index"
OUT="dir_discovery"

mkdir -p "$OUT"

echo "[*] Phase 2-A: directory discovery started"
date

#######################################
# 1. Discover directories (all levels)
#######################################
echo "[*] Discovering directories..."

awk -F'|' '{print $1}' "$INDEX" \
 | awk -F'/' '
   {
     path=""
     for (i=2; i<NF; i++) {
       path = path "/" $i
       print path
     }
   }
 ' \
 | sort | uniq \
 > "$OUT/all_dirs.list"

echo "    Found $(wc -l < "$OUT/all_dirs.list") directories"

#######################################
# 2. Discover dot-directories (high risk / high value)
#######################################
echo "[*] Discovering dot-directories..."

awk -F'/' '
{
  for (i=1; i<=NF; i++) {
    if ($i ~ /^\./) print $i
  }
}' "$OUT/all_dirs.list" \
 | sort | uniq -c | sort -nr \
 > "$OUT/dot_dirs.freq"

#######################################
# 3. Aggregate signals per directory
#######################################
echo "[*] Aggregating directory signals..."

awk -F'|' '
{
  path=$1
  size=$2
  date=$3
  mime=$4

  split(path, p, "/")
  dir=""

  for (i=2; i<length(p); i++) {
    dir = dir "/" p[i]

    files[dir]++
    bytes[dir] += size

    if (!(dir in min_date) || date < min_date[dir]) min_date[dir] = date
    if (!(dir in max_date) || date > max_date[dir]) max_date[dir] = date

    mimes[dir][mime] = 1
  }
}
END {
  for (d in files) {
    mime_count = 0
    for (m in mimes[d]) mime_count++

    print d "|" files[d] "|" bytes[d] "|" min_date[d] "|" max_date[d] "|" mime_count
  }
}
' "$INDEX" \
 | sort -t'|' -k3 -nr \
 > "$OUT/dir_stats.tsv"

#######################################
# 4. Top offenders by size
#######################################
echo "[*] Extracting largest directories..."

head -n 50 "$OUT/dir_stats.tsv" > "$OUT/top_dirs_by_size.tsv"

#######################################
# 5. Candidate ephemeral directories (heuristic)
#######################################
echo "[*] Heuristic ephemeral candidates..."

grep -E '/\.cache/|/cache|node_modules|__pycache__|/\.mozilla/firefox' \
  "$OUT/dir_stats.tsv" \
  > "$OUT/ephemeral_candidates.tsv"

echo "[*] Phase 2-A complete"
date

