# On-disk state schema

`STATE_SCHEMA_VERSION` in `~/.config/workbench/core/version` covers
everything in this document. Bump it (and add a migration in `wb apply`)
whenever this shape changes incompatibly.

## Version file

```
~/.config/workbench/core/version
```

Plain `KEY=VALUE`, readable via `grep`/`cut` alone — no core library needs
to be loadable to check it:

```
CORE_API_VERSION=1.4
STATE_SCHEMA_VERSION=2
WORKBENCH_CORE_SEMVER=0.1.0
```

See `contracts/core-api.md` for what each value gates (`CORE_API_VERSION`
is `X.Y`, not a bare integer — see docs/decisions-log.md D29).
`STATE_SCHEMA_VERSION` bumped `1` → `2` when `installers.list` (below) was
added — purely additive, so an existing `1` value on disk is migrated to
`2` in place by `wb install`/`wb apply` (`_workbench_migrate_state_schema`),
never left stale. `CORE_API_VERSION` is unconditionally resynced to the
running release's value on every `wb install`/`wb apply`
(`_workbench_sync_version_facts`) rather than migrated — see
`contracts/core-api.md`'s Versioning section (docs/decisions-log.md D36). A
fourth field, `MANIFEST_SCHEMA_VERSION`, previously lived here but has
been retired as dead (docs/decisions-log.md D37) — `wb apply` strips it from
any existing host's file.

## Module state root

```
${XDG_DATA_HOME:-~/.local/share}/workbench/modules/<name>/
├── sync.conf
├── snapshots/
│   └── <ref-slug>-<shortsha>/    immutable once written
├── current -> snapshots/<ref-slug>-<shortsha>
├── register.list
├── installers.list
├── getters.list       register.getters[] function|label (D89)
├── files.list         engine-owned ledger (D81)
├── files.policy       host-owned per-file policy (D81)
├── files.forms        linked entries the user chose to have managed as copies (D81)
├── files.displaced    user files moved aside by 'wb files use' (D81)
├── files.pending      targets waiting on a decision (D81; absent when none)
└── sums/<snapshot>    checksums recorded when each snapshot was fetched (D81)
```

`<name>` = the module's registration name (its catalog/`wb add` name).
Core occupies `<name> = core` — no special-cased shape (principle 4).
`<ref-slug>` is the tracked ref (tag name, `branch:<name>`, or the literal
ref value) run through `_wb_slugify` (lowercased, anything outside
`[a-z0-9._-]` collapsed to `-`) so a branch name containing `/` is still a
valid single path component.

### `sync.conf`

Plain `KEY=VALUE`, one assignment per line, read as inert data via
`grep`/`cut` — deliberately **not** `source`d, since this file lives on
disk and is machine-writable; sourcing it would execute anything placed
there rather than just reading key/value pairs (`workbench_module_conf_get`,
`lib/sync/state.sh`) — or rewritten one key at a time
(`workbench_module_conf_set`) without disturbing other keys:

| Key | Meaning | Default if absent |
|---|---|---|
| `REPO_URL` | The module's git/GitHub remote URL | — (required for sync) |
| `PRIVATE` | `true`/`false` — routes resolution+fetch (tracking-spec.md) | `false` |
| `TRACK_MODE` | `latest` \| `branch:<name>` \| `tag:<name>` \| `commit:<sha>` | `latest` |
| `TRACK_REF` | The concrete ref last resolved (tag name, branch name, or sha) | — |
| `RESOLVED_SHA` | The commit sha currently deployed | — |
| `REGISTERED` | `true`/`false` — `wb remove` sets `false`, never deletes | `true` once the file exists |
| `SYNC_ENABLED` | `true`/`false` — independent of `TRACK_MODE` (§9.7) | `true` |
| `ALLOW_HOOKS` | `true`/`false` — per-machine hook gate, mirrors the manifest's hook declaration | `false` |
| `HOOKS_APPROVED_SHA` | Commit whose `post_deploy` hook the user last approved (docs/decisions-log.md D76) | — |
| `HOOKS_PENDING` | `true`/`false` — a hook was deferred by an unattended sync and is owed a run on the next interactive one | `false` |
| `PENDING_SHA` | A newly-resolved `latest` release currently held in cooldown, not yet adopted (docs/decisions-log.md D77) | — |
| `PENDING_SINCE` | Unix epoch seconds this host first saw `PENDING_SHA` — measured against `RELEASE_COOLDOWN_DAYS` | — |

