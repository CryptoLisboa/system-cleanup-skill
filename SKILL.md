---
name: system-cleanup
description: >-
  Reclaim disk space on macOS safely — measure every target first, then delete
  only what is provably regenerable, tiered by reversibility. Use whenever the
  user is out of space or wants a cleanup: "free up space", "disk is full", "my
  Mac is full", "no space left on device", "clean my caches", "reclaim disk",
  "clear node_modules", "prune docker", "clean pnpm/yarn/npm cache", "what's
  eating my disk". Also use when a build, install, or Docker start fails from a
  full disk (a full disk wedges Docker Desktop's VM in a way reopening the app
  does NOT fix — see references/gotchas.md), when measured directories don't
  add up to what df reports ("where did my space go", "System Data is huge",
  "Other Users & Shared", "280 GB unaccounted" — see
  references/missing-space.md), and when cleaning another user account on the
  same Mac. Scans read-only and reports a
  ranked table before touching anything; auto-clears only Tier 0 pure caches;
  asks before anything needing an expensive re-download or holding local dev
  state; NEVER empties Trash or touches Downloads/Documents/personal media —
  those it hands back to the user. SKIP for cleaning up code (dead files,
  refactors), for freeing memory/RAM rather than disk, and for remote/server
  disk cleanup.
---

# system-cleanup — measure, tier, reclaim

Disk cleanup fails in two directions: too timid (scan, report, free nothing) or
too eager (blow away something irreplaceable). This skill fixes the tiering so
neither happens, and encodes the macOS traps that make cleanup commands
*silently no-op* while looking like they worked.

**Scope:** local macOS disk. NOT code cleanup. NOT RAM. NOT remote hosts.

## Iron rules (non-negotiable)

1. **Measure before you delete, always.** Run `scripts/scan.sh` first and show
   the user the ranked table. A cleanup that can't say what it freed and from
   where is not a cleanup.
2. **NEVER empty the Trash.** Not with `rm`, not with Finder automation, not
   when asked directly. Trash is the user's last undo. Report its size and let
   them empty it themselves. Same for `~/Downloads`, `~/Documents`, `~/Desktop`,
   and personal media — **report, never delete.**
3. **Tier by reversibility, not by size.** See the three tiers below. The
   question is never "is this big" but "what does the user lose, and what does
   getting it back cost them".
4. **Verify with `df` deltas, never `du` of what you removed.** Hardlinked trees
   (pnpm store ↔ node_modules) free nothing until the *last* link dies, so `du`
   overstates. Capture `df -k` before and after and report the real delta.
5. **One target per command, and check the exit path.** A single `rm -rf a/* b/*`
   under zsh aborts the WHOLE command on the first non-matching glob and deletes
   nothing, with no error you'd notice. See gotchas.
6. **Never run a bare `docker` command when the daemon may be down** — the CLI
   hangs indefinitely, not for 30s. Always go through
   `scripts/docker-revive.sh` or a poll loop.
7. **Deletion is one-way. Anything Tier 1 or 2 needs an explicit yes** for that
   specific target, in this session. A yes for images is not a yes for volumes.
8. **No silent long-running commands — ever.** A monolithic `du`/`rm` that
   prints nothing for minutes is indistinguishable from a hang; the user will
   (rightly) kill it and lose the work. Anything that can run >30s gets live
   per-item output and a periodic heartbeat (items done / GB freed / GB free).
   `scripts/scan-live.sh` and `scripts/purge-live.sh` exist so you never have
   to improvise this.
9. **Unprivileged `du` is a floor, not a total — and never suppress its
   stderr during an audit.** `du` silently counts every unreadable dir as 0;
   the permission-denied list is itself a finding (it exposes other accounts
   and root-owned stores). When the numbers don't reconcile with `df`, read
   `references/missing-space.md` before chasing theories — and ask the user
   for a System Settings → Storage screenshot first; it's instant ground truth
   that no unprivileged tool can compute.

## The three tiers

| Tier | What | Action |
|---|---|---|
| **0 — pure cache** | Package-manager caches, browser HTTP caches, build output (`.next`, compile artifacts), app updater staging, simulator caches | Clear without asking. Regenerates itself on next use, costs the user nothing but a slower first run. |
| **1 — expensive to regain, or local state** | Docker images/volumes, Playwright browser binaries, simulator *Devices*, Spotify offline downloads, anything needing a multi-GB re-download or holding local dev data | **Ask, per target, with the cost stated** ("re-pulls ~10 GB on next `supabase start`"). |
| **2 — irreplaceable** | Trash, Downloads, Documents, Desktop, photos/video, rendered deliverables, credentials, `.vercel/project.json`, any git-tracked file | **Never delete.** Report size, hand to user. |

When a target is ambiguous, it is Tier 1 until proven Tier 0. `out/` is Tier 0
in a Foundry project and Tier 2 in a Remotion project — same name, opposite
answer. Resolve it by looking for the project marker, not the directory name.

## Workflow

```bash
S=<path-to-this-skill>/scripts    # e.g. ~/.claude/skills/system-cleanup/scripts
bash $S/scan.sh                                  # read-only, deletes nothing
bash $S/reclaim.sh all                           # dry-run: pm + browsers + sim + appcache
bash $S/reclaim.sh all --execute                 # apply
bash $S/reclaim.sh builds --root ~/dev           # opt-in: build output in repos
bash $S/reclaim.sh builds --root ~/dev --node-modules --execute
bash $S/reclaim.sh self-test                     # assert the refusals still fire
bash $S/purge-live.sh self-test                  # same, for the sudo-territory script
```

1. **Scan.** Show the ranked table + current `df`. Note anything Tier 2 as
   "yours to delete, not mine".
