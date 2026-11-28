# Missing space — when the totals don't add up

Read this when measured directories sum to far less than what `df` says is
used. The gap is almost never hidden data. It is almost always **measurement
error**, and there is a fast path to proving which kind.

The case that built this file: 280 GB "unaccounted". Seven parallel scan agents
spent 48 minutes on snapshot/swap/sparse-file theories. The actual answer was
visible in one screenshot the whole time.

## Step 0 — ask for the Storage panel FIRST

**System Settings → General → Storage.** Ask the user for a screenshot before
running anything. It is instant, needs no privileges, and reports categories no
unprivileged tool can compute — most importantly **"Other Users & Shared"**,
which is invisible to a `du` run as the current user. In the observed case it
answered the entire question in one line: `Other Users & Shared: 190.13 GB`.

Sanity-check its sum against `df` before trusting either (see units below).

## "Another account shows far more free space"

It can't. Every account on the Mac shares one APFS container, so real free
space is identical from all of them (`diskutil info /` → `Container Free
Space`). A much bigger number on one account is almost always:

1. **Purgeable counted as available.** Finder and the Storage panel can add
   space macOS *could* evict — iCloud-optimised files, local snapshots, caches
   — and that varies per account. `df` shows only what is free now.
2. **A "used" figure read as free.**
3. **An old reading.**

Observed: one account "remembered" ~300 GB free while `df`, `diskutil` and
Finder all agreed on 37–50 GB. Ask for that account's Storage screenshot
before chasing it.

## Step 1 — know your units before comparing anything

| Tool | Unit |
|---|---|
| `df -h` / `df -k` | **GiB** (1024³) |
| `diskutil info` | **GB** (10⁹) |
| Storage panel | **GB** (10⁹) |
| `du -k` | KiB → divide by 1048576 for GiB |

"401 GB used" from `df` and "430.6 GB used" from `diskutil` are **the same
number**. Chasing that 30 GB gap is chasing an exchange rate.

## Step 2 — `du` is permission-blind: floors, not totals

`du` silently reports **0** for every directory it cannot enter. With stderr
suppressed, "empty" and "unreadable" are indistinguishable. Two rules:

1. **Never `2>/dev/null` on an audit `du`.** Capture stderr. The
   permission-denied list IS the finding — in the observed case, 338 denied
   subtrees, and the error paths themselves revealed a second user account and
   a system-wide PostgreSQL install nobody knew about.
2. **Label every unprivileged measurement a floor.** A second account measured
   35.56 GB unprivileged; the truth was ≥54 GB. Report as "≥ X GB (unprivileged
   floor)", never as the size.

Count and group the blind spots:

```bash
du -d 1 -k -x /System/Volumes/Data 2>&1 >/dev/null | grep -c "Permission denied"
du -d 2 -k -x <dir> 2>&1 >/dev/null | grep "Permission denied" | cut -d/ -f1-5 | sort | uniq -c | sort -rn
```

## Step 3 — the usual suspects, and how to actually test each

Test these by measurement, not by reputation. In the observed case **all four
were innocent** — the entire gap was Step 2.

**APFS local snapshots.** Trap: `tmutil listlocalsnapshots /` lists snapshots
for the whole **volume group**, so OS-update snapshots living on the System
volume look like they're on Data. The per-volume truth:

```bash
diskutil apfs listSnapshots /System/Volumes/Data
```

If Time Machine's destination is a network share, local snapshots don't
accumulate at all.

**Swap.** `/System/Volumes/VM` is a **separate APFS volume** (`disk3s6`-style)
— excluded from Data's used-bytes by construction. Only `sleepimage` under
`/private/var/vm` counts against Data. Don't book swap against the gap.

**Sparse disk images (Docker.raw etc.).** `du` already reports **allocated**
blocks, not logical size. A 32 GB-logical Docker.raw allocating 11.5 GB
contributes 11.5, and the 20 GB "difference" does not exist on disk. Check both:

```bash
du -h Docker.raw            # allocated — the real footprint
ls -lh Docker.raw           # logical — the cap, not the cost
```

**Deleted-but-open files.** Real but almost always small. Dedupe by inode —
the raw sum double-counts a file once per holding process:

```bash
lsof -nP +L1 | awk '{print $7, $8}' | sort -u | awk '{s+=$1} END{printf "%.2f GiB\n", s/1073741824}'
```

## Step 4 — reconcile in a table, and keep a residual line

Build: region | GiB | source-of-measurement. Include an explicit **"still
unaccounted"** row. If the residual is large after Steps 0–3, the answer is a
permission wall (second account, root-owned dir), not exotica. Get the owner or
root to measure — never guess a number into the table.

## The two permission walls (they are different problems)

**Wall 1 — TCC/privacy** ("Operation not permitted" even under sudo):
per-APP, not per-user. Root does not bypass it. Fix: grant Full Disk Access to
the *hosting app* of the shell. Trick that avoids restarting a busy terminal:
grant FDA to **Claude Desktop** (`/Applications/Claude.app`), quit and reopen
it, and resume the session from Claude Desktop — the session inherits the
app's FDA and the terminal keeps its other sessions. After FDA: Trash,
Messages, Mail, Spotlight, and other-user 755 dirs all read normally.

**Wall 2 — unix permissions** (mode 700, other-uid files): FDA does nothing
here; only root or the owner passes. And **read ≠ write**: a 755 home lets you
traverse and measure another account, but every `rm` still fails — deletion
needs write on the *parent directory*, owned by the other uid. Don't discover
this mid-purge; check `ls -ld` first.

Some volume-root stores resist **even root** (SIP): `.DocumentRevisions-V100`,
`.Spotlight-V100` return nothing to `sudo du` — it silently prints no line for
them. Don't chase these; they are not addressable.

## Working in root territory: hand the user a script

When targets need sudo (other accounts, `/usr/local`), do not try to escalate
and do not feed the user twenty one-liners. Write ONE script and have them run
it with sudo. The script must:

- `export LC_ALL=C` at the top (see gotchas: locale breaks printf receipts)
- print a **per-item receipt** (size + path) as each delete lands
- **heartbeat every ~3s** — items done / total, GB freed, GB free. A silent
  long run is indistinguishable from a hang, and the user will kill it.
- measure freed space by **df delta**, and sleep ~5s first (APFS reclaims
  lazily; delta can read 0 immediately after a successful delete)
- end with an explicit NOT-touched list

`scripts/purge-live.sh` and `scripts/scan-live.sh` are these rules, ready to
run — point the user at them instead of writing new ones.

Glob trap when *composing* sudo one-liners for the user: `sudo du /other/700dir/*`
fails with `zsh: no matches found` — the glob expands in the **caller's**
shell, which can't read the dir, before sudo ever runs. Wrap the whole
expansion root-side: `sudo sh -c 'find <dir> -mindepth 1 -maxdepth 1 -exec du -sk {} +'`.

## A dormant account is still a person's data

Even with authorization ("it's my old account"), purge only marker-gated dev
artifacts and named caches. Browser caches can go **cache-class subdirs only**
(see targets.md — profile/logins/bookmarks survive). Never sweep by size:
`com.apple.voicememos` (personal recordings), WhatsApp (message history), and
Dropbox (sync state) all look like fat app-data dirs and are all irreplaceable
or expensive. Downloads triage: group by extension first —

```bash
sudo sh -c 'find <dir> -type f -exec du -k {} +' | awk -F'\t' '{n=split($2,p,"."); ext=(n>1)?tolower(p[n]):"none"; s[ext]+=$1} END{for(e in s) printf "%9.2f GB  .%s\n", s[e]/1048576, e}' | sort -rn
```

— then delete only unambiguous installer classes (`.dmg`, `.pkg`) wholesale.
Media and `.zip` stay for the owner to review: one Takeout-style archive
mistaken for an installer costs real files.