### `scheduler.conf`

```
${XDG_CONFIG_HOME:-${HOME}/.config}/workbench/core/scheduler.conf
```

Plain `KEY=VALUE`, read the same way as `sync.conf` (never `source`d).

| Key | Meaning | Default if absent |
|---|---|---|
| `RELEASE_COOLDOWN_DAYS` | Days a new `latest` release must be continuously resolved before an unattended (`scheduled`) sync adopts it; `0` disables (docs/decisions-log.md D77) | `3` |

### `adoption.log`

```
${XDG_DATA_HOME:-${HOME}/.local/share}/workbench/adoption.log
```

Append-only, tab-separated, one line per event, never rotated (≈120
bytes/line): `<utc-iso8601>\t<event>\t<module>\t<old_sha>\t<new_sha>\t<ref>\t<reason>`.
`<event>` is one of `adopt`, `cooldown-start`, `hook-run`, `hook-failed`,
`hook-deferred`. Written by `_wb_adoption_log_event`
(`lib/sync/engine.sh`) — a local record of what this host adopted and ran,
and when, for incident response (docs/decisions-log.md D77).

### `register.list`

Rendered from the module's manifest `register.shell[]` entries, resolved
against that module's `current` snapshot, by the sync engine after every
successful fetch, by `wb add` on initial registration, and — unconditionally,
every run, regardless of whether anything changed — by `wb install`/`wb
apply` for every loadable module (`_wb_converge_module_registrations`,
`bin/wb`). This last one closed a confirmed regression (docs/decisions-log.md
D21): a `bootstrap.sh`-driven install left it entirely unrendered, since
neither `_wb_bootstrap_core_module`'s early-return path nor anything else in
`wb install`/`wb apply`/`wb update` called this unconditionally before —
only a genuine upstream commit change ever did.

```
<absolute-path-into-current>|<tier>
```

One line per registered shell file. `<tier>` is one of
`env`/`core`/`tools`/`platform`/`distro`/`lazy` — see
`contracts/core-api.md`'s loader-tier section for sourcing order and the
platform/distro filename-selector convention.

`wb status` flags loudly (a warning, not silence) any registered,
sync-enabled module whose manifest declares `register.shell[]` entries but
whose `register.list` is missing or empty (docs/decisions-log.md D71: this
check is against `register.shell[]` alone — an installers-only module
correctly has an empty `register.list`, since its content never renders
there).

### `installers.list`

The tool-updating framework's discovery artifact (docs/decisions-log.md
D23) — rendered at exactly the same points `register.list` is, from the
module's manifest `register.installers[].src` entries: each declared file
is introspected as plain text (`_extract_function_names`,
`lib/core/functions.sh` — never sourced at render time) for
`install-<name>`-shaped function definitions.

```
<absolute-path-into-current>|<function-name>|<friendly-name>
```

One line per discovered `install-*` function. `<friendly-name>` is
`<function-name>` with the `install-` prefix stripped. `wb tools`
aggregates this file across every loadable module — see
`docs/module-authoring.md` for the naming convention and the collision
rule (first-by-module-name-order wins, warned once) when two modules
declare the same friendly name.

`wb status` flags loudly (a warning, not silence) any registered,
sync-enabled module whose manifest declares `register.installers[]`
entries but whose `installers.list` is missing or empty — checked
independently of the `register.list` check above (docs/decisions-log.md
D71).

### `getters.list`

Rendered at exactly the points `register.list` and `installers.list` are,
from the module's manifest `register.getters[]` entries
(docs/decisions-log.md D89):

```
<function-name>|<label>
```

The loader defines each `<function-name>` the module didn't define itself
as a call to `_wb_module_getter`, which reads `<label>` back from here.
Entries whose function is empty, starts with `_`, or contains anything
outside `[A-Za-z0-9_-]` are never written; `|`, tabs and newlines are
stripped from the label. Additive: like the D81 `files.*` files it needs
no `STATE_SCHEMA_VERSION` bump — a host without it simply has no generated
getters until the next sync or `wb apply` renders it.

### `files.list`

