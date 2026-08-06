#!/usr/bin/env bash
# system-cleanup :: scan.sh
# READ-ONLY. Measures cleanup targets and prints a ranked, tier-labelled table.
# Deletes nothing. Safe to run with a wedged Docker daemon.
#
# bash (not zsh) on purpose: zsh aborts a whole command on a non-matching glob.
set -uo pipefail

: "${HOME:?HOME must be set}"
MIN_MB="${MIN_MB:-1}"          # skip rows smaller than this
ROWS="$(mktemp -t syscleanup-rows)"
trap 'rm -f "$ROWS"' EXIT

# macOS has no coreutils `timeout`. This is the replacement.
with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$secs" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    /bin/sleep 1; i=$((i+1))
  done
  wait "$pid"
}

# $HOME must be QUOTED in the pattern and ~ escaped in the replacement, or bash
# leaves the path untouched with no error.
tilde() { printf '%s' "${1/#"$HOME"/\~}"; }

# row <tier> <label> <path>
row() {
  local tier="$1" label="$2" path="$3" kb
  [ -e "$path" ] || return 0
  kb="$(du -sk "$path" 2>/dev/null | awk 'NR==1{print $1}')"
  [ -z "$kb" ] && return 0
  [ "$kb" -lt $((MIN_MB * 1024)) ] && return 0
  printf '%s\t%s\t%s\t%s\n' "$kb" "$tier" "$label" "$(tilde "$path")" >>"$ROWS"
}

# Always reported regardless of size — "Trash is already empty" is itself a
# finding, and it stops anyone reaching for it later.
row_always() {
  local tier="$1" label="$2" path="$3" kb items=""
  [ -e "$path" ] || return 0
  kb="$(du -sk "$path" 2>/dev/null | awk 'NR==1{print $1}')"; kb="${kb:-0}"
  items="$(ls -A "$path" 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s\t%s\t%s\t%s\n' "$kb" "$tier" "$label ($items items)" "$(tilde "$path")" >>"$ROWS"
}

section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

dump() {   # dump <tier-filter|all>
  local want="$1"
  awk -F'\t' -v want="$want" '
    want=="all" || $2==want {
      printf "%9.0f MB  %-2s  %-26s %s\n", $1/1024, $2, $3, $4
    }' "$ROWS" | sort -rn
}

printf '\033[1msystem-cleanup scan\033[0m  (read-only — nothing is deleted)\n'
printf 'free space now:\n'
df -h /System/Volumes/Data 2>/dev/null | tail -1 || df -h / | tail -1

