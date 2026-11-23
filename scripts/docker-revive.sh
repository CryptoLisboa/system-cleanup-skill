#!/usr/bin/env bash
# system-cleanup :: docker-revive.sh
# Fixes the stale-backend wedge: a full disk kills Docker Desktop's VM boot, the
# backend never retries, and REOPENING THE APP DOES NOT HELP -- the dead backend
# still holds the socket and survives a normal quit.
#
# Symptom: `docker` hangs forever; com.docker.backend is alive but there is no VM
# process; com.docker.backend.log loops `returning engine error:` with an empty
# message; the backend's start timestamp is from a previous day.
#
# RESTARTS ONLY. Deletes no image, no container, no volume, no disk image.
set -uo pipefail

WAIT_SECS="${WAIT_SECS:-240}"

log() { printf '\033[1m>>\033[0m %s\n' "$1"; }

# `docker info` can exit 0 while the server half is broken (observed: backend
# answers the socket but reports "Docker Desktop is unable to start"). Require a
# real version string AND a server round-trip, not just exit status.
daemon_up() {
  local v
  v=$(docker info --format '{{.ServerVersion}}' 2>/dev/null) || return 1
  case "$v" in [0-9]*.[0-9]*) ;; *) return 1 ;; esac
  docker system df >/dev/null 2>&1
}

# macOS has no coreutils `timeout`.
with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$secs" ]; then
      kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124
    fi
    /bin/sleep 1; i=$((i+1))
  done
  wait "$pid"
}

if ! command -v docker >/dev/null 2>&1; then
  log "docker CLI not found — nothing to revive."; exit 0
fi

log "checking daemon (bounded — a dead daemon hangs the CLI forever)"
if with_timeout 30 daemon_up; then
  log "daemon already up. Nothing to do."
  with_timeout 25 docker system df
  exit 0
fi

log "daemon down. Backend start time (stale = never retried VM boot after a full disk):"
ps -o lstart=,pid=,command= -p "$(pgrep -f 'MacOS/com.docker.backend$' 2>/dev/null | head -1)" 2>/dev/null | cut -c1-100 || true

LOGDIR="$HOME/Library/Containers/com.docker.docker/Data/log/host"
if [ -f "$LOGDIR/com.docker.backend.log" ]; then
  log "last engine errors:"
  grep -a "returning engine error" "$LOGDIR/com.docker.backend.log" 2>/dev/null | tail -3
fi

log "quitting Docker Desktop (graceful first)"
osascript -e 'quit app "Docker Desktop"' >/dev/null 2>&1 || true
osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true
/bin/sleep 8

log "killing any surviving docker processes"
# Leave /Library/PrivilegedHelperTools/com.docker.vmnetd alone: root-owned helper.
pkill -f 'com.docker.backend'  2>/dev/null || true
pkill -f 'Docker Desktop'      2>/dev/null || true
pkill -f 'com.docker.build'    2>/dev/null || true
pkill -f 'cli-plugins/docker-agent' 2>/dev/null || true
/bin/sleep 5

# pkill does not always land it. Kill survivors by PID -- this step is the one
# that actually unwedges it.
for pid in $(pgrep -f 'com.docker.backend' 2>/dev/null); do
  log "hard-killing surviving backend pid $pid"
  kill -9 "$pid" 2>/dev/null || true
done
/bin/sleep 3

remaining="$(pgrep -cf 'com.docker.backend' 2>/dev/null || echo 0)"
log "backend processes remaining: $remaining (want 0)"

log "free space before relaunch (VM boot needs headroom — that's what broke it):"
df -h /System/Volumes/Data 2>/dev/null | tail -1

log "relaunching Docker Desktop"
open -a Docker

log "polling for daemon (up to ${WAIT_SECS}s)"
i=0
while [ "$i" -lt "$WAIT_SECS" ]; do
  if daemon_up; then
    log "DAEMON UP after ~${i}s"
    docker info --format 'ServerVersion={{.ServerVersion}} images={{.Images}} containers={{.Containers}}'
    docker system df
    cat <<'EOF'

Prune in order of safety (see SKILL.md):
  docker builder prune -a -f     # pure cache, free
  docker image prune -f          # dangling layers only
  docker image prune -a -f       # ALL unreferenced images -- costs a re-pull
  # volumes: enumerate by name and delete a FILTERED set.
  # `docker volume prune -a` deletes an active project's DB just because its
  # stack is not running right now. Never use it blind.
EOF
    exit 0
  fi
  /bin/sleep 5; i=$((i+5))
done

log "still down after ${WAIT_SECS}s. Deeper problem than a stale backend."
pgrep -fl 'com.docker|Docker Desktop' 2>/dev/null | cut -c1-90
tail -15 "$LOGDIR/supervisor.log" 2>/dev/null
exit 1
