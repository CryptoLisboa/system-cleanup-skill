#!/usr/bin/env bash
# purge-live.sh — parallel purge of regenerable dev artifacts, with live receipts.
#
#   bash purge-live.sh <root>                    # DRY-RUN: list targets + sizes
#   bash purge-live.sh <root> --execute          # delete, 4 workers, 3s heartbeat
#   bash purge-live.sh <root> --home <dir> ...   # also purge <dir>'s package caches
#   bash purge-live.sh self-test                 # assert every refusal still fires
#   ... --force                                  # override the running-server gate
#   sudo bash purge-live.sh /Users/other/dev --home /Users/other --execute
#
# Targets (Tier 0 only; marker-gated where the name is ambiguous — targets.md):
#   node_modules            always (regenerable by definition; the dry-run
#                           default is the consent step for the reinstall cost)
#   target/                 only beside Cargo.toml
#   dist/build/.next/.turbo/.anchor/.parcel-cache/.svelte-kit/out
#                           only beside package.json or Anchor.toml — and for
#                           out/dist/build, ONLY when there is no remotion
#                           config and no rendered media inside (a Remotion
#                           out/ is the finished deliverable: Tier 2)
#   --home adds: .npm/_cacache .nuget/packages .p2 .expo .yarn/cache
#                .yarn/berry/cache .gradle/caches .m2/repository
#                .bun/install/cache, the entries of .cache (minus model stores),
#                and an ALLOWLISTED set of Library/Caches names — NEVER the
#                whole dir. Spotify offline music and Playwright browsers live
#                in there; both Tier 1, both reported instead of deleted.
#
# NEVER touches: source, .git, Trash, Downloads, Documents, Desktop, Movies,
# Music, Pictures, Dropbox/CloudStorage, .ssh/.gnupg/.aws/.config/.claude,
# .nvm (working runtimes), Application Support, Keychains, Messages, Mail —
# enforced by safe_target() + DENY below, not by good intentions.
# `self-test` proves the refusals actually fire; run it after ANY edit here.
#
# Design rules this encodes (each learned the hard way — see gotchas.md):
#  - LC_ALL=C: comma-decimal locales make printf reject %f and lie in receipts
#  - the running-server check GATES (a guard that only prints once deleted a
#    live next-server's .next out from under it)
#  - heartbeat every 3s: a silent long delete is indistinguishable from a hang
#  - freed space measured by df delta, not summed du (hardlinks/clonefiles lie)
#  - APFS reclaims lazily: sleep before the final df, and say so if delta ~ 0
#  - every path passes safe_target() BEFORE it is queued; the workers only
#    ever see the validated queue and never compose paths themselves

export LC_ALL=C
set -u

ROOT="" ; HOMEBASE="" ; EXECUTE=0 ; FORCE=0 ; SELFTEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --execute) EXECUTE=1 ;;
    --force)   FORCE=1 ;;
    --home)    shift; HOMEBASE=${1:-} ;;
    self-test) SELFTEST=1 ;;
    *)         ROOT=$1 ;;
  esac
  shift
done
ROOT=${ROOT%/} ; HOMEBASE=${HOMEBASE%/}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/purge-live.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
TARGETS="$WORK/targets.txt"; : > "$TARGETS"
SKIPPED="$WORK/skipped.txt"; : > "$SKIPPED"

# ─────────────────────────────── guards ───────────────────────────────
DENY=()
build_deny() {   # derive the protected set for every home this run might touch
  local homes="" rh h
  [ -n "$HOMEBASE" ] && homes="$HOMEBASE"
  rh=$(printf '%s' "$ROOT" | sed -nE 's#^(/Users/[^/]+)(/.*)?$#\1#p')
  [ -n "$rh" ] && [ "$rh" != "$HOMEBASE" ] && homes="$homes $rh"
  DENY=()
  for h in $homes; do
    DENY+=(
      "$h/.Trash" "$h/Downloads" "$h/Documents" "$h/Desktop"
      "$h/Movies" "$h/Pictures" "$h/Music" "$h/Public" "$h/Dropbox"
      "$h/Library/CloudStorage" "$h/Library/Application Support"
      "$h/Library/Keychains" "$h/Library/Mobile Documents"
      "$h/Library/Messages" "$h/Library/Mail" "$h/Library/Photos"
      "$h/.ssh" "$h/.gnupg" "$h/.aws" "$h/.config" "$h/.claude" "$h/.nvm"
      "$h/Library/Developer/Xcode/Archives"
      "$h/Library/Developer/CoreSimulator/Devices"
      "$h/Library/Containers/com.docker.docker"
      "$h/Library/Caches/ms-playwright" "$h/Library/Caches/ms-playwright-go"
      "$h/Library/Caches/com.spotify.client"
      "$h/.cache/huggingface" "$h/.cache/torch"
    )
  done
}

