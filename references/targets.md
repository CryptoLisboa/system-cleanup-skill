# Target catalog

Tier: **T0** clear freely · **T1** ask first, state the cost · **T2** never
delete, report to the user.

Sizes are what was actually observed on one heavily-used dev Mac — useful for
knowing what's abnormal, not a promise.

## T0 — package managers

| Path | Seen | Regenerate |
|---|---|---|
| `~/.npm` | 3.8 G | `npm cache clean --force`, refills on install |
| `~/Library/pnpm/store` | 1.7 G | `pnpm store prune` — **after** deleting `node_modules` |
| `~/Library/Caches/pnpm` | 415 M | auto |
| `~/.yarn/berry/cache` | 666 M | `yarn install` |
| `~/Library/Caches/Yarn`, `~/.cache/yarn` | — | `yarn install` |
| `~/.bun/install/cache` | — | `bun install` |
| `~/Library/Caches/Homebrew` | 73 M | `brew cleanup --prune=all` |
| `~/Library/Caches/pip` | 59 M | auto |
| `~/Library/Caches/node-gyp` | 126 M | re-downloads node headers |
| `~/Library/Caches/typescript` | 102 M | auto |
| `~/Library/Caches/electron` | 84 M | re-downloads electron |
| `~/Library/Caches/hardhat-nodejs` | 32 M | re-downloads solc |
| `~/Library/Caches/ffmpeg-static-nodejs` | 37 M | re-downloads ffmpeg |

## T0 — browsers (HTTP cache only)

| Path | Seen |
|---|---|
| `~/Library/Caches/Google/Chrome` | 3.1 G |
| `~/Library/Caches/BraveSoftware` | 48 M |
| `~/Library/Caches/Microsoft Edge`, `Firefox`, `Arc` | varies |

Profiles, history, passwords, and extensions live in
`~/Library/Application Support/…` — **never** in `Caches`. Clearing the cache
costs a slower first page load, nothing else. Quitting the browser first is
tidier but not required.

## T0 — cache-class subdirs inside app profiles (profile-preserving purge)

Chromium browsers and Electron apps keep multi-GB caches **inside**
`~/Library/Application Support/<app>/`, next to real state. The dir as a whole
is T2, but these subdirs are pure cache and can go per profile — bookmarks,
history, cookies, and logins survive untouched:

```
Cache  Code Cache  GPUCache  Media Cache  ShaderCache  GrShaderCache
DawnCache  DawnGraphiteCache  DawnWebGPUCache  blob_storage
Service Worker/CacheStorage  Service Worker/ScriptCache
CachedData  CachedExtensionVSIXs  logs
```

Apply to `Google/Chrome/{Default,Profile *}/`, `BraveSoftware/Brave-Browser/…`,
`Microsoft/Edge/…`, and Electron apps (`discord`, `Code`, `Cursor`, `Notion`,
`Figma`, `Postman`, `Slack`, `obs-studio`). Observed: 17.9 GB across one
account's profiles with zero state loss. Never touch siblings like `Bookmarks`,
`History`, `Login Data`, `Cookies`, `IndexedDB`, `Local Storage`.

## T0 — superseded version dirs (keep newest, delete the rest)

| Path | Seen | Note |
|---|---|---|
| `~/.local/share/claude/versions/` | 0.97 G | old Claude Code versions; keep highest |
| `~/Library/Application Support/svm/` | 0.96 G | old Solana toolchains; keep highest |
| `~/Library/Caches/*.ShipIt` | 1.5 G | already in app caches above |

Pattern: `ls -1 | sort -V | sed '$d'` — **not** `head -n -1`, which silently
no-ops on macOS (gotchas.md).

## T0 — Xcode / simulators

| Path | Seen | Note |
|---|---|---|
| `~/Library/Developer/Xcode/DerivedData` | — | rebuilt on next build |
| `~/Library/Developer/CoreSimulator/Caches` | 2.9 G | usually the whole CoreSimulator footprint |
| `xcrun simctl delete unavailable` | — | guard it; `simctl` is absent with CLT-only |

## T0 — app caches / updater staging

| Path | Seen | Note |
|---|---|---|
| `~/Library/Caches/*.ShipIt` | 1.5 G + 423 M | Electron updater staging (editors, chat apps, …) |
| `~/Library/Caches/GeoServices` | 74 M | Apple Maps tiles |
| `~/Library/Caches/Adobe` | 125 M | |
| `~/Library/Caches/<vpn-client-bundle-id>` | 245 M | VPN clients cache aggressively |
| `~/Library/Caches/com.apple.helpd` | 23 M | |

## T0 — build output in repos

