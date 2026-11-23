# Gotchas — read before writing any new delete command

Every one of these was hit for real. Most fail *silently*: the command looks
like it worked and freed nothing.

## `printf %f` respects locale — receipts lie in comma-decimal locales

```bash
printf "%.2f GB" 0.502285
# printf: 0.502285: invalid number   → prints "0,00 GB"
```

In a locale with comma decimal separators, shell `printf` rejects dot-decimal
arguments and emits zero. The deletes still ran — only the receipt lied, which
is worse: the user reads "0,00 GB" next to a 10 GB delete. **`export LC_ALL=C`
at the top of every script that prints numbers.** (Or do the formatting in
`awk`, which is locale-stable for this.)

## macOS `head` has no `head -n -1` — "all but last" loops silently no-op

```bash
ls | sort -V | head -n -1        # GNU-only
# macOS: "head: illegal line count -- -1" → loop body never runs
```

The failure mode is the bad one: the "delete all versions except the newest"
loop iterates zero times, deletes nothing, prints nothing, and the run looks
complete. Use `sed '$d'` for all-but-last. Same GNU-ism family as the missing
`timeout` below.

## A guard that only PRINTS is not a guard

A purge script checked for running dev servers, **printed** the `next-server`
it found — then deleted its `.next` anyway and killed the server mid-request.
The check read as protection in review and protected nothing.

If a script checks a precondition, the check must **gate** (refuse or branch),
not narrate. And before deleting build output at all, look for the processes
that hold it open — `next-server`, `vite`, `webpack`, `vitest` workers — and
refuse while they run. `purge-live.sh` does this (override: `--force`).

## `sudo cmd /other/700dir/*` fails before sudo runs

```bash
sudo du -sk /Users/other/Downloads/*
# zsh: no matches found: /Users/other/Downloads/*
```

The glob expands in the **caller's** shell, which cannot read the 700 dir —
sudo never executes. Move the expansion root-side:

```bash
sudo sh -c 'find /Users/other/Downloads -mindepth 1 -maxdepth 1 -exec du -sk {} +'
```

## `awk '{print $2}'` truncates paths at the first space

`du` output for `…/Library/Application Support` prints as
`…/Library/Application` — 20 identical truncated rows, all names lost. Blank
the size field and take the rest instead:

```bash
... | awk '{kb=$1; $1=""; sub(/^[ \t]+/,""); printf "%8.2f GB  %s\n", kb/1048576, $0}'
```

(Why: `du` writes `size<TAB>path`, but awk's **default** FS splits on every
run of spaces *and* tabs, so a path's internal spaces become field breaks.
Forcing the FS to the real separator — `awk -F'\t' '{print $2}'` — also works.)

## APFS clones: `du` can overstate by 15x

41 Chrome `code_sign_clone` dirs measured 85 GB with `du`; deleting all of them
moved `df` by 5.7 GB. They are copy-on-write clones of one app bundle, so each
reports full size while sharing almost every block. Same family as the
hardlink trap below, bigger ratio. Never promise the `du` number for anything
under `/private/var/folders/*/*/X` — delete, then report the `df` delta.

## Space that vanishes between cleanups lives outside `$HOME`

When free space drops tens of GB in days and every home-dir total looks the
same as last time, measure `/private/var/folders` before theorising. It holds
per-user temp and cache dirs that no `$HOME` scan touches (87 GB seen there).

## A pgrep-based wait loop matches its own shell

```bash
until ! pgrep -f 'docker image prune -a'; do sleep 3; done   # never ends
```

`pgrep -f` matches the wrapper shell whose command line contains the pattern,
so the loop waits on itself. Wait on the PID instead:
`until ! kill -0 "$pid" 2>/dev/null; do sleep 3; done`.

## `docker info` can exit 0 on a broken daemon

The backend can answer the socket while the engine is down, so exit status
alone reads as "up". Require a real version string **and** a server round-trip
(`docker system df`). `docker-revive.sh` does both.

## APFS reclaims lazily — an immediate `df` can read delta 0

A verified multi-GB delete showed `DELTA_MB=0`, then the space appeared a
minute later. Sleep ~5s before the closing `df`, and if the delta still looks
wrong, say "re-check in 60s" rather than concluding the delete failed. (Also
observed after `simctl runtime delete`: 0 immediately, 7 GB shortly after.)

## `sudo rm` cannot delete a CoreSimulator runtime