2. **Clear Tier 0** with `reclaim.sh` (dry-run first, then `--execute`).
3. **Ask about Tier 1**, one question per target, each with its real cost. Use a
   multi-option question, not a yes/no — "all unused images / only old duplicate
   versions / dangling only / none" is a far better menu than "prune images?".
4. **Re-measure and report** the `df` delta, a per-target table, the explicit
   *left alone* list with reasons, and the regeneration commands the user now
   needs (`pnpm install`, `npx playwright install`, …).

Order matters: **delete `node_modules` BEFORE `pnpm store prune`.** While
`node_modules` exists, the store's packages are still referenced and the prune
frees ~nothing.

## Root territory and other accounts

Some of the biggest wins live where your shell can't act: other user accounts
(190 GB observed), `/usr/local`, root-owned stores. Rules of engagement:

- **Never escalate yourself.** Write ONE script with receipts + heartbeat and
  hand the user a single `sudo bash …` command. `purge-live.sh` (dry-run by
  default, `--home` for cache dirs) is the template. Twenty sudo one-liners is
  how mistakes happen; one auditable script is how they don't.
- **Read ≠ write.** A 755 home on another account measures fine and then every
  `rm` fails — deletion needs write on the parent dir, owned by the other uid.
  Check `ls -ld` before promising anything.
- **Full Disk Access defeats TCC, not unix perms** — and it's per-app. The
  no-terminal-restart route and both walls: `references/missing-space.md`.
- A dormant account is still a person's data: marker-gated dev artifacts and
  cache-class subdirs only (targets.md), even when the user owns the account.
  Voice memos, message history, and sync state all masquerade as fat app data.

## Broadcast gating (same three tiers as the rest of the house)

- **scan** (`scan.sh`) — read-only, always safe, works with a wedged Docker.
- **dry-run** (`reclaim.sh`, default) — prints exactly which paths it would
  remove and their sizes. Removes nothing.
- **execute** (`reclaim.sh --execute`) — the only path that deletes, and only
  ever Tier 0 allowlisted paths. It refuses Tier 1/2 by construction; those stay
  manual and asked-for.

## Docker

Docker is usually the single biggest win and the most dangerous. A full disk
kills its VM boot, the backend never retries, and **reopening the app does not
fix it** — the stale backend still holds the socket and survives a normal quit.

```bash
bash <path-to-this-skill>/scripts/docker-revive.sh   # restarts only; deletes nothing
```

Once the daemon answers, prune in order of safety:

| Command | Frees | Cost |
|---|---|---|
| `docker builder prune -a -f` | build cache | nothing, pure cache |
| `docker image prune -f` | dangling layers | nothing |
| `docker image prune -a -f` | ALL images no container references | re-pull on next start; can be many GB of download |
| `docker volume prune -a -f` | all unused volumes | **destroys local DB data — enumerate and filter by name FIRST** |

`docker volume prune -a` is indiscriminate: a volume counts as "unused" merely
because its stack isn't running right now, so it will happily delete an active
project's local database. Always `docker system df -v`, list volumes by name,
and delete a filtered set — never the blanket prune.

Docker Desktop 4.8x trims `Docker.raw` itself after a prune, so the host space
appears without extra work. Give it a moment before concluding it didn't.

## Files

| Path | What |
|---|---|
| `scripts/scan.sh` | Read-only measurement. Ranked table by size with tier labels, plus `df`. Safe with a dead Docker daemon. |
| `scripts/reclaim.sh` | Tier-0 reclaims, grouped: `pm`, `browsers`, `sim`, `appcache`, `all` (those four), plus opt-in `langcache` and `builds`. Dry-run default; `--execute` to act. Hard-refuses Tier 1/2 paths. |
| `scripts/reclaim.sh self-test` | Asserts every Tier-1/2 refusal actually fires (forced dry-run). Run it after editing the denylist or any guard — a guard that fails open still reads as protection. `purge-live.sh self-test` does the same for the sudo-territory script. |
| `scripts/docker-revive.sh` | Fixes the stale-backend wedge (hard-kill + relaunch + poll). Restarts only; deletes nothing. |
| `scripts/scan-live.sh` | Live per-entry size scan: parallel `du` workers, prints each entry as measured, ranked table at the end. Sudo-safe for other accounts. Read-only. |
| `scripts/purge-live.sh` | Parallel Tier-0 purge with per-item receipts + 3s heartbeat. Dry-run default, `--execute` to act, gates on running dev servers; `--home` adds package caches plus an **allowlisted** set of `Library/Caches` names — never the whole dir (Spotify offline music and Playwright browsers live there, both Tier 1, both reported instead of deleted). Same denylist-by-construction as reclaim.sh, plus remotion/media gates on `out`/`dist`/`build`; `self-test` asserts every refusal. The one to hand users for sudo territory. |
| `references/targets.md` | Full target catalog: path, tier, typical size, what breaks, regeneration command. Includes the profile-preserving cache-class list for browsers/Electron. |
| `references/gotchas.md` | The traps: zsh glob abort, hardlink accounting, missing `timeout`, hanging Docker CLI, locale-broken `printf`, macOS `head -n -1`, print-only guards, sudo glob expansion, APFS lazy reclaim, simctl runtimes. Read before writing any new delete command. |
| `references/missing-space.md` | When totals don't reconcile with `df`: Storage panel first, units, permission-blind `du`, the four usual suspects and how to actually test them, TCC vs unix perms, root-territory rules. |

## Reporting

Always close with: `df` before → after and total reclaimed; a per-target table;
an explicit **left alone** list with a reason each; and the regeneration
commands. The "left alone" list is what makes the cleanup trustworthy — it shows
the user you found their data and chose not to touch it.
