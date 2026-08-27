# Tracking & distribution contract

How `workbench-core` decides what commit of a module is deployed, and when.
See `ARCHITECTURE.md` §9 for the design rationale (D5-D8); this document is
the concrete, on-disk/behavioural contract.

## The four `TRACK_MODE` states

Persisted per module in `sync.conf` (`contracts/state-schema.md`):

| `TRACK_MODE` | Meaning | Re-checked every cycle? |
|---|---|---|
| `latest` (default) | Highest tag matching `vX.Y.Z` exactly | Yes |
| `branch:<name>` | A branch's current tip | Yes (this is the point) |
| `tag:<name>` | An exact tag, clean or pre-release | No — re-verified only, never re-resolved |
| `commit:<sha>` | An exact commit | No — re-verified only |

`tag:`/`commit:` pins are static until explicitly changed via
`wb track <name> --tag <t>` / `--commit <sha>`; each cycle re-confirms the
pin still exists upstream but never advances it on its own.

## Ref resolution (§9.1)

| Repo visibility | `TRACK_MODE` | Resolution | Fetch |
|---|---|---|---|
| Public | `latest` / `tag:` / `commit:` | GitHub API (unauthenticated) | GitHub codeload tarball — **no `git` anywhere** |
| Public | `branch:<name>` | `git ls-remote` | Shallow clone-and-discard (git as transport only) |
| Private | any | `git ls-remote` (via the deploy key, `lib/ssh/bootstrap.sh`) | Shallow clone-and-discard |

The public, non-branch path never invokes `git` — enforced by
`tests/check-distribution-no-git.sh`, which scrubs `git` from `PATH` and
confirms the fetch still succeeds. `branch:` tracking is git-based by
design (the one deliberate exception), for any repo, public or private —
mechanically identical to the private-repo path, just re-run every cycle.

A depth-1 `git fetch` **by branch or tag name** works uniformly; a depth-1
fetch **by raw commit sha** additionally requires the remote to have
`uploadpack.allowReachableSHA1InWant` enabled, which isn't guaranteed for an
arbitrary remote — `lib/distribution/fetch-git-snapshot.sh` tries the
shallow form first and falls back to a full fetch + checkout when it fails.

## Snapshots (§9.3)

```
${XDG_DATA_HOME}/workbench/modules/<name>/
├── sync.conf
├── snapshots/<ref-slug>-<shortsha>/     immutable once written
├── current -> snapshots/<ref-slug>-<shortsha>
└── register.list / deploy is read live from the manifest in `current`
```

`current` is flipped with `ln -sfn`/`ln -sfh` directly against the final
path — not a temp-symlink-then-`mv`, which would silently nest the new
snapshot inside the old one (`mv` treats an existing symlink-to-directory
destination as a directory to move *into*). There is never a window where
`current` resolves to a partially-written directory: the new snapshot is
always written out completely, under its own name, before the swap.

Retention defaults to the 3 most recent snapshots per module
(`WORKBENCH_SNAPSHOT_KEEP`); pruning never removes whatever `current`
currently points at, even if it would otherwise fall outside the window.

## Cadence (§9.4/D8)

One shared interval, **recomputed fresh on every check** — weekly
(604800s) by default, 300s (5 minutes) for as long as any registered
module (core included) is `branch:`-tracked, reverting the moment none are.

The OS-level scheduling primitive (systemd timer / launchd agent — see
`ansible/roles/module_sync/templates/{systemd,launchd}/`) is a **fixed**
5-minute poll that never itself changes: it invokes `wb sync run-if-due`
every 5 minutes unconditionally, and `lib/sync/engine.sh`'s
`workbench_sync_due()` decides in userspace whether this firing should
actually do anything, by comparing elapsed time since the last run against
the currently-applicable interval. This is deliberate: reconfiguring a
*running* systemd timer's own interval (or a loaded launchd agent's
`StartInterval`) requires reloading/restarting that unit, which is exactly
the "restart of the timer infrastructure" a tracking-mode change must never
require. Polling a fixed 5-minute floor and self-throttling in userspace
sidesteps that architecture question entirely, at the cost of one cheap
no-op invocation every 5 minutes even while the interval is nominally
weekly.

`wb update [<name>]` bypasses `workbench_sync_due()` entirely — always
runs immediately, regardless of cadence state.

## Persistence & `WORKBENCH_TRACK_<MODULE>` (§9.5/D7)

`sync.conf`'s `TRACK_MODE`/`TRACK_REF`/`RESOLVED_SHA` is the sole persistent
source of truth for both the sync engine and `wb status`. The manifest's
`branch:` field is a default only, consulted exactly once — the first time
a module is registered and no `sync.conf` yet exists for it.

The loader additionally exports a derived, **read-only**
`WORKBENCH_TRACK_<MODULE>` for every *registered* module (whether or not
its sync is currently enabled), formatted `<TRACK_MODE>:<TRACK_REF>` (e.g.
`branch:my-feature`) or bare `<TRACK_MODE>` when there's no ref yet
(`latest` with nothing resolved). `<MODULE>` is the registration name,
uppercased with `-` folded to `_` (via `tr`, not `${var^^}` — bash 3.2 has
no case-conversion parameter expansion).

## Loadable vs. registered vs. sync-enabled

Three related but distinct predicates (`lib/sync/state.sh`):

- **Registered** (`REGISTERED=true` in `sync.conf`, the default the moment
  `sync.conf` exists at all) — this module is part of the machine's
  configuration. `wb remove` sets this to `false` without deleting anything
  — idempotent, non-destructive deregistration.
- **Sync-enabled** (`SYNC_ENABLED=true`, independent of `TRACK_MODE`) —
  whether the timer/bulk `wb update` touches this module at all. Toggled by
  `wb sync enable|disable <name>`.
- **Loadable** = registered AND sync-enabled. This is the set
  `lib/loader.sh` actually sources `register.list` from into a new
  interactive shell. A module with sync paused is frozen at whatever it
  last deployed and is **not** re-sourced into new shells until re-enabled
  — a deliberate reading of ARCHITECTURE.md §3's "every registered,
  sync-enabled module," not an oversight: pausing a module's sync is a
  reasonable way to also pause a broken module's shell functions without
  fully deregistering it. `WORKBENCH_TRACK_<MODULE>` is exported for every
  *registered* module regardless of this, so `wb status`/scripts can always
  see what a paused module was last tracking.

## Resilience guarantees (§9.6, unchanged from `external-sync.sh`)

- One module's failure (bad URL, network error, failed fetch) is logged and
  never aborts any other module's sync — `workbench_sync_run_one()` isolates
  each module's cycle.
- A `post_deploy` hook's failure is recorded but never fails that module's
  sync, let alone any other's.
- `wb status` (and anything reading `sync.conf`/`register.list` directly)
  performs no fetch and takes no lock — read-only, local plumbing only.

## Developer workflow & disk duplication (§9.6)

A developer's own working clone of a module — wherever they manage it,
`git push`ed normally — is entirely outside anything `workbench` tracks.
Pointing that module's tracking at that same branch (`wb dev`/
`wb track --branch`) produces a **separate**, independently-fetched
snapshot under `snapshots/`, fetched fresh every cycle the same way any
`branch:`-tracked content is. This means a developer actively working on a
module has two copies of the same files on disk at once: their own editing
clone, and workbench's fetched snapshot. This is expected, low-impact
(small text files, not large binaries), and not a bug or drift — see
`docs/module-authoring.md`'s note on this.