# ---------------------------------------------------------------- Tier 0
row T0 "pnpm store"          "$HOME/Library/pnpm/store"
row T0 "pnpm store (xdg)"    "$HOME/.local/share/pnpm/store"
row T0 "pnpm cache"          "$HOME/Library/Caches/pnpm"
row T0 "pnpm store (legacy)" "$HOME/.pnpm-store"
row T0 "npm cache"           "$HOME/.npm"
row T0 "yarn cache (v1)"     "$HOME/Library/Caches/Yarn"
row T0 "yarn cache (xdg)"    "$HOME/.cache/yarn"
row T0 "yarn berry cache"    "$HOME/.yarn/berry/cache"
row T0 "bun cache"           "$HOME/.bun/install/cache"
row T0 "deno cache"          "$HOME/Library/Caches/deno"
row T0 "homebrew cache"      "$HOME/Library/Caches/Homebrew"
row T0 "pip cache"           "$HOME/Library/Caches/pip"
row T0 "node-gyp headers"    "$HOME/Library/Caches/node-gyp"
row T0 "typescript cache"    "$HOME/Library/Caches/typescript"
row T0 "electron cache"      "$HOME/Library/Caches/electron"
row T0 "hardhat cache"       "$HOME/Library/Caches/hardhat-nodejs"
row T0 "ffmpeg-static cache" "$HOME/Library/Caches/ffmpeg-static-nodejs"
row T0 "gradle caches"       "$HOME/.gradle/caches"
row T0 "go module cache"     "$HOME/go/pkg/mod"
row T0 "cargo registry"      "$HOME/.cargo/registry"
row T0 "chrome http cache"   "$HOME/Library/Caches/Google/Chrome"
row T0 "brave http cache"    "$HOME/Library/Caches/BraveSoftware"
row T0 "edge http cache"     "$HOME/Library/Caches/Microsoft Edge"
row T0 "firefox http cache"  "$HOME/Library/Caches/Firefox"
row T0 "arc http cache"      "$HOME/Library/Caches/Arc"
row T0 "xcode DerivedData"   "$HOME/Library/Developer/Xcode/DerivedData"
row T0 "simulator caches"    "$HOME/Library/Developer/CoreSimulator/Caches"
row T0 "apple maps cache"    "$HOME/Library/Caches/GeoServices"
row T0 "adobe cache"         "$HOME/Library/Caches/Adobe"
for u in "$HOME"/Library/Caches/*.ShipIt; do
  [ -d "$u" ] && row T0 "updater staging" "$u"
done

# ---------------------------------------------------------------- Tier 1
row T1 "playwright browsers" "$HOME/Library/Caches/ms-playwright"
row T1 "playwright-go"       "$HOME/Library/Caches/ms-playwright-go"
row T1 "spotify offline"     "$HOME/Library/Caches/com.spotify.client"
row T1 "simulator DEVICES"   "$HOME/Library/Developer/CoreSimulator/Devices"
row T1 "iOS DeviceSupport"   "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
row T1 "rust toolchains"     "$HOME/.rustup"
row T1 "maven repository"    "$HOME/.m2/repository"
row T1 "docker (all data)"   "$HOME/Library/Containers/com.docker.docker"
row T1 "colima/lima VMs"     "$HOME/.lima"
row T1 "orbstack data"       "$HOME/.orbstack"

# ---------------------------------------------------------------- Tier 2
row_always T2 "TRASH — never empty for the user" "$HOME/.Trash"
row T2 "Downloads"           "$HOME/Downloads"
row T2 "Documents"           "$HOME/Documents"
row T2 "Desktop"             "$HOME/Desktop"
row T2 "Movies"              "$HOME/Movies"
row T2 "Pictures"            "$HOME/Pictures"
row T2 "Music"               "$HOME/Music"
row T2 "xcode Archives"      "$HOME/Library/Developer/Xcode/Archives"

section "Tier 0 — pure cache (clear freely; regenerates itself)"
dump T0
section "Tier 1 — ASK FIRST (expensive re-download, or holds local state)"
dump T1
section "Tier 2 — NEVER auto-delete (report to user, they decide)"
dump T2

# ------------------------------------------------------ discovery: unknowns
section "Largest \$HOME entries (find targets this list doesn't know about)"
# NOTE: `find -mindepth 1 -maxdepth 1` so dotfiles ARE included (a bare `*` glob
# silently skips them) AND names with spaces survive. `du -sh -- $(ls -A)` does
# the first but not the second: the unquoted expansion word-splits, so
# "Docker Desktop" becomes two nonexistent args and the entry vanishes.
( cd "$HOME" && find . -mindepth 1 -maxdepth 1 -exec du -sh {} + 2>/dev/null | sort -rh | head -12 )

section "Largest ~/Library/Caches entries"
( cd "$HOME/Library/Caches" 2>/dev/null && find . -mindepth 1 -maxdepth 1 -exec du -sh {} + 2>/dev/null | sort -rh | head -15 )

# ------------------------------------------------------------------ docker
section "Docker"
if with_timeout 20 docker system df >/tmp/syscleanup-docker.$$ 2>&1; then
  cat /tmp/syscleanup-docker.$$
  printf '\nvolumes by name (filter these -- NEVER blanket `volume prune -a`):\n'
  with_timeout 25 docker volume ls --format '{{.Name}}' 2>/dev/null | head -20
  vc="$(with_timeout 25 docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')"
  printf '  ... %s volumes total\n' "${vc:-?}"
else
  printf 'daemon not answering (or no docker installed).\n'
  printf 'If Docker is installed, this is usually the stale-backend wedge:\n'
  printf '  bash %s/docker-revive.sh\n' "$(dirname "$0")"
fi
rm -f /tmp/syscleanup-docker.$$

section "Next"
cat <<'EOF'
  reclaim Tier 0 (dry-run first):
    bash scripts/reclaim.sh all
    bash scripts/reclaim.sh all --execute

  Tier 1 needs an explicit per-target yes from the user, with its cost stated.
  Tier 2 is the user's to delete. Never empty the Trash for them.
EOF
