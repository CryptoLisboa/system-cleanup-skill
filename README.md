# system-cleanup

A [Claude Code](https://claude.com/claude-code) agent skill that reclaims disk space on macOS **safely**: measure every target first, then delete only what is provably regenerable, tiered by reversibility.

Disk cleanup fails in two directions — too timid (scan, report, free nothing) or too eager (blow away something irreplaceable). This skill fixes the tiering so neither happens, and encodes the macOS traps that make cleanup commands *silently no-op* while looking like they worked.

## The safety model

Everything is tiered by **reversibility, not size**:

| Tier | What | Action |
|---|---|---|
| **0 — pure cache** | Package-manager caches, browser HTTP caches, build output, updater staging, simulator caches | Cleared freely — regenerates itself on next use |
| **1 — expensive to regain, or local state** | Docker images/volumes, Playwright browsers, simulator devices, offline music, anything needing a multi-GB re-download | **Asked per target, with the real cost stated** |
| **2 — irreplaceable** | Trash, Downloads, Documents, personal media, rendered deliverables, credentials, git-tracked files | **Never deleted.** Reported and handed back to you |

Iron rules the scripts enforce *by construction* (not by good intentions):

- **Never empties the Trash** — not even when asked. It's your last undo.
- Measure before delete, always; verify with `df` deltas, never `du` of what was removed (hardlinks lie).
- Ambiguous names resolve by project marker, not directory name — `out/` is build output in a Foundry project and the finished render in a Remotion project.
- Deletion scripts refuse Tier 1/2 paths via denylists, and each ships a `self-test` mode that asserts every refusal still fires.
- No silent long-running commands: live per-item receipts + a 3-second heartbeat.

## Install as a Claude Code skill

```bash
git clone https://github.com/CryptoLisboa/system-cleanup-skill.git ~/.claude/skills/system-cleanup
```

Then ask Claude Code things like *"free up space"*, *"what's eating my disk"*, *"docker won't start, disk full"*, *"System Data is huge, where did my space go"* — the skill triggers automatically.

## Use the scripts standalone

No Claude required — the scripts are plain bash (macOS `/bin/bash` 3.2 compatible):

```bash
S=~/.claude/skills/system-cleanup/scripts   # or wherever you cloned it

bash $S/scan.sh                          # read-only ranked table of every target + df
bash $S/reclaim.sh all                   # dry-run: package managers, browsers, sim, app caches
bash $S/reclaim.sh all --execute         # apply (Tier 0 only, denylist-guarded)
bash $S/reclaim.sh builds --root ~/dev   # opt-in: build output in repos (marker-gated)
bash $S/purge-live.sh ~/dev              # dry-run: node_modules + build dirs, live receipts
bash $S/purge-live.sh ~/dev --execute    # parallel delete with heartbeat + df-delta report
bash $S/docker-revive.sh                 # fix Docker Desktop's full-disk wedge (restarts only)
bash $S/scan-live.sh /Users/other        # live per-entry scan (sudo-safe for other accounts)
```

After editing any guard or denylist:

```bash
bash $S/reclaim.sh self-test
bash $S/purge-live.sh self-test
```

Both must print `all assertions passed` before `--execute` is trusted again.

## What's inside

| File | Purpose |
|---|---|
| `SKILL.md` | The skill entry point: tiers, iron rules, workflow, Docker order-of-safety |
| `scripts/scan.sh` | Read-only measurement — ranked, tier-labelled table |
| `scripts/reclaim.sh` | Tier-0 reclaims by group, dry-run default, denylist + self-test |
| `scripts/purge-live.sh` | Parallel purge of dev artifacts with live receipts; the one to hand users for sudo territory |
| `scripts/scan-live.sh` | Live per-entry size scan, parallel workers |
| `scripts/docker-revive.sh` | Un-wedge Docker Desktop after a full disk (deletes nothing) |
| `references/targets.md` | Full target catalog: path, tier, typical size, regeneration cost |
| `references/gotchas.md` | The traps: zsh glob abort, hardlink accounting, hanging Docker CLI, locale-broken printf, and more |
| `references/missing-space.md` | When `du` totals don't reconcile with `df`: units, permission-blind measurement, the usual suspects |

## Why the gotchas file exists

Every rule in there was learned from a real failure: a guard that word-split on a path with spaces and reclassified finished video renders as disposable build output; a blanket `docker volume prune` that deleted an active project's local database; a `du -sh $(ls -A)` that silently dropped `Docker Desktop` from the scan because of word splitting. Read it before writing any new delete command.

## Requirements

- macOS (paths and traps are macOS-specific; `df`/APFS assumptions included)
- bash (scripts target macOS's stock bash 3.2 — no `wait -n`, no coreutils `timeout`)

## Disclaimer

These scripts delete files (`rm -rf`) when run with `--execute`. Dry-run is the default everywhere, denylists guard the irreplaceable, and self-tests assert the guards — but you run them at your own risk. Read the dry-run output before applying.

## License

[MIT](LICENSE)
