#!/usr/bin/env bash
# system-cleanup :: reclaim.sh
# Clears TIER 0 (pure cache) targets only. Dry-run by default.
#
#   bash reclaim.sh <group...> [--execute] [--root DIR] [--node-modules] [--depth N]
#
# groups: pm  langcache  browsers  sim  appcache  builds  all
#         (`all` = pm browsers sim appcache — deliberately NOT langcache/builds,
#          which need an explicit opt-in because they cost a rebuild.)
#
# Refuses Tier 1 / Tier 2 by construction: never the Trash, Downloads, Documents,
# Desktop, personal media, Application Support, keychains, credentials, ~/.claude,
# Xcode Archives, simulator Devices, or Docker's data. Those are asked-for or
# hand-back-to-user only, never automated.
set -uo pipefail

: "${HOME:?HOME must be set}"

EXECUTE=0
ROOT=""
NODE_MODULES=0
DEPTH=5
PICKED=()
TOTAL_KB=0
TINY=0
MIN_MB="${MIN_MB:-1}"   # don't bother reporting/removing anything smaller

while [ $# -gt 0 ]; do
  case "$1" in
    --execute)      EXECUTE=1 ;;
    --root)         ROOT="${2:-}"; shift ;;
    --node-modules) NODE_MODULES=1 ;;
    --depth)        DEPTH="${2:-5}"; shift ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    -*)             printf 'unknown flag: %s\n' "$1"; exit 2 ;;
    *)              PICKED+=("$1") ;;
  esac
  shift
done
[ "${#PICKED[@]}" -eq 0 ] && { sed -n '2,20p' "$0"; exit 2; }