safe_target() {  # validate BEFORE queueing; return 1 = refuse (reason on stdout)
  local p="$1" d n
  [ -n "$p" ] || { echo "REFUSE empty path"; return 1; }
  case "$p" in /*) ;; *) echo "REFUSE relative path: $p"; return 1 ;; esac
  case "$p" in *'*'*|*'?'*) echo "REFUSE unexpanded glob: $p"; return 1 ;; esac
  # depth >= 3 components kills /, /Users, /Users/<x>, and every volume root
  n=$(printf '%s' "$p" | awk -F/ '{c=0; for(i=1;i<=NF;i++) if($i!="") c++; print c}')
  [ "$n" -ge 3 ] || { echo "REFUSE too shallow: $p"; return 1; }
  if [ "$p" = "$ROOT" ] || { [ -n "$HOMEBASE" ] && [ "$p" = "$HOMEBASE" ]; }; then
    echo "REFUSE scan base itself: $p"; return 1
  fi
  local inside=1
  case "$p" in "$ROOT"/*) inside=0 ;; esac
  if [ -n "$HOMEBASE" ]; then case "$p" in "$HOMEBASE"/*) inside=0 ;; esac; fi
  [ "$inside" -eq 0 ] || { echo "REFUSE outside scan roots: $p"; return 1; }
  for d in ${DENY[@]+"${DENY[@]}"}; do
    case "$p" in "$d"|"$d"/*) echo "REFUSE denylist: $p"; return 1 ;; esac
  done
  return 0
}

# space-safe project-marker probe — an unquoted `for g in $pattern` word-splits
# on spaces and turns the guard into a no-op (gotchas.md)
has_file() { [ -n "$(find "$1" -maxdepth 1 -name "$2" -print -quit 2>/dev/null)" ]; }
# rendered deliverables are WORK PRODUCT, not build output
has_media() {
  [ -n "$(find "$1" -maxdepth 2 \
      \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.webm' -o -iname '*.gif' \
         -o -iname '*.mp3' -o -iname '*.wav' -o -iname '*.pdf' \) \
      -print -quit 2>/dev/null)" ]
}

add()  { echo "$1" >> "$TARGETS"; printf "\r  found %-6s %.70s\033[K" "$(wc -l < "$TARGETS" | tr -d ' ')" "$1"; }
skip() { printf 'SKIP  %s  — %s\n' "$2" "$1" >> "$SKIPPED"; }
try_add() {
  local why
  if why=$(safe_target "$1"); then add "$1"; else printf '%s\n' "$why" >> "$SKIPPED"; fi
}

# ───────────────────────────── self-test ─────────────────────────────
if [ "$SELFTEST" -eq 1 ]; then
  EXECUTE=0   # a failing assertion must never be able to delete anything
  F="$WORK/fixtures"; fails=0
  ROOT="$F/dev" ; HOMEBASE="$F/home"
  mkdir -p "$ROOT/webapp/dist" "$ROOT/webapp/node_modules" \
           "$ROOT/video/out" "$ROOT/render/out" \
           "$HOMEBASE/.Trash" "$HOMEBASE/Downloads" "$HOMEBASE/Documents" \
           "$HOMEBASE/Library/Application Support/Google" \
           "$HOMEBASE/Library/Keychains" \
           "$HOMEBASE/Library/Caches/ms-playwright" \
           "$HOMEBASE/Library/Caches/com.spotify.client" \
           "$HOMEBASE/Library/Caches/Yarn" \
           "$HOMEBASE/.ssh" "$HOMEBASE/.nvm" "$HOMEBASE/Dropbox" \
           "$HOMEBASE/.cache/huggingface"
  touch "$ROOT/webapp/package.json" "$ROOT/video/package.json" \
        "$ROOT/render/package.json" "$ROOT/video/remotion.config.ts" \
        "$ROOT/render/out/final.mp4"
  build_deny
  refuse() {
    if safe_target "$1" >/dev/null 2>&1; then
      printf '  \033[31m✗ FAIL not refused: %s\033[0m\n' "${1:-<empty>}"; fails=$((fails+1))
    else printf '  \033[32m✓\033[0m refused %s\n' "${1:-<empty>}"; fi
  }
  accept() {
    if safe_target "$1" >/dev/null 2>&1; then printf '  \033[32m✓\033[0m accepted %s\n' "$1"
    else printf '  \033[31m✗ FAIL wrongly refused: %s\033[0m\n' "$1"; fails=$((fails+1)); fi
  }
  echo "== safe_target — every line below MUST be refused (forced dry-run) =="
  refuse ""
  refuse "/"
  refuse "/Users"
  refuse "/etc/passwd"
  refuse "$ROOT"
  refuse "$HOMEBASE"
  refuse "$HOMEBASE/.Trash"
  refuse "$HOMEBASE/Downloads"
  refuse "$HOMEBASE/Documents"
  refuse "$HOMEBASE/Library/Application Support"
  refuse "$HOMEBASE/Library/Application Support/Google"
  refuse "$HOMEBASE/Library/Keychains"
  refuse "$HOMEBASE/.ssh"
  refuse "$HOMEBASE/.nvm"
  refuse "$HOMEBASE/Dropbox"
  refuse "$HOMEBASE/Library/Caches/ms-playwright"
  refuse "$HOMEBASE/Library/Caches/com.spotify.client"
  refuse "$HOMEBASE/.cache/huggingface"
  refuse "$ROOT/webapp/dist/*"
  echo "== and these MUST be accepted =="
  accept "$ROOT/webapp/node_modules"
  accept "$ROOT/webapp/dist"
  accept "$HOMEBASE/Library/Caches/Yarn"
  echo "== deliverable gates =="
  if has_file "$ROOT/video" 'remotion.config.*'; then
    printf '  \033[32m✓\033[0m remotion marker detected\n'
  else printf '  \033[31m✗ FAIL remotion marker missed\033[0m\n'; fails=$((fails+1)); fi
  if has_media "$ROOT/render/out"; then
    printf '  \033[32m✓\033[0m rendered media detected in out/\n'
  else printf '  \033[31m✗ FAIL media in out/ missed\033[0m\n'; fails=$((fails+1)); fi
  if has_media "$ROOT/webapp/dist"; then
    printf '  \033[31m✗ FAIL empty dist misread as media\033[0m\n'; fails=$((fails+1))
  else printf '  \033[32m✓\033[0m media-free dist accepted\n'; fi
  echo
  if [ "$fails" -eq 0 ]; then printf '\033[32mall assertions passed\033[0m\n'; exit 0
  else printf '\033[31m%s FAILURES — do not use --execute until fixed\033[0m\n' "$fails"; exit 1; fi
fi

# ─────────────────────────────── main ────────────────────────────────
[ -n "$ROOT" ] && [ -d "$ROOT" ] || {
  echo "usage: purge-live.sh <root> [--home <dir>] [--execute] [--force]  |  purge-live.sh self-test"
  exit 1
}
build_deny

freek() {
  local k
  k=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')
  [ -n "$k" ] || k=$(df -k / | awk 'NR==2{print $4}')
  printf '%s' "$k"
}
START_FREE=$(freek)
T0=$SECONDS

# ── GATE, not a warning: deleting .next/dist under a live dev server kills it ──
BUSY=$(ps -eo command 2>/dev/null | grep -cE "[n]ext-server|[n]ext dev|[v]ite |[w]ebpack|[v]itest" || true)
if [ "${BUSY:-0}" -gt 0 ] && [ "$FORCE" -eq 0 ]; then
  echo "REFUSING: $BUSY dev-server/test processes are running (next/vite/webpack/vitest)."
  echo "Deleting build output under a live server kills it mid-request."
  echo "Stop them, or re-run with --force if they belong to a different tree."
  ps -eo pid,command | grep -E "[n]ext-server|[n]ext dev|[v]ite |[w]ebpack|[v]itest" | head -8
  exit 2
fi

echo "════════════════════════════════════════════════════════════"
echo "  PURGE  $ROOT $([ -n "$HOMEBASE" ] && echo "(+ caches of $HOMEBASE)")"
awk -v s="$START_FREE" 'BEGIN{printf "  start free: %.2f GiB", s/1048576}'
[ "$EXECUTE" -eq 1 ] && echo "   MODE: EXECUTE" || echo "   MODE: dry-run (nothing deleted)"
echo "════════════════════════════════════════════════════════════"
echo
echo "── enumerating targets ──"

while IFS= read -r d; do try_add "$d"; done \
  < <(find "$ROOT" -name node_modules -type d -prune 2>/dev/null)

while IFS= read -r d; do
  [ -f "$(dirname "$d")/Cargo.toml" ] && try_add "$d"
done < <(find "$ROOT" -name target -type d -not -path '*/node_modules/*' -prune 2>/dev/null)

for n in dist build .next .turbo .anchor .parcel-cache .svelte-kit out; do
  while IFS= read -r d; do
    proj="$(dirname "$d")"
    { [ -f "$proj/package.json" ] || [ -f "$proj/Anchor.toml" ]; } || continue
    case "$n" in
      out|dist|build)
        # `out/` in a Remotion project is the finished render — Tier 2.
        # Media presence wins over every other signal (gotchas.md).
        if has_file "$proj" 'remotion.config.*'; then
          skip "remotion render output — Tier 2 deliverable" "$d"; continue
        fi
        if has_media "$d"; then
          skip "holds rendered media, looks like a deliverable — Tier 2" "$d"; continue
        fi
        ;;
    esac
    try_add "$d"
  done < <(find "$ROOT" -name "$n" -type d -not -path '*/node_modules/*' -prune 2>/dev/null)
done

if [ -n "$HOMEBASE" ] && [ -d "$HOMEBASE" ]; then
  for p in "$HOMEBASE/.npm/_cacache" "$HOMEBASE/.nuget/packages" "$HOMEBASE/.p2" \
           "$HOMEBASE/.expo" "$HOMEBASE/.yarn/cache" "$HOMEBASE/.yarn/berry/cache" \
           "$HOMEBASE/.gradle/caches" "$HOMEBASE/.m2/repository" \
           "$HOMEBASE/.bun/install/cache"; do
    [ -d "$p" ] && try_add "$p"
  done
  # ~/.cache entry-by-entry so the DENY list (huggingface/torch models) applies
  if [ -d "$HOMEBASE/.cache" ]; then
    while IFS= read -r e; do
      [ -d "$HOMEBASE/.cache/$e" ] && try_add "$HOMEBASE/.cache/$e"
    done < <(ls -A "$HOMEBASE/.cache" 2>/dev/null)
  fi
  # Library/Caches: allowlisted Tier-0 names only — NEVER the whole dir.
  # Spotify offline downloads and Playwright browsers live in here (Tier 1).
  C="$HOMEBASE/Library/Caches"
  if [ -d "$C" ]; then
    for name in pnpm Yarn deno pip node-gyp typescript electron hardhat-nodejs \
                ffmpeg-static-nodejs Homebrew GeoServices Adobe com.apple.helpd \
                BraveSoftware Firefox Arc "Microsoft Edge" "Google/Chrome"; do
      [ -d "$C/$name" ] && try_add "$C/$name"
    done
    for u in "$C"/*.ShipIt; do [ -d "$u" ] && try_add "$u"; done
    # honesty pass: anything >= 50 MB left behind gets a line in the report
    while IFS= read -r e; do
      [ -d "$C/$e" ] || continue
      grep -qxF "$C/$e" "$TARGETS" && continue
      kb=$(du -sk "$C/$e" 2>/dev/null | awk '{print $1}'); kb=${kb:-0}
      [ "$kb" -ge 51200 ] || continue
      case "$e" in
        ms-playwright|ms-playwright-go)
          skip "Tier 1: npx playwright install re-downloads it — ask first" "$C/$e ($((kb/1024)) MB)" ;;
        com.spotify.client)
          skip "Tier 1: holds offline downloads — ask first" "$C/$e ($((kb/1024)) MB)" ;;
        *)
          skip "not on the Tier-0 allowlist — left for review" "$C/$e ($((kb/1024)) MB)" ;;
      esac
    done < <(ls -A "$C" 2>/dev/null)
  fi
fi

TOTAL=$(wc -l < "$TARGETS" | tr -d ' ')
printf "\r  %s targets queued\033[K\n" "$TOTAL"

if [ -s "$SKIPPED" ]; then
  echo
  echo "── left alone (and why) ──"
  sort -u "$SKIPPED" | sed 's/^/  /'
fi
echo
[ "$TOTAL" -eq 0 ] && { echo "nothing to do"; exit 0; }

if [ "$EXECUTE" -eq 0 ]; then
  echo "── dry-run: sizes (largest first) ──"
  while IFS= read -r d; do du -sk "$d" 2>/dev/null; done < "$TARGETS" \
    | sort -rn | awk -F'\t' '{t+=$1; printf "  %8.2f GB  %s\n", $1/1048576, $2}
                             END{printf "\n  WOULD FREE (du sum, overstates on hardlinks): %.2f GB\n", t/1048576}'
  echo
  echo "  re-run with --execute to delete"
  exit 0
fi

WORKERS=4
# round-robin split across workers
i=0
while [ $i -lt $WORKERS ]; do
  : > "$WORK/w$i.list"; : > "$WORK/w$i.log"; echo 0 > "$WORK/w$i.done"
  i=$((i+1))
done
awk -v n="$WORKERS" -v w="$WORK" '{print $0 > (w "/w" (NR%n) ".list")}' "$TARGETS"

echo "── deleting with $WORKERS parallel workers ──"
i=0
while [ $i -lt $WORKERS ]; do
  (
    c=0
    while IFS= read -r d; do
      kb=$(du -sk "$d" 2>/dev/null | awk '{print $1}'); kb=${kb:-0}
      if rm -rf -- "$d" 2>/dev/null; then
        awk -v k="$kb" -v p="$d" 'BEGIN{printf "  ok   %8.2f GB  %s\n", k/1048576, p}' >> "$WORK/w$i.log"
      else
        echo "  FAIL $d" >> "$WORK/w$i.log"
      fi
      c=$((c+1)); echo "$c" > "$WORK/w$i.done"
    done < "$WORK/w$i.list"
    touch "$WORK/w$i.fin"
  ) &
  i=$((i+1))
done

# live dashboard: new receipts + heartbeat every 3s — never silent
declare -a SEEN; i=0
while [ $i -lt $WORKERS ]; do SEEN[$i]=0; i=$((i+1)); done
while :; do
  i=0
  while [ $i -lt $WORKERS ]; do
    n=$(wc -l < "$WORK/w$i.log" 2>/dev/null | tr -d ' '); n=${n:-0}
    if [ "$n" -gt "${SEEN[$i]}" ]; then
      sed -n "$(( SEEN[i] + 1 )),${n}p" "$WORK/w$i.log"
      SEEN[$i]=$n
    fi
    i=$((i+1))
  done
  done_n=0; i=0
  while [ $i -lt $WORKERS ]; do
    done_n=$(( done_n + $(cat "$WORK/w$i.done" 2>/dev/null || echo 0) )); i=$((i+1))
  done
  now=$(freek)
  awk -v el=$((SECONDS-T0)) -v d="$done_n" -v t="$TOTAL" -v f=$((now-START_FREE)) -v n="$now" \
    'BEGIN{printf "\033[36m[%02d:%02d] %s/%s done | freed %.2f GiB | free %.2f GiB\033[0m\n", el/60, el%60, d, t, f/1048576, n/1048576}'
  fin=0; i=0
  while [ $i -lt $WORKERS ]; do [ -f "$WORK/w$i.fin" ] && fin=$((fin+1)); i=$((i+1)); done
  [ "$fin" -eq "$WORKERS" ] && break
  sleep 3
done
wait

# flush receipts written after the loop's last read — without this, the final
# few deletions go unreported when workers finish between poll and break
i=0
while [ $i -lt $WORKERS ]; do
  n=$(wc -l < "$WORK/w$i.log" 2>/dev/null | tr -d ' '); n=${n:-0}
  [ "$n" -gt "${SEEN[$i]}" ] && sed -n "$(( SEEN[i] + 1 )),${n}p" "$WORK/w$i.log"
  i=$((i+1))
done

sleep 5   # APFS reclaims lazily — an immediate df can read delta 0
END_FREE=$(freek)
echo
echo "════════════════════════════════════════════════════════════"
awk -v a="$START_FREE" -v b="$END_FREE" -v t="$TOTAL" -v f="$(grep -ch FAIL "$WORK"/w*.log | awk '{s+=$1} END{print s+0}')" 'BEGIN{
  printf "  targets    : %s   failures: %s\n", t, f
  printf "  free before: %.2f GiB\n  free after : %.2f GiB\n  RECLAIMED  : %.2f GiB\n", a/1048576, b/1048576, (b-a)/1048576
}'
echo "  (if RECLAIMED looks low, wait 60s and re-check df — APFS is lazy)"
echo "  never touched: Trash, Downloads, Documents, Desktop, personal media,"
echo "  Application Support, Keychains, .ssh, .nvm — see DENY in this script."
echo "════════════════════════════════════════════════════════════"