| Name | Safe when |
|---|---|
| `.next`, `.turbo`, `.parcel-cache`, `.svelte-kit`, `.nuxt`, `.angular`, `coverage` | always |
| `.vercel/output` | always — but **never** `.vercel/project.json` (T2, it's the project link) |
| `artifacts`, `out`, `cache` | `foundry.toml` or `hardhat.config.*` sibling |
| `target` | `Cargo.toml` sibling |
| `dist`, `build` | `git check-ignore` confirms ignored (absolute path!) |
| `node_modules` | always regenerable, but costs a reinstall → opt-in flag |

## T1 — ask first

| Path / action | Seen | Real cost |
|---|---|---|
| `docker image prune -a` | 15 G | full re-pull; a multi-version Supabase stack is ~10 G of download |
| `docker volume prune` | 3.8 G | **local databases.** Enumerate by name, delete a filtered set, never blanket |
| `~/Library/Caches/ms-playwright` | 2.5 G | `npx playwright install` |
| `~/Library/Caches/com.spotify.client` | 562 M | loses offline downloads |
| `~/Library/Application Support/Spotify` | **10.8 G** | the offline-song store itself; re-streams on demand. Far bigger than the Caches entry |
| `.dmg`/`.pkg` installers in Downloads | 1.7 G | re-downloadable, but Downloads is T2 ground — list them, let the user fire the delete |
| `/usr/local/Homebrew` | 0.95 G | stale x86/Rosetta brew on ARM Macs. Verify dead first: no `/usr/local/Cellar`, no `/usr/local/bin/brew`, `brew config` points at `/opt/homebrew` |
| `/usr/local/share/dotnet` | 3.6 G | only if every SDK is end-of-life (`ls` the versions) and no .NET work exists; sudo, so user runs it |
| `~/Library/Developer/CoreSimulator/Devices` | 192 M | installed simulator state, app data |
| `~/Library/Developer/Xcode/iOS DeviceSupport` | — | re-extracted per device on next attach |
| `~/.rustup` | — | toolchain re-download |
| `~/.m2/repository` | — | full Maven re-resolve |
| `~/.cargo/registry`, `~/go/pkg/mod`, `~/.gradle/caches` | — | dependency re-download (`langcache` group) |

## T2 — never delete

| Path | Why |
|---|---|
| `~/.Trash` | the user's last undo. **Never empty it, even if asked.** Report the size. |
| `~/Downloads` | personal files. Report the biggest, let them choose. |
| `~/Documents`, `~/Desktop`, `~/Movies`, `~/Pictures`, `~/Music` | personal data |
| `~/Library/Developer/Xcode/Archives` | shipped build archives; needed to re-sign/symbolicate |
| `.vercel/project.json` | Vercel project link |
| Rendered deliverables (`out/` in a Remotion project, exported video//images) | the actual work product |
| `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config`, `~/.claude` | credentials and config |
| `~/Library/Application Support`, `Keychains`, `Mail`, `Messages`, `Mobile Documents` | app state, mail, iCloud Drive (cache-class subdirs above are the only exception) |
| `~/Library/Application Support/com.apple.voicememos` | **personal audio recordings** — looks like fat app data (1.3 G seen), no cloud copy guaranteed |
| `~/Library/Application Support/WhatsApp` | local message history |
| `~/Library/Application Support/Dropbox` | sync state — deleting forces a full re-sync, frees nothing durable |
| `~/.nvm/versions` on an account someone still uses | working Node runtimes, not cache — breaks `node` until reinstalled. T1 on dormant accounts |

## Docker footprint

`~/Library/Containers/com.docker.docker` holds everything (27 G observed, 7.4 G
after a prune). Reclaim **through the daemon**, not by deleting `Docker.raw` —
Docker Desktop 4.8x trims the sparse image itself after a prune.

Safety order: `builder prune -a` → `image prune` (dangling) →
`image prune -a` (re-pull cost) → volumes (**filtered by name only**).

## Where to look when the catalog comes up short

```bash
cd "$HOME" && find . -mindepth 1 -maxdepth 1 -exec du -sh {} + 2>/dev/null | sort -rh | head -12
```

Dotdirs matter — a bare `*` hides every one of them, which is exactly where
large agent/tool workspaces live (5.5 G observed in a single dotdir under a
code root).

Also worth a look, outside `$HOME`: `/Applications` (25 G), `/Library` (31 G),
`/usr/local`, `/opt`. These usually need `sudo` to measure fully — ask the user
to run it rather than trying to escalate.

**Other user accounts** (`/Users/<other>`) can dwarf everything above — 190 GB
observed, invisible to a same-user `du`. The Storage panel's "Other Users &
Shared" line is the tell. Full playbook: `references/missing-space.md`. Biggest
single wins observed there: `Library/Caches` 42.8 G, Spotify 10.8 G, Chrome
10 G, a 24.7 G dev tree of `node_modules`.

If the catalog AND the extra looks still don't reconcile with `df`, stop
guessing — read `references/missing-space.md` and reconcile properly.