# $HOME must be QUOTED in the pattern and ~ escaped in the replacement, or bash
# leaves the path untouched with no error.
tilde() { printf '%s' "${1/#"$HOME"/\~}"; }
mb()    { awk -v k="${1:-0}" 'BEGIN{printf "%.0f", k/1024}'; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
plan()  { printf '  \033[36m·\033[0m %s\n' "$1"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$1"; }
note()  { printf '  \033[1m>\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
# has_file <dir> <name-pattern> -- space-safe project-marker probe.
# Do NOT implement this as `for g in $pattern`: an unquoted expansion word-splits
# on spaces, so any path like "client demos/promo reel/..." silently never matches
# and a protective guard turns into a no-op.
has_file() { [ -n "$(find "$1" -maxdepth 1 -name "$2" -print -quit 2>/dev/null)" ]; }

# Rendered deliverables (video/audio/pdf) are WORK PRODUCT, not build output --
# `out/` in a video project holds the finished renders. Tool-marker checks run
# before this, so a Foundry/Hardhat/Cargo dir never reaches here.
has_media() {
  [ -n "$(find "$1" -maxdepth 2 \
      \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.webm' -o -iname '*.gif' \
         -o -iname '*.mp3' -o -iname '*.wav' -o -iname '*.pdf' \) \
      -print -quit 2>/dev/null)" ]
}

# Backstop denylist. The per-group allowlists are the primary guard; this exists
# so a future edit cannot accidentally reach anything irreplaceable.
DENY=(
  "$HOME/.Trash" "$HOME/Downloads" "$HOME/Documents" "$HOME/Desktop"
  "$HOME/Movies" "$HOME/Pictures" "$HOME/Music" "$HOME/Public"
  "$HOME/Library/Application Support" "$HOME/Library/Keychains"
  "$HOME/Library/Mobile Documents" "$HOME/Library/Messages"
  "$HOME/Library/Mail" "$HOME/Library/Photos"
  "$HOME/.ssh" "$HOME/.gnupg" "$HOME/.aws" "$HOME/.config" "$HOME/.claude"
  "$HOME/Library/Developer/Xcode/Archives"
  "$HOME/Library/Developer/CoreSimulator/Devices"
  "$HOME/Library/Containers/com.docker.docker"
)

safe_rm() {
  local p="$1" label="${2:-}" kb d
  [ -n "$p" ] || { warn "REFUSE empty path"; return 1; }
  case "$p" in
    "/"|"$HOME"|"$HOME/") warn "REFUSE root/home: $p"; return 1 ;;
    *'*'*|*'?'*)          warn "REFUSE unexpanded glob: $p"; return 1 ;;
  esac
  case "$p" in "$HOME"/*) ;; *) warn "REFUSE outside HOME: $p"; return 1 ;; esac
  for d in "${DENY[@]}"; do
    case "$p" in
      "$d"|"$d"/*) warn "REFUSE denylist $(tilde "$d"): $(tilde "$p")"; return 1 ;;
    esac
  done
  [ -e "$p" ] || return 0
  kb="$(du -sk "$p" 2>/dev/null | awk 'NR==1{print $1}')"; kb="${kb:-0}"
  # Below the floor it isn't worth a line of output or a delete. Counted so the
  # summary can say how many were passed over rather than hiding them.
  if [ "$kb" -lt $((MIN_MB * 1024)) ]; then
    TINY=$((TINY + 1)); return 0
  fi
  if [ "$EXECUTE" = 1 ]; then
    if rm -rf -- "$p" 2>/dev/null; then ok "$(mb "$kb") MB  $label  $(tilde "$p")"
    else warn "failed: $(tilde "$p")"; return 1; fi
  else
    plan "$(mb "$kb") MB  $label  $(tilde "$p")"
  fi
  TOTAL_KB=$((TOTAL_KB + kb))
}

# Only ever a recognised build-output directory name -- never a project root.
safe_rm_build() {
  local p="$1" label="$2" base; base="$(basename "$p")"
  case "$base" in
    .next|.turbo|.parcel-cache|.svelte-kit|.nuxt|.angular|coverage \
    |out|dist|build|artifacts|target|cache|output|node_modules) ;;
    *) warn "REFUSE non-build basename: $(tilde "$p")"; return 1 ;;
  esac
  safe_rm "$p" "$label"
}

run_cmd() {  # run_cmd <description> <cmd...>
  local desc="$1"; shift
  if [ "$EXECUTE" = 1 ]; then
    if "$@" >/dev/null 2>&1; then ok "$desc"; else warn "$desc (failed / not installed)"; fi
  else
    plan "$desc"
  fi
}

# ------------------------------------------------------------------- groups
g_pm() {
  head_ "package-manager caches (Tier 0)"
  # ORDER: node_modules must already be gone before pruning the pnpm store, or
  # the store's packages are still hardlink-referenced and the prune frees ~0.
  run_cmd "pnpm store prune"        pnpm store prune
  run_cmd "npm cache clean --force" npm cache clean --force
  safe_rm "$HOME/Library/Caches/pnpm"              "pnpm cache"
  safe_rm "$HOME/.yarn/berry/cache"                "yarn berry"
  safe_rm "$HOME/Library/Caches/Yarn"              "yarn v1"
  safe_rm "$HOME/.cache/yarn"                      "yarn xdg"
  safe_rm "$HOME/.bun/install/cache"               "bun"
  safe_rm "$HOME/Library/Caches/deno"              "deno"
  safe_rm "$HOME/Library/Caches/pip"               "pip"
  safe_rm "$HOME/Library/Caches/node-gyp"          "node-gyp"
  safe_rm "$HOME/Library/Caches/typescript"        "typescript"
  safe_rm "$HOME/Library/Caches/electron"          "electron"
  safe_rm "$HOME/Library/Caches/hardhat-nodejs"    "hardhat"
  safe_rm "$HOME/Library/Caches/ffmpeg-static-nodejs" "ffmpeg-static"
  run_cmd "brew cleanup --prune=all" brew cleanup --prune=all
  safe_rm "$HOME/Library/Caches/Homebrew"          "homebrew"
}

g_langcache() {
  head_ "compiler / language caches (Tier 0, but costs a re-download)"
  safe_rm "$HOME/.cargo/registry" "cargo registry"
  safe_rm "$HOME/go/pkg/mod"      "go modules"
  safe_rm "$HOME/.gradle/caches"  "gradle"
  note "next cargo/go/gradle build re-downloads its dependencies"
}

g_browsers() {
  head_ "browser HTTP caches (Tier 0)"
  for b in "Google Chrome" "Brave Browser" Firefox Arc "Microsoft Edge"; do
    pgrep -x "$b" >/dev/null 2>&1 && warn "$b is RUNNING — quit it for a clean sweep (deleting live cache is tolerated, just messier)"
  done
  safe_rm "$HOME/Library/Caches/Google/Chrome"    "chrome"
  safe_rm "$HOME/Library/Caches/BraveSoftware"    "brave"
  safe_rm "$HOME/Library/Caches/Microsoft Edge"   "edge"
  safe_rm "$HOME/Library/Caches/Firefox"          "firefox"
  safe_rm "$HOME/Library/Caches/Arc"              "arc"
  note "profiles/history/passwords live in ~/Library/Application Support — untouched"
}

g_sim() {
  head_ "Xcode / simulator caches (Tier 0)"
  safe_rm "$HOME/Library/Developer/Xcode/DerivedData"        "DerivedData"
  safe_rm "$HOME/Library/Developer/CoreSimulator/Caches"     "sim caches"
  note "CoreSimulator/Devices (installed sim state) and Xcode/Archives (shipped builds) are NOT touched"
  if command -v xcrun >/dev/null 2>&1 && xcrun simctl help >/dev/null 2>&1; then
    run_cmd "simctl delete unavailable" xcrun simctl delete unavailable
  else
    warn "xcrun simctl unavailable (Command Line Tools only, no full Xcode) — skipped"
  fi
}

g_appcache() {
  head_ "app caches & updater staging (Tier 0)"
  local u
  for u in "$HOME"/Library/Caches/*.ShipIt; do
    [ -d "$u" ] && safe_rm "$u" "updater staging"
  done
  safe_rm "$HOME/Library/Caches/GeoServices" "apple maps"
  safe_rm "$HOME/Library/Caches/Adobe"       "adobe"
  safe_rm "$HOME/Library/Caches/com.apple.helpd" "apple help"
  note "SKIPPED on purpose: com.spotify.client (holds offline downloads = state, not cache)"
  note "SKIPPED on purpose: ms-playwright (Tier 1 — multi-GB re-download; ask first)"
}

g_builds() {
  local root="${ROOT:-$HOME/dev}"
  head_ "build output under $(tilde "$root") (Tier 0)"
  [ -d "$root" ] || { warn "root not found: $(tilde "$root") — pass --root DIR"; return 0; }

  # Unambiguous: these names are always regenerable framework build output.
  while IFS= read -r d; do
    [ -n "$d" ] && safe_rm_build "$d" "build-output"
  done < <(find "$root" -maxdepth "$DEPTH" -type d \
            \( -name .next -o -name .turbo -o -name .parcel-cache \
               -o -name .svelte-kit -o -name .nuxt -o -name .angular \
               -o -name coverage \) -not -path '*/node_modules/*' -prune 2>/dev/null)

  # .vercel/output ONLY. .vercel/project.json is the Vercel project link (Tier 2):
  # delete it and the project is unlinked from Vercel.
  while IFS= read -r d; do
    [ -n "$d" ] && safe_rm_build "$d" "vercel-output"
  done < <(find "$root" -maxdepth $((DEPTH + 1)) -type d -path '*/.vercel/output' \
            -not -path '*/node_modules/*' -prune 2>/dev/null)

  # Ambiguous names: delete ONLY with a proven project marker. `out` is build
  # output in Foundry and a rendered deliverable in Remotion — same name,
  # opposite tier. Never decide from the name alone.
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    local proj base repo; proj="$(dirname "$d")"; base="$(basename "$d")"
    if [ -f "$proj/foundry.toml" ] || has_file "$proj" 'hardhat.config.*'; then
      case "$base" in artifacts|out|cache) safe_rm_build "$d" "solidity-build"; continue ;; esac
    fi
    if [ -f "$proj/Cargo.toml" ] && [ "$base" = target ]; then
      safe_rm_build "$d" "cargo-target"; continue
    fi
    if has_file "$proj" 'remotion.config.*'; then
      warn "SKIP rendered video output (Tier 2): $(tilde "$d")"; continue
    fi
    # Being gitignored is NOT proof it's disposable -- rendered deliverables are
    # routinely gitignored too. Media inside wins over the gitignore signal.
    if has_media "$d"; then
      warn "SKIP holds rendered media, looks like a deliverable (Tier 2): $(tilde "$d")"; continue
    fi
    repo="$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null)"
    if [ -z "$repo" ]; then
      warn "SKIP no marker, no git: $(tilde "$d")"; continue
    fi
    # ABSOLUTE path: check-ignore resolves a relative path against the repo root,
    # not your cwd, so relative paths silently mislabel everything as tracked.
    if git -C "$repo" check-ignore -q "$d" 2>/dev/null; then
      safe_rm_build "$d" "gitignored-build"
    else
      warn "SKIP git-tracked, may be source: $(tilde "$d")"
    fi
  done < <(find "$root" -maxdepth "$DEPTH" -type d \
            \( -name out -o -name dist -o -name build -o -name artifacts -o -name target \) \
            -not -path '*/node_modules/*' -prune 2>/dev/null)

  if [ "$NODE_MODULES" = 1 ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && safe_rm_build "$d" "node_modules"
    done < <(find "$root" -maxdepth "$DEPTH" -type d -name node_modules -prune 2>/dev/null)
    note "run \`pnpm store prune\` AFTER this (not before) to actually free the store"
    note "reinstall with: pnpm install"
  else
    note "node_modules left alone — pass --node-modules to include it"
  fi
}

g_selftest() {
  # EXECUTE is forced off: a failing assertion must never be able to delete the
  # very thing it is asserting is protected.
  EXECUTE=0
  local fails=0 p
  head_ "self-test — every path below MUST be refused (forced dry-run)"
  for p in "$HOME/.Trash" "$HOME/Downloads" "$HOME/Documents" "$HOME/Desktop" \
           "$HOME/Movies" "$HOME/Pictures" "$HOME/Music" "$HOME/.ssh" \
           "$HOME/.config" "$HOME/.claude" "$HOME/Library/Application Support" \
           "$HOME/Library/Keychains" "$HOME/Library/Containers/com.docker.docker" \
           "$HOME/Library/Developer/CoreSimulator/Devices" \
           "$HOME/Library/Developer/Xcode/Archives" \
           "$HOME" "/" "/etc" '/tmp/*' ""; do
    if safe_rm "$p" "MUST-REFUSE" >/dev/null 2>&1; then
      printf '  \033[31m✗ FAIL not refused: %s\033[0m\n' "${p:-<empty>}"; fails=$((fails + 1))
    else
      ok "refused ${p:-<empty>}"
    fi
  done
  if safe_rm_build "$HOME/dev/a-project-root" "MUST-REFUSE" >/dev/null 2>&1; then
    printf '  \033[31m✗ FAIL project root accepted as build dir\033[0m\n'; fails=$((fails + 1))
  else
    ok "refused non-build basename (project root)"
  fi
  if [ "$fails" -eq 0 ]; then printf '\n  \033[32mall assertions passed\033[0m\n'
  else printf '\n  \033[31m%s FAILURES — do not use --execute until fixed\033[0m\n' "$fails"; fi
  return 0
}

# -------------------------------------------------------------------- main
BEFORE="$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')"
[ "$EXECUTE" = 1 ] && printf '\033[1mMODE: EXECUTE (deleting)\033[0m\n' \
                   || printf '\033[1mMODE: dry-run\033[0m (nothing deleted — add --execute)\n'

for g in "${PICKED[@]}"; do
  case "$g" in
    pm)        g_pm ;;
    langcache) g_langcache ;;
    browsers)  g_browsers ;;
    sim)       g_sim ;;
    appcache)  g_appcache ;;
    builds)    g_builds ;;
    self-test) g_selftest ;;
    all)       g_pm; g_browsers; g_sim; g_appcache ;;
    *)         printf 'unknown group: %s\n' "$g"; exit 2 ;;
  esac
done

AFTER="$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')"
head_ "result"
printf '  target total: %s MB\n' "$(mb "$TOTAL_KB")"
[ "$TINY" -gt 0 ] && printf '  passed over: %s targets under %s MB\n' "$TINY" "$MIN_MB"
if [ "$EXECUTE" = 1 ] && [ -n "${BEFORE:-}" ] && [ -n "${AFTER:-}" ]; then
  # df delta is the ONLY honest number: hardlinked trees (pnpm store <-> node_modules)
  # free nothing until the last link dies, so summing du overstates the win.
  printf '  actual df delta: %s MB\n' "$(mb $((AFTER - BEFORE)))"
fi
df -h /System/Volumes/Data 2>/dev/null | tail -1
[ "$EXECUTE" = 1 ] || printf '\nre-run with --execute to apply.\n'
