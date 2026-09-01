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
CORE_API_VERSION=1
MANIFEST_SCHEMA_VERSION=1
STATE_SCHEMA_VERSION=2
WORKBENCH_CORE_SEMVER=0.1.0
```

See `contracts/core-api.md` for what each integer gates.
`STATE_SCHEMA_VERSION` bumped `1` → `2` when `installers.list` (below) was
added — purely additive, so an existing `1` value on disk is migrated to
`2` in place by `wb install`/`wb apply` (`workbench_migrate_state_schema`),
never left stale.

## Module state root

```
${XDG_DATA_HOME:-~/.local/share}/workbench/modules/<name>/
├── sync.conf
├── snapshots/
│   └── <ref-slug>-<shortsha>/    immutable once written
├── current -> snapshots/<ref-slug>-<shortsha>
├── register.list
└── installers.list
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

### `register.list`

Rendered from the module's manifest `register.shell[]` entries, resolved
against that module's `current` snapshot, by the sync engine after every
successful fetch, by `wb add` on initial registration, and — unconditionally,
every run, regardless of whether anything changed — by `wb install`/`wb
apply` for every loadable module (`_wb_converge_module_registrations`,
`bin/wb`). This last one closed a confirmed regression (ARCHITECTURE.md §12
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
sync-enabled module whose manifest declares `register.shell[]`/
`register.installers[]` entries but whose `register.list` is missing or
empty.

### `installers.list`

The tool-updating framework's discovery artifact (ARCHITECTURE.md §12
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

## User-local overrides

```
${XDG_CONFIG_HOME:-~/.config}/workbench/local/
├── settings.sh          # reserved name — the direct successor to 90-local.sh
└── *.sh                 # any number of other user-authored files
${XDG_CONFIG_HOME:-~/.config}/workbench/user/*.sh
```

`workbench/local/` replaces the old single-file `90-local.sh`
(ARCHITECTURE.md §12 D22). `settings.sh` is the one reserved filename in
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

## What is deliberately NOT here

- No persistent, incrementally-`git pull`-updated working tree anywhere,
  for any module, under any `TRACK_MODE` — see `ARCHITECTURE.md` principle
  6 / D5. Every module directory's only `git`-shaped artifact, ever, is the
  ephemeral scratch clone `lib/distribution/fetch-git-snapshot.sh` deletes
  before the tree reaches `snapshots/`.
- No single flat `~/.config/shell/` (or equivalent) root — every module
  gets its own `snapshots/`/`current`, and the loader enumerates all of them
  (`ARCHITECTURE.md` §3).