`rm -rf` on `/Library/Developer/CoreSimulator/…` returns EPERM **even as
root**, and `hdiutil detach` reports "Resource busy" because
CoreSimulatorService silently re-attaches the image after every unmount. Not
SIP. The working route needs no sudo — go through simctl directly (plain
`xcrun simctl` can't find it without full Xcode):

```bash
/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/simctl runtime list
/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/simctl runtime delete <UUID>
```

simctl hands the request to the root-owned service, which detaches and unlinks
itself. First invocation can take >2 min while the service starts — not hung.

## Reading another account ≠ being able to delete in it

A 755 home lets you traverse and measure every world-readable file — and then
every `rm` fails, because unlinking needs **write on the parent directory**,
which belongs to the other uid. Full Disk Access doesn't change this either
(FDA defeats TCC, not unix permissions — see missing-space.md). Check
`ls -ld` on the target before promising a purge; if it's another uid, the
answer is a sudo script the user runs (`purge-live.sh`), not your shell.

## zsh aborts the whole command on a non-matching glob

```bash
rm -rf ~/Library/Caches/Google/Chrome/Default/Cache/* ~/Library/Caches/Google/Chrome/ShaderCache/*
# zsh: no matches found: .../ShaderCache/*
```

`ShaderCache` didn't exist, so **zsh refused the entire command and deleted
nothing** — including the paths that did exist. Exit status looks unremarkable.

Fixes, in order of preference:
1. `rm -rf` the **directory itself**, not `dir/*`.
2. `find <dir> -mindepth 1 -delete`.
3. `#!/usr/bin/env bash` scripts (bash leaves unmatched globs literal; the
   `*'*'*` guard in `safe_rm` then catches them).
4. `setopt null_glob` if you must stay in zsh.

Always re-measure after a delete. Don't trust the absence of an error.

## `GROUPS` is a bash special variable — never use it as your own

```bash
GROUPS=()            # does NOT clear it
GROUPS+=("$1")       # appends to the user's numeric group IDs
# -> ${GROUPS[0]} == 20   (macOS `staff`), and your parsed arg is at index 16
```

Bash maintains `GROUPS` as the current user's group-ID list. Assigning to it is
silently ignored, so a flag parser using `GROUPS` for selected groups reads back
group IDs and every dispatch falls through to "unknown group: 20". Same hazard
with `SECONDS`, `LINENO`, `RANDOM`, `PIPESTATUS`, `BASH_*`, `PWD`, `UID`,
`HISTFILE`, `IFS`, `FUNCNAME`. Name script variables something boring
(`PICKED`, `SELECTED`).

## Unquoted glob expansion word-splits on spaces, killing safety guards

```bash
has_glob() { for g in $1; do [ -e "$g" ] && return 0; done; return 1; }   # BROKEN
has_glob "$proj/remotion.config.*"
```

With `$proj` = `~/dev/client demos/promo reel/video`, `for g in $1` splits on
the spaces into `~/dev/client`, `demos/promo`, `reel/video/remotion.config.*` — none
exist, so the function returns false. The guard that was supposed to protect
rendered video output became a no-op, and 46 MB of finished `.mp4` renders got
classified as disposable build output.

Space-safe instead:

```bash
has_file() { [ -n "$(find "$1" -maxdepth 1 -name "$2" -print -quit 2>/dev/null)" ]; }
has_file "$proj" 'remotion.config.*'
```

**A guard that fails open is worse than no guard** — it reads as protection in
the code review and deletes anyway. Test every protective check against a path
containing a space. `reclaim.sh self-test` exists for exactly this reason:

```bash
bash scripts/reclaim.sh self-test    # asserts the refusals actually fire
```

## Gitignored does not mean disposable

Rendered deliverables are routinely gitignored — build output and finished work
product look identical to `git check-ignore`. `out/` in the Remotion project was
both gitignored *and* the finished `.mp4` renders. So gitignore status is
evidence, not proof: check for media content (`*.mp4`, `*.mov`, `*.pdf`, …)
before trusting it, and let media presence override the gitignore signal.

## `du -sh dir/*` silently skips dotfiles

`~/Library/Caches/*` misses nothing important, but a code root's `*` misses the
dotdir agent/tool workspaces (often the largest thing there), and `$HOME/*`
misses every dotdir. Use:

```bash
cd "$dir" && find . -mindepth 1 -maxdepth 1 -exec du -sh {} + 2>/dev/null | sort -rh | head -15
```

This is how a multi-GB directory hides from a scan.

Do **not** "fix" it with `du -sh -- $(ls -A)`. That includes dotfiles but the
unquoted command substitution word-splits on spaces, so `Docker Desktop` becomes
two nonexistent args and the entry disappears from the scan entirely — the exact
failure you were trying to avoid, now silent under `2>/dev/null`. `find
-mindepth 1 -maxdepth 1` handles both.

## Hardlinks: `du` overstates, `df` is truth

pnpm's store and each `node_modules` are **hardlinks to the same inodes**.
Space frees only when the *last* link dies, so:

- `du` of `node_modules` + `du` of the store double-counts.
- Deleting only the store frees ~nothing while `node_modules` still exists.
- **Order matters: delete `node_modules` first, then `pnpm store prune`.**
  Reversed, the prune sees every package as still referenced and frees ~0.

Report `df -k` before/after deltas, never a sum of `du`.

## macOS has no `timeout`

`timeout 30 docker ps` → `command not found: timeout`, and the exit status of
the pipeline can still read as success. No coreutils by default. Use the
`with_timeout` helper in `scan.sh` / `docker-revive.sh` (background + poll +
`kill -9`), or run in the background and poll.

## A dead Docker daemon hangs the CLI forever

`docker ps`, `docker system df`, `docker images` do **not** time out when the
daemon is down — they block indefinitely. The eventual error is:

```
Cannot connect to the Docker daemon at unix:///Users/<you>/.docker/run/docker.sock. Is the docker daemon running?
```

Never run a bare `docker` command during cleanup. Wrap it in `with_timeout`, or
run it backgrounded and poll.

## The Docker stale-backend wedge (full disk → permanently broken Docker)

Sequence: disk fills → Docker Desktop's Linux VM can't boot → **the backend
never retries** → the app appears to run but every `docker` call hangs. Freeing
space does not fix it. **Reopening the app does not fix it** either, because the
stale backend still holds the socket.

Diagnosis:

| Signal | Meaning |
|---|---|
| `com.docker.backend` alive, no VM process | VM never booted |
| backend start time is a **previous day** | it's stale, not starting up |
| `com.docker.backend.log` loops `returning engine error:` with an *empty* message | apiproxy up, `dockerd` never answered |
| an `error-dialog` Docker Desktop process | it already gave up |

Fix — and the load-bearing step is the hard kill by PID, because
`osascript quit` and even `pkill -f com.docker.backend` can leave it alive:

```bash
bash scripts/docker-revive.sh
```

Once revived, the daemon comes up in ~10s. `Docker.raw` self-trims after a
prune on Docker Desktop 4.8x (observed 27 GB → 7.4 GB), so don't hand-delete the
disk image to reclaim space.

## `docker volume prune -a` deletes active projects' data

A volume is "unused" if no **running** container references it. Your active
project's local Postgres counts as unused the moment its stack is stopped. A
blanket prune took `supabase_db_<project>` for a project with commits that same
week.

Always: `docker system df -v` → list volumes by name → delete a **filtered**
set. The gain over selective is usually trivial (170 MB out of 3.8 GB in the
observed case) and the downside is someone's database.

## `git check-ignore` resolves paths against the repo, not your cwd

```bash
git -C "$repo" check-ignore -q "./apps/web/.next"    # WRONG — relative to $repo
git -C "$repo" check-ignore -q "$abs_path"           # right
```

Passing a cwd-relative path makes genuinely-ignored build dirs report as
tracked, so a "safe" filter silently protects nothing and labels everything
wrong. Always pass absolute paths.

## Directory names don't determine tier — project markers do

| Name | Tier 0 when | Tier 2 when |
|---|---|---|
| `out/` | `foundry.toml` sibling (compile output) | `remotion.config.*` sibling (**rendered video deliverable**) |
| `artifacts/` | `hardhat.config.*` / `foundry.toml` sibling | otherwise unknown |
| `target/` | `Cargo.toml` sibling | otherwise unknown |
| `dist/`, `build/` | `git check-ignore` says ignored | git-tracked → it's source |
| `cache/` | Foundry project | app data anywhere else |

No marker and no gitignore proof → **skip it**.

## `.vercel` is not build output

`.vercel/output` is build output (Tier 0). `.vercel/project.json` is the
**project link** — delete it and the repo is unlinked from Vercel. Only ever
remove `.vercel/output`.

## `xcrun simctl` may not exist

With Command Line Tools but no full Xcode:

```
xcrun: error: unable to find utility "simctl", not a developer tool or in PATH
```

Guard `simctl` calls. `CoreSimulator/Caches` is still safe to `rm` directly;
`CoreSimulator/Devices` holds installed simulator state (Tier 1).

## Caches that aren't caches

Living under `~/Library/Caches` does not make something disposable:

- `com.spotify.client` — offline downloads. Deleting costs the user their
  offline music, and it's unavailable until re-downloaded.
- `ms-playwright` — browser binaries; multi-GB re-download via
  `npx playwright install`.
- `*.ShipIt` — genuinely disposable updater staging (can be >1 GB).

## `docker image prune -a` scope

It removes every image **no container references** — including stopped
containers' images, which are kept. Reclaim is often larger than expected
(14.96 GB observed) but the cost is a full re-pull; a multi-version Supabase
stack is ~10 GB of download on the next `supabase start`. State that cost when
asking.
