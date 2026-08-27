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
STATE_SCHEMA_VERSION=1
WORKBENCH_CORE_SEMVER=0.1.0
```

See `contracts/core-api.md` for what each integer gates.

## Module state root

```
${XDG_DATA_HOME:-~/.local/share}/workbench/modules/<name>/
├── sync.conf
├── snapshots/
│   └── <ref-slug>-<shortsha>/    immutable once written
├── current -> snapshots/<ref-slug>-<shortsha>
└── register.list
```

`<name>` = the module's registration name (its catalog/`wb add` name).
Core occupies `<name> = core` — no special-cased shape (principle 4).
`<ref-slug>` is the tracked ref (tag name, `branch:<name>`, or the literal
ref value) run through `_wb_slugify` (lowercased, anything outside
`[a-z0-9._-]` collapsed to `-`) so a branch name containing `/` is still a
valid single path component.

### `sync.conf`

Plain `KEY=VALUE`, one assignment per line, read via `source` in a subshell
(`workbench_module_conf_get`) or rewritten one key at a time
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

Rendered (by the sync engine after every successful fetch, and by `wb add`
on initial registration) from the module's manifest `register.shell[]`
entries, resolved against that module's `current` snapshot:

```
<absolute-path-into-current>|<tier>
```

One line per registered shell file. `<tier>` is one of
`env`/`core`/`tools`/`platform`/`distro`/`lazy` — see
`contracts/core-api.md`'s loader-tier section for sourcing order and the
platform/distro filename-selector convention.

## User-local overrides

```
${XDG_CONFIG_HOME:-~/.config}/workbench/local/90-local.sh
${XDG_CONFIG_HOME:-~/.config}/workbench/user/*.sh
```

The first is sourced twice by the loader (first so its flags gate later
tiers, again at the end so it wins over anything a tier also touched) — the
namespace-moved equivalent of `dotfiles`' `~/.config/dotfiles/local/90-local.sh`.
The second is `WORKBENCH_USER_EXT_DIR`, sourced last of all content tiers,
same shadowing/syntax-smoke-test semantics as the donor codebase's
`DOTFILES_USER_EXT_DIR`.

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
