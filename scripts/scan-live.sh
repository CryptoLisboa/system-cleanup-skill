#!/usr/bin/env bash
# scan-live.sh — live per-entry size scan. Read-only, deletes nothing.
#
# Prints each entry's size THE MOMENT it is measured, so a long walk is never
# indistinguishable from a hang. Ends with a ranked table + total.
#
#   bash scan-live.sh [path]          # default: $HOME
#   sudo bash scan-live.sh /Users/otheraccount     # other-uid dirs need root
#
# Why this exists: a monolithic `du -s` on a 100+ GB tree prints nothing for
# minutes. The user cannot tell working from wedged, and will kill it. Four
# parallel du workers + per-entry receipts fix that.

export LC_ALL=C   # locale-proof printf: comma-decimal locales reject %f args
set -u
BASE=${1:-$HOME}
PAR=4
WORK=$(mktemp -d "${TMPDIR:-/tmp}/scan-live.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
T0=$SECONDS

[ -d "$BASE" ] || { echo "FATAL: $BASE is not a directory"; exit 1; }

echo "════════════════════════════════════════════════════════════"
echo "  LIVE SCAN  $BASE   (read-only)"
echo "════════════════════════════════════════════════════════════"
echo

# ls -A, never a bare glob: a bare * hides every dotdir (see gotchas.md)
ls -A "$BASE" > "$WORK/entries" 2>/dev/null
TOTAL=$(wc -l < "$WORK/entries" | tr -d ' ')
echo "  $TOTAL entries to measure, $PAR at a time"
echo

: > "$WORK/results"
# FIFO pid throttle — macOS /bin/bash is 3.2, which has no `wait -n` (bash 4.3+).
# Waiting on the oldest pid keeps a true rolling window of $PAR workers.
pids=()
while IFS= read -r e; do
  (
    kb=$(du -sk "$BASE/$e" 2>/dev/null | awk '{print $1}')
    kb=${kb:-0}
    printf "%s\t%s\n" "$kb" "$e" >> "$WORK/results"
    awk -v kb="$kb" -v e="$e" 'BEGIN{printf "  %8.2f GB  %s\n", kb/1048576, e}'
  ) &
  pids+=($!)
  if [ "${#pids[@]}" -ge "$PAR" ]; then
    wait "${pids[0]}" 2>/dev/null
    pids=("${pids[@]:1}")
  fi
done < "$WORK/entries"
wait

echo
echo "════════════════ RANKED (largest first) ════════════════════"
# never awk '{print $2}' here — paths with spaces truncate (gotchas.md)
sort -rn "$WORK/results" | head -30 | awk -F'\t' '{
  if ($1/1048576 >= 0.01) printf "  %8.2f GB  %s\n", $1/1048576, $2
}'
echo
TOT=$(awk -F'\t' '{s+=$1} END{print s+0}' "$WORK/results")
awk -v t="$TOT" -v el="$((SECONDS-T0))" 'BEGIN{printf "  TOTAL: %.2f GB   (scanned in %ds)\n", t/1048576, el}'
echo "════════════════════════════════════════════════════════════"
if [ "$(id -u)" -ne 0 ]; then
  echo "  NOTE: run unprivileged, so this is a FLOOR, not a total —"
  echo "  du silently counts unreadable dirs as 0. Re-run under sudo"
  echo "  (or compare against System Settings > Storage) before trusting it."
fi
