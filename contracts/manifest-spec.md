# The workbench-core manifest spec

This is the authoritative contract for a workbench-core manifest. If you are
authoring a module or an independent tracked tool, everything you need is in
this file.

`.dotfiles-sync.yml`'s filename and `version: 1` semantics are permanent —
this keeps existing `dotfiles`-era manifests working unmodified. It is no
longer the *only* permanent name, though: `workbench.yml` / `workbench.yaml`
/ `wb.yml` / `wb.yaml`, `version: 2`, is a parallel, equally-supported
spelling with the identical field set — see
[Manifest filenames & discovery](#manifest-filenames--discovery) below and
ARCHITECTURE.md §12 D46. All of `core_api`/`sync`/`register` below are new,
optional, namespaced keys that only `workbench-core` looks for; a manifest
with none of them behaves exactly as it always has.

If this file and `lib/manifest/validate.sh` (the developer-time validator)
or `lib/manifest/parse.sh` (the hot-path reader) ever disagree, **this file
wins** — both cite the relevant section here in their own error output.

## Table of contents

- [Manifest filenames & discovery](#manifest-filenames--discovery)
- [Quick start](#quick-start)
- [Schema version 1 — unchanged fields](#schema-version-1--unchanged-fields)
- [`core_api`](#core_api)
- [`sync.enabled`](#syncenabled)
- [`info`](#info)
- [`overrides_src`](#overrides_src)
- [`register:`](#register)
  - [`register.shell[]`](#registershell)
  - [`register.installers[]`](#registerinstallers)
  - [`register.getters[]`](#registergetters)
- [Field reference](#field-reference)
- [`dest` validation](#dest-validation)
- [Hook contract](#hook-contract)
- [The compatibility boundary — what would actually be breaking](#the-compatibility-boundary)
- [Validating your manifest](#validating-your-manifest)

## Manifest filenames & discovery

`workbench-core` discovers a module's manifest by checking, in this order,
in the module's repo root:

1. `workbench.yml`
2. `workbench.yaml`
3. `wb.yml`
4. `wb.yaml`
5. `.dotfiles-sync.yml`

Only the first match found is read — manifests are never merged across
filenames. Filename and `version:` are a bound pair: any of the first four
names **must** declare `version: 2`; `.dotfiles-sync.yml` **must** declare
`version: 1`. Either mismatch is a loud validation/sync-refusal error, not a
silent correction.

Because `wb.yml`/`wb.yaml` are generic enough to plausibly be some other
tool's own config file, a candidate with any of the first four names must
contain a top-level `version:` key to be accepted as a workbench manifest at
all — one with no `version:` key is silently treated as not ours, and
discovery moves on to the next candidate rather than erroring on a
stranger's file. `.dotfiles-sync.yml` is exempt from this sniff-check and is
always trusted unconditionally, as it always has been.

There is no deprecation timeline for `.dotfiles-sync.yml` — it may remain a
fully supported name indefinitely. `workbench.yml`/`version: 2` is simply
the name this spec's own examples lead with for new or migrating repos. See
ARCHITECTURE.md §12 D46 for the full decision.

## Quick start

A minimal module manifest — deploy only, no shell registration. This is the
form new and migrating repos should lead with:

```yaml
# workbench.yml — schema version 2
version: 2
branch: main

deploy:
  - src: claude/
    dest: ~/.claude/
    mode: copy
```

A module that also registers shell functions and a getter:

```yaml
# workbench.yml — schema version 2
version: 2
branch: main

deploy:
  - src: shell/
    dest: ~/.local/share/workbench/modules/awsconfd/src/
    mode: copy

core_api: ">=1.0 <2.0"
sync:
  enabled: true

info:
  description: "AWS config helpers and credential rotation"

register:
  shell:
    - src: shell/aws.sh
      tier: tools
  installers:
    - src: shell/installers.sh
  getters:
    - name: aws
      function: get-aws-functions
      label: "AWS config helpers"
```

The legacy/reference form — identical fields, `.dotfiles-sync.yml`,
`version: 1` — still works exactly as it always has:

```yaml
# .dotfiles-sync.yml — schema version 1
version: 1
branch: main

deploy:
  - src: shell/
    dest: ~/.local/share/workbench/modules/awsconfd/src/
    mode: copy

core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/aws.sh
      tier: tools
```

No manifest at all is also valid — a clone-only mirror that deploys
nothing.

## Schema version 1 — unchanged fields

`version`, `branch`, `deploy[]`, and `hooks.post_deploy` behave exactly as
they did for `dotfiles`' `external-sync` engine. `branch:` is now explicitly
a **default only** (see [tracking-spec.md](tracking-spec.md)) — once a
machine has its own persisted `TRACK_MODE`/`TRACK_REF` for this module,
that machine-side state is authoritative and `branch:` is never consulted
again for that module on that machine.

## `core_api`

```yaml
core_api: ">=1.0 <2.0"
```

A semver-range string against `CORE_API_VERSION` (see
[core-api.md](core-api.md)). **Required for `register:` to be honoured** —
absent, the manifest is treated as deploy/sync-only (legacy behaviour) and
any `register:` block is ignored. Core checks this range **before** sourcing
any of the module's `register.shell[]` files, and refuses loudly (not a
silent skip) if it isn't satisfied by the running Core API version.

## `sync.enabled`

```yaml
sync:
  enabled: true   # default
```

The manifest-declared default for whether this module auto-syncs on the
timer. Machine-side state (`sync.conf`) can independently override this per
machine — see [tracking-spec.md](tracking-spec.md) §Toggles.

## `info`

```yaml
info:
  description: "One-line summary of what this module does"
```

Free-text, author-supplied metadata surfaced by `wb module info <name>`
(see `docs/module-authoring.md`). Unlike `register:`, `info:` has no
functional effect on sync, deploy, or the loader — it's display-only, so
it's read regardless of whether `core_api` is declared. `description` is
optional; a module that omits it still gets a full `wb module info`
output built entirely from what core already tracks (repository,
tracking state, registration) — omitting it just means that one line
reads as not yet published, not as an error.

Keep `description` to one line — anything longer belongs in a `HELP.md`
or `README.md` at the repo root, shown in full by `wb module docs
<name>`. That lookup is convention-only, not a manifest field: `HELP.md`
is tried first, falling back to `README.md`; neither present is reported
as "not published," not an error.

## `overrides_src`

```yaml
overrides_src: shell/overrides.sh
```

A module's answer to "I ship an opinionated default, but you should be
able to change it without editing a file that lives inside my immutable,
per-sync snapshot." `src` is validated exactly like `deploy[].src` (safe
relative path, no leading `/`, no `..` segment) — there is deliberately no
`dest` field, for the same reason `register.shell[]` has none (see
above): the destination is always engine-computed, never
author-specified, because this file lands inside
`~/.config/workbench/local/` — the one directory a user's own shell
trusts enough to source unconditionally on every start, and the one
place this project's non-negotiables specifically forbid a module from
choosing its own path into.

The engine deploys it once, to
`${XDG_CONFIG_HOME:-~/.config}/workbench/local/overrides/<module-name>.sh`
(`<module-name>` is the module's registration name — the same name `wb
add <name>` uses), with the same `copy`/`force: false` semantics
`deploy[]` already has — create once, never touched again by the engine.
There is no `force: true` escape hatch for this field: once deployed,
the file is the user's, permanently, by design. A module bumping
`overrides_src`'s content in a later release does **not** update anyone
who already has the file — same one-way-publish model `deploy[]`'s own
`copy` mode already documents above. If a module doesn't yet have an
opinion worth exposing, it simply omits this field — there is no blank
placeholder, and none is ever created on a module's behalf.

Loaded early — before every module's own tier content, and before
`~/.config/workbench/local/settings.sh`'s own early pass — so a value it
sets is visible to a module's own `${VAR:-default}`-style tier code, and
a user's own `settings.sh` always wins if both set the same variable. See
`lib/loader.sh`'s "Module-shipped overrides" section and
`docs/module-authoring.md`'s "Shipping overridable defaults" section for
the full load-order picture and the `WORKBENCH_OVERRIDE_<SCOPE>` naming
convention this field exists to support.

## `register:`

The fix for a structural gap in the pre-`workbench` design: a manifest-
driven module's `deploy[]` entries can never land in `~/.config/shell/`
(that destination is on the `dest` denylist, for good reason — see below),
which means a manifest-driven module could never get its shell functions
somewhere the loader would actually find them. `register:` closes this gap
by having the *engine* compute the destination, never the author.

### `register.shell[]`

```yaml
register:
  shell:
    - src: shell/aws.sh    # required, path relative to repo root
      tier: tools          # optional, default "tools"
```

- `src` — validated exactly like `deploy[].src` (safe relative path, no
  leading `/`, no `..` segment).
- `tier` — one of `env` / `core` / `tools` / `platform` / `distro` / `lazy`,
  matching the loader's tier order (see the Core API loader docs). Governs
  load order and eagerness the same way it does for core's own files.
- `dest` — **not a field.** The engine computes it: each `register.list`
  entry the sync engine writes points at `<module>/current/<src>` — i.e.
  your file, exactly where it already lives inside your own module's
  fetched snapshot (`${XDG_DATA_HOME}/workbench/modules/<name>/current/`),
  never copied or symlinked anywhere else (see
  `contracts/state-schema.md`'s `register.list` section and
  `workbench_render_register_list()` in `lib/sync/engine.sh`). A manifest
  that supplies `dest` here fails validation loudly — this is deliberate: a
  `register:` entry structurally cannot target anything outside its own
  module namespace, so there is no denylist to defend, and none is needed.
  (An earlier design draft described a separate
  `${WORKBENCH_HOME}/modules.d/<module-name>/<basename>` symlink tree for
  this — the sync engine reading `register.list` straight out of each
  module's own `current` snapshot makes that indirection unnecessary; see
  `ARCHITECTURE.md` §12 D16.)

### `register.installers[]`

```yaml
register:
  installers:
    - src: shell/installers.sh
```

Files scanned for `install-<name>`-shaped functions, folded into the
generalised tool-updating registry `wb tools` walks (ARCHITECTURE.md §12
D23). Same `src` validation as `register.shell[]`. See
`docs/module-authoring.md#declaring-installers-wb-tools` for the naming
convention (a hard requirement, not a suggestion) and the collision rule
when two modules declare the same friendly name.

### `register.getters[]`

```yaml
register:
  getters:
    - name: aws                      # required
      function: get-aws-functions    # required
      label: "AWS config helpers"    # optional
```

Declares a domain getter so `wb functions` can enumerate it without a
hardcoded registry entry in core. `name` and `function` are required and
must be non-empty; `label` is free text shown in `wb functions`' output.

Unknown keys anywhere under `register:` (including unrecognised sub-blocks
alongside `shell`/`installers`/`getters`) are ignored, not fatal — same
forward-compatibility posture as the rest of this spec.

## Field reference

| Field | Required | Default | Meaning |
|---|---|---|---|
| `version` | yes | — | Must be `1`. |
| `branch` | no | `main` | Default `TRACK_REF` only — see tracking-spec.md. |
| `deploy[].src` | yes, per entry | — | Path within repo, relative, no `..`. |
| `deploy[].dest` | yes, per entry | — | Must start with `~/`, no `..`, not on the dest denylist. |
| `deploy[].dest_macos` | no | — | Overrides `dest` on macOS only. Same validation as `dest`. |
| `deploy[].mode` | no | `copy` | `copy` \| `link` \| `link_tree`. |
| `deploy[].force` | no | `false` | Overwrite a non-symlink/non-matching existing dest. |
| `deploy[].platforms` | no | (all) | List containing only `linux`/`macos`. |
| `core_api` | no | — | Semver range this module targets. Absent = `register:` ignored. |
| `sync.enabled` | no | `true` | Module-level default; machine state can override. |
| `info.description` | no | — | Free text, shown by `wb module info`. No functional effect — read regardless of whether `core_api` is declared. |
| `overrides_src` | no | — | Path to a file deployed once (never overwritten) to `~/.config/workbench/local/overrides/<module-name>.sh`. No `dest` — always engine-computed. |
| `register.shell[].src` | yes, per entry | — | Validated like `deploy[].src`. |
| `register.shell[].tier` | no | `tools` | Loader tier. |
| `register.shell[].dest` | — | — | **Not permitted.** Engine-computed only. |
| `register.installers[].src` | yes, per entry | — | Validated like `deploy[].src`. |
| `register.getters[].name` | yes, per entry | — | Non-empty string. |
| `register.getters[].function` | yes, per entry | — | Non-empty string. |
| `register.getters[].label` | no | — | Free text. |
| `hooks.post_deploy.command` | yes, if `hooks.post_deploy` given | — | Non-empty list (argv form). `[0]` must exist in the repo. |
| `hooks.post_deploy.run_on` | no | `changed` | `changed` \| `always` \| `initial`. |
| `hooks.post_deploy.timeout` | no | `300` | Positive integer, seconds. |

## `dest` validation

Every `deploy[].dest`/`dest_macos` must:

- Start with `~/` (anchored at the user's home directory — no absolute
  paths outside it).
- Contain no `..` path segment.
- Not fall under the dest denylist: `~/.ssh/`, `~/.gnupg/`,
  `~/.config/shell/`, `~/.config/git/`, `~/.config/dotfiles/`,
  `~/.config/workbench/`, `~/.config/external-sync/`,
  `~/.config/systemd/user/`, `~/Library/LaunchAgents/`, `~/.bashrc`,
  `~/.zshrc`, `~/.profile`, `~/.gitconfig`.

This denylist is exactly why `register:` had to exist as a separate,
engine-routed mechanism — a manifest-driven module can never `deploy:` its
way into shell-loader-visible territory, by design.

## Hook contract

`hooks.post_deploy` runs after a successful sync+deploy cycle for this
module, gated by **both** the manifest declaring it and the machine's own
`allow_hooks: true` for this module (set via `wb add --allow-hooks` or
machine-side state) — an ungated hook declaration is a no-op, not an error.

- `command` must be a list (argv form), never a bare string — a string
  would be silently word-split.
- `command[0]` is resolved relative to the module's deployed source tree
  and must exist in the repo at validation time.
- `run_on: changed` (default) fires when the module's tracked ref moved or a
  deploy action actually changed something this cycle, or on the module's
  very first successful sync. `always` fires unconditionally, every cycle.
  `initial` fires only on the module's first successful sync, ever.
- `timeout` (seconds, default 300) is enforced with `timeout`/`gtimeout` if
  available; a hook without either running is a logged, non-fatal warning.
- A hook's exit code is recorded but never fails the module's own sync —
  see [tracking-spec.md](tracking-spec.md) §Resilience.

See `docs/module-authoring.md` for the full hook environment (env vars
exposed to a running hook) and a reference hook skeleton.

## The compatibility boundary

The additive approach above covers everything currently in scope. A genuine
break would only be needed for something like changing `dest` validation
semantics incompatibly, making `register:` mandatory, or supporting multiple
manifests per repo. `version: 2` is now spoken for by the filename change
above (ARCHITECTURE.md §12 D46), so a future genuine break would need
`version: 3` — see ARCHITECTURE.md §5.4. Nothing today requires this.

## Validating your manifest

```sh
lib/manifest/validate.sh [path/to/manifest]
```

With no path, the validator discovers a manifest in the current directory
using the same precedence as the sync engine (see
[Manifest filenames & discovery](#manifest-filenames--discovery) above).

Requires [mikefarah/yq v4](https://github.com/mikefarah/yq#install) — a
developer-time dependency only; nothing on the hot/timer sync path depends
on `yq` (see `lib/manifest/parse.sh`, which reads the same manifest with
plain `awk`). On Ubuntu/Debian, `python3-yq` can shadow the real binary
under the same `yq` name — it is a completely different (jq-wrapper) tool
with no compatible CLI surface; `lib/manifest/validate.sh` detects and
rejects it rather than producing confusing parse errors.