Engine-owned ledger (docs/decisions-log.md D81). Pipe-delimited, one row per target, read as data with `awk` — never sourced. The `#` header line is ignored.

```
# dest|kind|state|sha|original|ack|pin
~/.config/tmux/tmux.conf|deploy|active|<sha256>|-|-|-
~/.vimrc|deploy|user|-|-|-|-
~/.config/nvim|deploy|held|link:.|-|-|v1.0.0-c2f7760
~/.gitconfig#under|layer|active|<sha256>|-|-|-
```

| Field | Values |
|---|---|
| `dest` | `~/`-form dest from the manifest (directory children as `<dest>/<path>`), or the absolute engine-computed path for `overrides_src`, or — for a layer — `<target>#<position>` (`~/.gitconfig#under`). The key. |
| `kind` | `deploy` \| `overrides` \| `layer` (docs/decisions-log.md D82) |
| `state` | `active` — core wrote or linked it. `user` — the user chose to own it (`wb files resolve … keep`, or `skip` on a linked entry); never written again. `removed` — core wrote it, the user deleted it; never recreated. `restored` — `wb files restore` ran. `held` — linked, with changes made through the link; pinned until resolved. `converted` — a linked directory now delivered as managed copies (its children have their own rows). |
| `sha` | Copy: sha256 of what core last wrote. Linked: `link:<src>`. |
| `original` | Backup of the pre-workbench content core displaced at `dest`, or `-`. Under the backup root. Layers: `-` (the target existed), `+created` (core created it), or a backup path (after `wb files use` displaced the user's content). |
| `ack` | Copy: the upstream sha256 the user chose to keep their edit over (`wb files resolve … manage`); no notice until the default moves again. Otherwise `-`. |
| `pin` | `held`: the snapshot basename the entry is pinned to. Otherwise `-`. |

Content core found at a dest that isn't its own has no row — it's re-evaluated on every deploy, so a later `follow` applies to it. Rewritten atomically (temp file + rename) one row at a time. Safe to delete: the next deploy re-derives each row, treating a byte-identical copy of a retained default (or a link into the module's own state) as core's and anything else as the user's. What's lost is `original`, `ack` and `pin` — the backups themselves stay, and a held entry's snapshot becomes prunable, so don't delete it while anything is held.

**Layer rows** (`kind: layer`, docs/decisions-log.md D82). `state`: `active` — core's block is in the target as core wrote it (lines found inside it that core didn't write are moved out, just below it). `user` — the user edited the block (an expected line is gone), or the layer's policy is `skip`; never written. `removed` — the user deleted the block's markers; never re-added. `restored` — `wb files restore` removed the block. `sha` is the sha256 of the exact block text written, markers included. Once a row exists, its target is the layer's target from then on, even if another candidate file appears later.

### `files.policy`

Host-owned. One `<dest>|<policy>` row per target the user has overridden with `wb files policy`; `<policy>` is `skip`, `seed`, `managed` or `follow` (`seed` is copy-only). No row: the entry's lifecycle and the host default decide. Never written by sync.

A layer's row is keyed by its layer id instead of a path — `<tool>` for an `under` layer, `<tool>:over` for an `over` one (`gitconfig|skip`) — and takes only `skip` or `managed`. That lets `wb add --skip-layer` write it before the module's first deploy, when the target isn't known yet. `managed` on a layer is the explicit consent to write through a symlinked target.

### `files.forms`

`<dest>|copy` for each linked entry the user chose to have managed as copies (`wb files resolve … manage`). `workbench_files_targets` then lists that entry's files as copy-mode targets. Removed by `wb files use` and `wb files restore`.

### `files.displaced`

`<owner-dest>|<path>|<backup>` for each user file `wb files use` moved aside on behalf of `<owner-dest>` (a `yield_to` competitor). `wb files restore` of the owner copies each back and drops its row.

### `files.pending`

`<dest>|held` or `<dest>|moved` (an edited copy whose default has changed since), or `<target>#<position>|linked` (a layer whose target is a symlink the user manages, waiting on `wb files resolve <module> <layer-id> use|keep` — D82). Rewritten after every deploy and every `wb files` change; deleted when empty. Read by the loader's shell-start notice and `wb status`, by existence and line count only.

### `sums/<snapshot>`

`<sha256>  <path>` for every regular file in the snapshot, written once, when the snapshot is fetched (or, for a host upgrading to D81, the first time an update finds none). Removed when the snapshot is pruned.

### Effective policy

`workbench_files_effective_policy`: a `files.policy` row wins; else `lifecycle: seed` → `seed`, `generated` → `follow`, `managed` and linked entries → the host default.

### Copy-mode decision matrix

"follow (file)" means a `files.policy` row or `lifecycle: generated`; "follow (host)" means the host default.

| condition | skip | seed | managed | follow (host) | follow (file) |
|---|---|---|---|---|---|
| `new` — nothing there, no record | – | create | create | create | create |
| `yielded` — a `yield_to` path exists | – | leave (yours) | leave (yours) | leave (yours) | create, warn |
| `adoptable` — byte-identical to a retained default, or core's link | – | adopt as-is | refresh | refresh | refresh |
| `foreign` — exists, not ours | – | leave (yours) | leave (yours) | replace, keep original | replace, keep original |
| `clean` — what core wrote | – | – | refresh if default moved | refresh if default moved | refresh if default moved |
| `edited` — changed since core wrote it | – | – | leave; pending if default moved | back up, replace | back up, replace |
| `gone` — deleted since core wrote it | – | leave (removed) | leave (removed) | leave (removed) | leave (removed) |

`held`, `user`, `removed` and `restored` rows are never written by sync. "Replace" moves a user's symlink aside as a symlink; a directory is never written into. The host default never creates a second config beside one at a `yield_to` path, because tmux would load both. Implemented once, purely, as `_wb_files_decide` (`lib/files/lifecycle.sh`).

### Linked decision matrix

| at `dest` | skip | managed | follow (per entry) | follow (host default) |
|---|---|---|---|---|
| nothing, no record | – | link | link | link |
| nothing, a `yield_to` path exists | – | leave (yours) | link, warn | leave (yours) |
| core's link | becomes your own copy | relink | relink | relink |
| core's unedited copy (entry was copy mode) | – | link | link | link |
| a file, or a symlink elsewhere | – | leave (yours) | move aside, link | move aside, link |
| a real directory | – | leave (yours)* | move aside, link | leave (yours)* |
| recorded, now gone | – | leave (removed) | leave (removed) | leave (removed) |

\* `link_tree` only: a directory with no record where at least half the module's files are present and byte-identical to a retained default is an earlier copy of this module (the pre-D81 engine copied `link_tree` entries). It's adopted as managed copies instead: matching files are refreshed and tracked, differing files stay yours.

At update time (`workbench_files_before_swap`, before every snapshot swap): an `active` link whose snapshot has changed since it was fetched is **held** — repointed at that exact snapshot, which pruning then keeps. With a per-entry `follow`, the changes are backed up and the update proceeds; if the backup fails, it's held instead. If any entry can't be secured, the engine doesn't swap at all. A snapshot that is pinned, or has changed since it was fetched, is never swapped back in.

## Host file policy

```
${XDG_DATA_HOME:-~/.local/share}/workbench/files.conf
```

`DEFAULT_POLICY=managed|follow` (absent: `managed`). Applies to `lifecycle: managed` copy entries and linked entries only, and never moves a real directory. Set with `wb files policy --default`.

`INSTALL_DEFAULT=keep|use` (absent: `keep`): the last whole-host answer to the install question (docs/decisions-log.md D84). It only chooses what Enter picks at the next question; it never answers for the user, and an install with no terminal always keeps.

A module whose `sync.conf` has no `RESOLVED_SHA` but has a `current` snapshot was fetched and never deployed — the user quit at the install question. The next interactive `wb update` asks again; the next unattended sync deploys it with the default answer, keep.

## User-local overrides

```
${XDG_CONFIG_HOME:-~/.config}/workbench/local/
├── settings.sh          # reserved name — the direct successor to 90-local.sh
└── *.sh                 # any number of other user-authored files
${XDG_CONFIG_HOME:-~/.config}/workbench/user/*.sh
```

`workbench/local/` replaces the old single-file `90-local.sh`
(docs/decisions-log.md D22). `settings.sh` is the one reserved filename in
that directory, keeping exactly `90-local.sh`'s old two-pass semantics:
sourced first (so flags it sets gate later tiers) and again at the very end
(so it wins over anything a tier also touched) — this is where the
documented switches (`WORKBENCH_PLAIN_SHELL`, `WORKBENCH_SHOW_FUNCTIONS`,
etc.) live. `wb install`/`wb apply` create the directory and write a
default, commented `settings.sh` if one doesn't already exist — never
overwriting one that does.

Every *other* `*.sh` file in the same directory — genuinely open,
user-owned content (functions, aliases, whatever) — is sourced once,
together, filename-sorted, immediately after `settings.sh`'s final pass.
This deliberately does **not** reproduce the six loader tiers
(`env`/`core`/`tools`/`platform`/`distro`/`lazy`) for local content — flat
and always-last is the right level of complexity for something the loader
can't validate the shape of the way it can a module's manifest.

Resulting tail-end order in `lib/loader.sh`: `settings.sh` (early) → six
tiers → prompt fallback → `settings.sh` (final) → other `local/*.sh` files
→ `WORKBENCH_USER_EXT_DIR/*.sh` → `dedupe-path`.

`WORKBENCH_USER_EXT_DIR` (the second path above) is unchanged and
conceptually distinct from the local-overrides directory — hand-authored
"pseudo-module" extensions vs. personal overrides — and stays the true
last-of-everything, sourced after `workbench/local/`'s other files. Same
shadowing/syntax-smoke-test semantics as the donor codebase's
`DOTFILES_USER_EXT_DIR`, shared via `lib/loader.sh`'s
`_wb_loader_source_sh_files_once` helper with the local-overrides "other
files" pass above.

## Cadence state

```
${XDG_DATA_HOME:-~/.local/share}/workbench/last-cadence-run
```

A single unix timestamp, rewritten by `workbench_cadence_mark_ran()` after
every `wb sync run-if-due`/`workbench_sync_all` invocation — see
`contracts/tracking-spec.md` §Cadence.

## Backup root

```
${XDG_DATA_HOME:-~/.local/share}/workbench/backups/
└── <YYYY-MM-DD>/
    └── <HH00>/
        └── <module>-<basename>.<HHMMSS>[.<n>]
```

Written by `workbench_backup_existing_file` (`lib/sync/engine.sh`)
immediately before core replaces or removes a real (non-symlink)
pre-existing file or directory (see `docs/decisions-log.md` D53) —
`wb files use`/`wb module reset`, a `follow` policy, and any
`lifecycle: generated` (`force: true`) entry. Every backup path, copied
or moved, comes from the one naming helper, `_wb_backup_path_new`.

Also written by `lib/files/lifecycle.sh` (D81): copies before it replaces content, and moves when it puts the user's own config aside (`wb files use`, `follow`). A moved symlink is kept as a symlink. Changes backed up from a held or followed link are one directory per entry (`<module>-<name>.<HHMMSS>/`), with their relative paths kept. The first backup of content core didn't write is recorded as that entry's `original` in `files.list`, and moved-aside competitors in `files.displaced` — don't delete those if you might want `wb files restore`.

`<HH00>` is the hour, zero-padded to two digits, with a literal `00`
appended (`09:14` → `0900`), not the minute — kept coarse deliberately,
since this directory is for a human to browse, not to correlate to the
second. `<HHMMSS>` on the filename itself disambiguates multiple backups
of the same file inside one hour bucket; a numeric `.<n>` suffix is added
only in the (expected to be vanishingly rare) case two backups of the
same file land in the same second.

Copy-mode backup is skipped when the incoming content is byte-identical
to what's already at `dest` — an unchanged `force: true` re-deploy
produces nothing here. Anything replaced by a link is moved here whole,
unconditionally — a type change is worth preserving even when the
content matched.

No retention policy and no scheduled cleanup — deliberate, not deferred;
revisit only if volume ever actually becomes a problem.

## What is deliberately NOT here

- No persistent, incrementally-`git pull`-updated working tree anywhere,
  for any module, under any `TRACK_MODE` — see `docs/architecture.md` principle
  6 / D5. Every module directory's only `git`-shaped artifact, ever, is the
  ephemeral scratch clone `lib/distribution/fetch-git-snapshot.sh` deletes
  before the tree reaches `snapshots/`.
- No single flat `~/.config/shell/` (or equivalent) root — every module
  gets its own `snapshots/`/`current`, and the loader enumerates all of them
  (`docs/architecture.md` §3).
