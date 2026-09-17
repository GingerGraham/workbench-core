# Module authoring guide

How to make a repo — an ecosystem module (`workbench-*`) or an independent
tracked tool (`awsconfd`-style) — work with `workbench-core`'s sync engine
and shell loader.

## Table of contents

- [Do you need this at all?](#do-you-need-this-at-all)
- [The manifest](#the-manifest)
- [The tag format contract](#the-tag-format-contract)
- [Registering shell content](#registering-shell-content)
- [Shipping overridable defaults (`overrides_src`)](#shipping-overridable-defaults-overrides_src)
- [Declaring installers (`wb tools`)](#declaring-installers-wb-tools)
- [Declaring function availability (optional but recommended)](#declaring-function-availability-optional-but-recommended)
- [Publishing module info & docs (optional but recommended)](#publishing-module-info--docs-optional-but-recommended)
- [The arch-normalization snippet](#the-arch-normalization-snippet)
- [Hooks](#hooks)
- [Dev-mode disk duplication (read this before filing a "bug")](#dev-mode-disk-duplication)
- [Testing your manifest](#testing-your-manifest)
- [Agent instructions for module repos](#agent-instructions-for-module-repos)
- [Governance files for module repos](#governance-files-for-module-repos)

## Do you need this at all?

No — a repo with no manifest at all is a valid clone-only mirror. You only
need a manifest if you want `workbench-core` to deploy files, register
shell functions, or run a hook for you.

New module repo? Generate one from
[`GingerGraham/workbench-template`](https://github.com/GingerGraham/workbench-template)
(GitHub's "Use this template" button, or `gh repo create --template
GingerGraham/workbench-template`) rather than starting from scratch or
copying another module's tree — it carries the full directory skeleton,
a manifest stub, and every file below, and fills in the new module's
name for you on first push. [Agent instructions for module repos](#agent-instructions-for-module-repos)
and [Governance files for module repos](#governance-files-for-module-repos)
below remain the canonical source those files are periodically
re-snapshotted from — the template itself is not where you'd change
their content. The former holds the four canonical files (`AGENTS.md`, `CLAUDE.md`,
`.github/copilot-instructions.md`, `.claude/skills/conventional-commits/SKILL.md`)
every `workbench-*` module carries — copy from there, not from another
module's tree, so all of them stay in sync.

## The manifest

See `contracts/manifest-spec.md` for the full field reference, including
which filenames are discovered and in what order. The short version: add
`workbench.yml` (`version: 2`) to your repo root for a new or migrating
module — `.dotfiles-sync.yml` (`version: 1`) still works identically as the
legacy name — declare `deploy:` entries for anything that should land on
disk, and — if you want shell integration — `core_api:` plus `register:`.

```yaml
# workbench.yml
version: 2
branch: main
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/mytool.sh
      tier: tools
```

## The tag format contract

`TRACK_MODE=latest` (the default for anything registered via `wb add`)
resolves to the **highest tag matching exactly `vX.Y.Z`** — three numeric
segments, `v`-prefixed, no pre-release or build suffix. To be
`latest`-trackable, tag your releases this way: `v1.0.0`, `v1.4.12`,
`v2.0.0`. Tags like `1.0.0` (no `v`), `v1.0` (two segments), or
`v1.0.0-rc1` (pre-release suffix) are invisible to `latest` resolution —
not an error, they're just skipped. A pre-release tag is still a perfectly
valid input to an *explicit* pin (`wb track <name> --tag v1.0.0-rc1`); it's
only excluded from the automatic `latest` chain.

This is published now, formally, as the contract every module author
should follow — `workbench-core` does not (yet) validate compliance for
you; see `architecture.md` §9.2 for why that's deferred.

## Registering shell content

`register.shell[].src` is a path relative to your repo root;
`register.shell[].tier` (default `tools`) picks which loader tier it loads
into — see `contracts/core-api.md`'s loader-tier section for the full
order and the `platform`/`distro` filename-selector convention (a
`platform`-tier file only loads if its basename is `linux`, `macos`, or
`wsl`; a `distro`-tier file only loads if its basename matches the running
distro exactly).

**Do not** put a `dest:` on a `register.shell[]` entry — it isn't a
supported field, and the validator rejects it. The engine computes where
your registered files land; this is deliberate (see `architecture.md`
principle 1) and is exactly what makes `register:` safe without a `dest`
denylist of its own.

## Shipping overridable defaults (`overrides_src`)

If your module has an opinionated default a user might reasonably want to
change — a theme name, a plugin list, which of several interchangeable
tools it prefers when more than one is installed — don't hardcode it as a
literal inside a file your module deploys. Files your module deploys live
inside its own immutable, per-sync snapshot
(`${XDG_DATA_HOME}/workbench/modules/<name>/current/`) and get silently
replaced on every sync; a user editing one directly loses that edit the
next time your module updates (`docs/decisions-log.md` D16).

Instead:

1. Write the opinion as a shell variable your own tier file reads with a
   default, not a bare literal:

   ```bash
   # shell/omp.sh, tier: tools
   OMP_THEME="${OMP_THEME:-atomic}"
   ```

2. Declare an `overrides_src` in your manifest — a small, commented file
   shipped alongside your module, containing the variable(s) a user can
   uncomment to change:

   ```yaml
   overrides_src: shell/overrides.sh
   ```

   ```bash
   # shell/overrides.sh
   # Uncomment to change this module's defaults. This file is yours —
   # workbench-core deploys it once and never touches it again.

   # export OMP_THEME="jandedobbeleer"
   ```

The engine deploys this once, to
`~/.config/workbench/local/overrides/<your-module-name>.sh`, and sources
it early — before your module's own tier content runs, and before the
user's own `settings.sh` — so a value it sets is visible to your
`${VAR:-default}` code, and a user's own `settings.sh` still wins if they
set the same variable there instead. You never choose the destination —
there is no `dest` field, the same as `register.shell[]` — because this
file lands inside the one directory a user's shell trusts enough to
source unconditionally on every start.

If you don't have an opinion worth exposing yet, omit `overrides_src`
entirely — there's no placeholder to create, and nothing to migrate later
when you add one.

### `WORKBENCH_OVERRIDE_<SCOPE>` — naming convention for election-type opinions

A default like `OMP_THEME` already has a natural escape hatch —
`${OMP_THEME:-atomic}` is overridable the moment anyone sets `OMP_THEME`
anywhere upstream of your tier file running. It needs no special name.

An **election** — your module choosing between two or more
mutually-exclusive implementations of the same feature, like
workbench-shell's oh-my-posh > starship > oh-my-zsh prompt-engine
priority — is different. That priority is decided by hardcoded
`command -v <tool>` guard clauses, not by a variable, so there's nothing
for a user to set today. If your module has an election like this and you
want it overridable, name the override variable
`WORKBENCH_OVERRIDE_<SCOPE>` and check it at the top of every guard in
the election, before the `command -v` check:

```bash
# shell/starship.sh
command -v oh-my-posh &>/dev/null && [[ "${WORKBENCH_OVERRIDE_PROMPT_ENGINE:-}" != "starship" ]] && return 0
command -v starship &>/dev/null || return 0
```

`<SCOPE>` resolution:

- If the thing you're overriding already has a name in a cross-module
  contract (`contracts/core-api.md`), reuse that name minus the
  `WORKBENCH_` prefix — the prompt engine is already
  `WORKBENCH_PROMPT_ENGINE`/`WORKBENCH_PROMPT_SET`, so its override is
  `WORKBENCH_OVERRIDE_PROMPT_ENGINE`.
- Otherwise, `<MODULE>_<KNOB>` — e.g. `WORKBENCH_OVERRIDE_SHELL_ZSH_THEME`.

Don't rename an existing, already-working `${VAR:-default}` knob to fit
this prefix — it doesn't need one. Reserve `WORKBENCH_OVERRIDE_*` for
opinions that are currently hardcoded with no other escape hatch.

## Declaring installers (`wb tools`)

`register.installers[].src` is a path relative to your repo root, same
validation as `register.shell[].src`. Every top-level function in that file
named `install-<name>` (a **hard requirement**, not just a suggestion — it's
the only thing that makes your function discoverable at all) is picked up
by `wb tools list`/`wb tools install`/`wb tools upgrade` under the friendly
name `<name>` (the `install-` prefix stripped):

```yaml
register:
  installers:
    - src: shell/installers.sh
```

```sh
# shell/installers.sh
install-terraform() {
    # ... your own idempotency/version-checking logic here ...
}
```

Core's job stops at discovering `install-<name>` functions and invoking the
one you asked for — it does not know or guess how your tool is installed,
checked, or updated, and it never will. Critically, core **never** runs
your `install-<name>` function unless it was directly told to: `wb tools
install <name>` runs exactly that one tool; `wb tools install all` lists
every discovered tool and asks for a plain `y`/`yes` confirmation before
running any of them; and `wb tools upgrade [<name>|all]` only ever touches
a tool whose optional `installed-<name>` predicate (below) actually
reports it as installed. There is no bare "run everything with no
confirmation" path any more. **Idempotency and version-checking inside
`install-<name>` are entirely your responsibility as the module author.**
Whichever verb calls it, core just calls your function and reports
whatever it prints/returns; it does not track installed versions or diff
state on its own. Write `install-<name>` the way you'd write any script
meant to be run repeatedly and safely: check what's already installed,
and no-op (or upgrade) accordingly.

If your `install-<name>` function needs to unpack a `.zip`-distributed
release, `wb install`/`wb apply` will check for and report `unzip` as an
optional prerequisite (same treatment as `gpg`) — but, like every
optional prereq, it isn't installed automatically; your function should
still check for it and install it (or ask the user to) if it's missing.
`zip` is tracked on the same basis if you need to create an archive
rather than extract one.

`wb tools` is manual-only — it never runs on the background sync timer, and
is a distinct concept from `wb update`: `wb update` keeps your *module*
current (config text, shell registrations); `wb tools` keeps whatever
software your `install-*` functions happen to install current.

Two modules declaring the same friendly name (e.g. both defining
`install-terraform`) is a real constraint, not a silent surprise: `wb
tools` warns once and picks a winner by first-by-module-name-order —
choose a more specific friendly name if you don't want to depend on
alphabetical luck.

The friendly names `all`, `list`, `install`, `upgrade`, and `status` are
reserved for `wb tools`'s own subcommands/argument — an `install-all` or
`install-status`, say, is excluded from discovery entirely, with a
one-time warning, rather than silently shadowing (or colliding with) the
verb itself. Pick a different name.

## Reporting install status (optional but recommended)

Declare `installed-<name>` in the **same file** as `install-<name>` (no
separate manifest entry needed) to let `wb tools list --status` and `wb
tools upgrade` know whether your tool is actually present:

```sh
# shell/installers.sh
install-terraform() {
    # ... your own idempotency/version-checking logic here ...
}

installed-terraform() {
    command -v terraform &>/dev/null
}
```

The contract is deliberately minimal: **exit 0 means installed, exit 1
means not installed.** Anything else — you don't declare
`installed-<name>` at all, or it returns some other exit code, or it
errors — is treated as "unresponsive": `wb tools upgrade` will never run
`install-<name>` for it, on the principle that a wrong guess in either
direction is worse than an honest "don't know." If you don't implement
this, your tool is simply always unresponsive to `upgrade` — it remains
fully installable via `wb tools install <name>`, which never checks
status at all.

**If you declare `installed-<name>`, it must accurately reflect
reality.** This is a stronger obligation than idempotency inside
`install-<name>` itself: core treats whatever `installed-<name>` reports
as ground truth and acts on it unattended — a predicate that always
returns 0 regardless of actual state (or checks the wrong thing, or goes
stale) means `wb tools upgrade` will silently run `install-<name>`
believing it's a routine refresh of something already present, on every
invocation, with no other check in the loop. A predicate you're not
confident is genuinely correct should not be declared at all — the tool
falls back to "unresponsive," which is the safe default this whole
redesign exists to guarantee, not a degraded outcome.

This predicate should be cheap and side-effect-free (typically a single
`command -v`/file-existence check) — it may run once per tool on every
`wb tools list --status` or `wb tools upgrade` invocation.

## Declaring function availability (optional but recommended)

Declare `_<name>-available` in the **same file** as `<name>` (no manifest
entry needed) to let `<name>` be hidden from every listing surface —
`wb functions` and your own `get-<domain>-functions` getter alike —
whenever it can't actually be used:

```sh
# shell/aws.sh
aws-update() {
    install-aws
}

_aws-update-available() {
    command -v aws &>/dev/null
}
```

The contract is the same shape as `installed-<name>`: **exit 0 means
available, exit 1 means unavailable.** No predicate declared is not a
third state here — it means always available, since most functions have
nothing to gate and shouldn't need one. This predicate should be cheap
and side-effect-free (typically a single `command -v`), same as
`installed-<name>` — it may run once per function on every `wb functions`
invocation. Auth status, network calls, and hardware/state checks belong
in your function's own runtime preflight, never here.

Three ways to declare one, in order of preference:

**Several names share one simple check** — `_wb_declare_availability
<command> <name> [<name> ...]` (Core API, `lib/core/functions.sh`):

```sh
# shell/gpg.sh
_wb_declare_availability gh gpg-github-keys gpg-push-github
```

**Several names share an existing, more complex check** —
`_wb_alias_availability <check-function> <name> [<name> ...]`. If you
already have a loud `_xxx_require_yyy`-style preflight helper, extract a
quiet, boolean-returning twin it can call internally, and wire that twin
instead of duplicating the check:

```sh
# shell/disk-encryption.sh
_tpm_tools_present() {
    local cmd
    for cmd in "${_tpm_required_tools[@]}"; do
        command -v "${cmd}" &>/dev/null || return 1
    done
}
_wb_alias_availability _tpm_tools_present enroll-luks-tpm2 rotate-luks-key
```

**Anything else** — an OR of several tools, or a genuinely one-off
check — hand-write `_<name>-available` directly:

```sh
# shell/editors.sh
_open-workspace-available() {
    command -v code &>/dev/null || command -v code-insiders &>/dev/null
}
```

If your function already has its own loud preflight for the same
dependency, have it call the same quiet check as its first step instead
of re-testing `command -v` inline — one check, used by both the
function's own guard and every listing surface, never written twice.

Predicate functions are excluded from every listing automatically — the
leading underscore puts them in the same "private, never extracted"
class as every other `_`-prefixed function in this codebase.

### Discoverability

Gating hides genuinely-unusable commands from day-to-day listings, but
nothing is ever permanently lost. Whenever a listing hides at least one
name, it prints a one-line summary underneath — a count, plus the
specific missing command(s) where that can be recovered mechanically
from a `_wb_declare_availability`-generated predicate, or just the count
otherwise. `wb functions --all`, or `WORKBENCH_FUNCTIONS_SHOW_ALL=true`
in front of any getter, shows everything regardless of gating. You don't
need to do anything for your module to get this — it's automatic once
you're using the predicate convention above.

## Publishing module info & docs (optional but recommended)

`wb module info <name>` and `wb module docs <name>` let a user look up
what your module is and what it does without leaving the shell. Neither
requires `core_api:` — they're read-only and have no effect on sync,
deploy, or the loader, so they work even on the simplest deploy-only
manifest.

**`info`** — add a one-line `info.description` to your manifest:

```yaml
info:
  description: "Git configuration, aliases, and credential helpers"
```

Everything else `wb module info` shows (repository, visibility, tracking
mode, resolved commit, registration state) comes from what core already
tracks — `description` is the only thing you're actually publishing.
Leaving it out isn't an error; the user just sees a plain "not published
yet" line instead, pointing back at your repository. Keep it to one
line — anything longer belongs in your docs, below.

**`docs`** — drop a `HELP.md` at your repo root, and `wb module docs
<name>` prints it in full, read straight out of your module's synced
snapshot. No manifest field, no registration — pure convention. If you
don't have a `HELP.md`, your `README.md` is used instead; if you have
neither, the user sees a friendly pointer to your repository rather than
an error. Nothing beyond those two filenames is checked, so name it
exactly `HELP.md` if you want something distinct from your repo's
landing-page README.

## The arch-normalization snippet

`workbench-core` exposes `WORKBENCH_ARCH` — the raw, unmodified output of
`uname -m` (e.g. `x86_64`, `aarch64`, `arm64`). It deliberately does **not**
provide a universal name-normalizer, because upstream tools disagree on
convention: some want Go-style (`amd64`/`arm64`), some want uname-style
(`x86_64`/`aarch64`), a few also care about 32-bit (`386`/`arm`). Use
whichever of these two snippets matches the tool you're installing:

```sh
# Go-style (amd64/arm64) — common for tools distributed as Go binaries
case "${WORKBENCH_ARCH}" in
    x86_64)  _arch="amd64" ;;
    aarch64|arm64) _arch="arm64" ;;
    i386|i686) _arch="386" ;;
    armv7l)  _arch="arm" ;;
    *)       _arch="${WORKBENCH_ARCH}" ;;
esac
```

```sh
# uname-style (x86_64/aarch64) — common for tools that ship their own
# uname-based detection already and just need normalising to it
case "${WORKBENCH_ARCH}" in
    amd64)  _arch="x86_64" ;;
    arm64)  _arch="aarch64" ;;
    *)      _arch="${WORKBENCH_ARCH}" ;;
esac
```

Keep this mapping local to your own installer function — don't expect core
to have already normalized it for you.

## Hooks

`hooks.post_deploy` runs after your module's snapshot is deployed. Gated by
**both** your manifest declaring it and the machine registering your
module with `--allow-hooks` (`wb add <name> <url> --allow-hooks`) — an
undeclared or ungated hook is silently a no-op, never an error.

```yaml
hooks:
  post_deploy:
    command: ["hooks/post-deploy.sh"]
    run_on: changed   # changed (default) | always | initial
    timeout: 60
```

Your hook script receives, as environment variables:
`WORKBENCH_MODULE_NAME`, `WORKBENCH_MODULE_DIR` (the module's `current`
snapshot — `cwd` is already set there), `WORKBENCH_SYNC_REASON` (`add` |
`track` | `manual` | `scheduled`). Exit non-zero on failure — it's logged
and recorded, but never fails your module's sync (or any other module's).

## Dev-mode disk duplication

If you point your own module's tracking at your working branch
(`wb dev <name>` or `wb track <name> --branch <your-branch>`), you will end
up with **two copies** of your repo's files on disk: your own editing
clone (wherever you manage it — `git push`ed normally, entirely outside
anything `workbench` tracks), and a **separate**, independently-fetched
snapshot under `${XDG_DATA_HOME}/workbench/modules/<name>/snapshots/`,
refreshed on its own cadence.

**This is expected, by design, not a bug or drift.** `workbench-core`
never tracks or manages your editing clone at all — dev tracking is "fetch
this branch the way an end user's machine would," which is necessarily a
distinct copy. For small shell-config text files this is low-impact; don't
be alarmed to see it, and don't go looking for a way to make them the same
directory — there isn't one, and there isn't meant to be.

## Testing your manifest

```sh
lib/manifest/validate.sh [path/to/manifest]
```

Requires [mikefarah/yq v4](https://github.com/mikefarah/yq#install) (a
developer-time-only dependency — see `contracts/manifest-spec.md`). Run
this by hand before pushing a manifest change, or let your module repo's
own CI run it for you — see below.

### CI (`docs/decisions-log.md` D40)

Every ecosystem module repo has its own thin `.github/workflows/ci.yml`
that calls `workbench-core`'s reusable `module-ci.yml`:

```yaml
name: CI
on:
  pull_request:
    branches: [main]
  workflow_dispatch:
    inputs:
      core_ref:
        description: "workbench-core ref to test against"
        required: false

jobs:
  module-ci:
    uses: GingerGraham/workbench-core/.github/workflows/module-ci.yml@main
    with:
      module_name: <your-module's-catalog-name>   # e.g. git, gpg, cloud...
      core_ref: ${{ inputs.core_ref }}
```

It runs, on every PR:

- **shellcheck** over your `shell/**/*.sh` and `hooks/*.sh`.
- **manifest validate** — `lib/manifest/validate.sh` against your
  `.dotfiles-sync.yml`.
- **structural tests** — your own `tests/check-*.sh` suite, if you have
  one, on both `ubuntu-latest` and `macos-latest`.
- **add to core** — the actual question this brief exists to answer: does
  *this branch* add correctly to `workbench-core`? It runs real
  `wb add`/`wb track --branch <your-PR-branch>`/`wb update` against your
  module's own remote (a fork's, on a fork PR — never silently falling
  back to testing someone else's `main`), then asserts every `deploy:`
  destination landed, every `register.getters[]` function surfaced in
  `wb functions`, any `register.installers[]` entry surfaced in
  `wb tools list`, a second `wb update` is idempotent, and `wb remove`
  deregisters cleanly. Runs with `--allow-hooks`, so your `hooks:` content
  executes for real, against an isolated scratch `HOME`/`XDG_*` — never
  the runner's own environment.

The `workbench-core` ref this checks against defaults to core's latest
published GitHub Release, not `main` — override it with the
`core_ref` input (on a manual `workflow_dispatch` run) to test your module
against an in-flight core PR branch before it merges.

If the shared "add to core" check can't verify something specific to your
module (e.g. a side effect your `post_deploy` hook is supposed to have),
add an executable `tests/check-add-to-core.sh` to your repo — the shared
check runs it as an extra step if present, with `WB` and `MODULE_NAME`
already exported.

Commit messages are gated by a second thin workflow,
`.github/workflows/pr-check.yml` (`uses:
GingerGraham/workbench-core/.github/workflows/module-pr-check.yml@main`):
every commit on the PR must parse as a Conventional Commit
(`<type>[(scope)][!]: <subject>`) — module repos have no per-file
version-registration convention to gate on selectively, so this applies to
every commit, no exceptions.

Release automation (`.github/workflows/release.yml` /
`release-finalize.yml`, thin callers of `module-release.yml` /
`module-release-finalize.yml`) mirrors core's own propose-PR-then-finalize
release pipeline, but bumps only your repo's overall version/tag — module
repos have no per-file script version to bump individually.

## Agent instructions for module repos

Every `workbench-*` module repo carries the same four agent-instruction
files, ported from this repo's own topology (`docs/decisions-log.md`
D32, D58): `AGENTS.md` is the canonical, tool-agnostic entry point;
`CLAUDE.md` is a one-line `@AGENTS.md` import (Claude Code doesn't
auto-discover a root `AGENTS.md`); `.github/copilot-instructions.md` is
a maintained duplicate (Copilot's various surfaces don't uniformly
discover the root file either); and
`.claude/skills/conventional-commits/SKILL.md` is a module-scoped skill
covering this repo's own Conventional Commit grammar and PR-title
rules.

Module repos need neither a second `.github/instructions/*.instructions.md`
split (that exists in `workbench-core` only because core carries its own
`.github/scripts/**`, which is bash-4+-exempt — module repos check
core's scripts out at CI-time instead of committing anything
script-shaped locally) nor local relative doc links (a module's
`AGENTS.md` points at `workbench-core`'s docs on GitHub, since those
docs live in a different repo).

This section is the single source of truth for the four templates
below — when their content needs to change, edit it here first, then
re-propagate to all eleven module repos, not the other way round.
`<module>` is literal placeholder text a module author replaces with
the repo's own short name (`git`, `gpg`, `ssh`, `shell`, `cloud`, `iac`,
`containers`, `security`, `ai`, `devtools`, `desktop`).

### `AGENTS.md` (repo root)

````markdown
# Agent instructions — workbench-<module>

This file is the canonical, tool-agnostic entry point for any AI coding
agent working in this repo — Claude Code reads it via `CLAUDE.md`'s
`@AGENTS.md` import, GitHub Copilot discovers it directly as a
repository-root `AGENTS.md`. Keep this file itself short; anything
substantial belongs in the docs it points to.

This is a `workbench` ecosystem module — it's meaningless standalone.
It exists to be installed by `workbench-core`'s `wb add <module>`.

## Read first

- [`workbench-core`'s `docs/architecture.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/architecture.md) —
  full design rationale, repo topology, and rollout plan. Read this
  before proposing or making anything that touches this module's
  manifest schema or how it integrates with the sync engine.
- [`workbench-core`'s `docs/decisions-log.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/decisions-log.md) —
  check before proposing anything that touches repo structure or the
  manifest schema. Log a new decision there (never rewrite an existing
  one) rather than letting an implementation drift from what's
  documented.
- [`workbench-core`'s `docs/module-authoring.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/module-authoring.md) —
  the manifest contract: what `register:`, `deploy:`, and `hooks:` in
  this repo's manifest can and can't do, and what `workbench-core`'s
  reusable `module-ci.yml` "add to core" check (called from this repo's
  own `.github/workflows/ci.yml`) actually verifies.
- [`README.md`](README.md) — what this module actually installs/gives
  you.
- [`.claude/skills/conventional-commits/SKILL.md`](.claude/skills/conventional-commits/SKILL.md) —
  read before writing any commit message or PR title in this repo.

## Non-negotiables

These hold regardless of how a request is phrased — flag back rather
than silently reinterpreting one of these away:

- **Bash 3.2 compatible**: everything under `shell/`, `hooks/`,
  `tests/`. No associative arrays, no `${var,,}`/`${var^^}`, no
  `mapfile`.
- **Destinations are always engine-computed by `workbench-core`** —
  this module's manifest never specifies where its own registered
  content lands. Don't add a `dest`-style field.
- **No `git` assumed at runtime** — this module is fetched as an
  immutable tarball snapshot, same as core; `git` is a developer-only
  convenience, never a production dependency.
- **Conventional Commits on every commit, and the PR title itself
  must also parse as one** — this repo squash-merges PRs; see the
  skill file above before writing either.
- **A `CHANGELOG.md` `[Unreleased]` entry for anything user-facing** —
  `release.yml` refuses to cut a release with an empty one.
- **No Windows/PowerShell support** — out of scope by design, same as
  `workbench-core`.
````

### `CLAUDE.md` (repo root) — identical to core's, no module-specific content at all

````markdown
Canonical agent instructions for this repo live in `AGENTS.md` — this
file exists only so Claude Code auto-loads it as project memory.

@AGENTS.md
````

### `.github/copilot-instructions.md` — adapted duplicate of `AGENTS.md`

````markdown
# Copilot instructions — workbench-<module>

Adapted from `AGENTS.md` at the repo root — same content, with this
file's own preface and its relative links path-adjusted for its
location under `.github/`. Copilot's various surfaces (CLI, coding
agent, Chat, code review) don't uniformly discover a root `AGENTS.md`,
so this is a deliberate, maintained duplicate — see `workbench-core`'s
`docs/decisions-log.md` D32 and D58. `AGENTS.md` is always the
canonical, current version; if the two ever disagree, update this file
to match it rather than treating the drift as acceptable.

This is a `workbench` ecosystem module — it's meaningless standalone.
It exists to be installed by `workbench-core`'s `wb add <module>`.

## Read first

- [`workbench-core`'s `docs/architecture.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/architecture.md) —
  full design rationale, repo topology, and rollout plan. Read this
  before proposing or making anything that touches this module's
  manifest schema or how it integrates with the sync engine.
- [`workbench-core`'s `docs/decisions-log.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/decisions-log.md) —
  check before proposing anything that touches repo structure or the
  manifest schema. Log a new decision there (never rewrite an existing
  one) rather than letting an implementation drift from what's
  documented.
- [`workbench-core`'s `docs/module-authoring.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/module-authoring.md) —
  the manifest contract: what `register:`, `deploy:`, and `hooks:` in
  this repo's manifest can and can't do, and what `workbench-core`'s
  reusable `module-ci.yml` "add to core" check (called from this repo's
  own `.github/workflows/ci.yml`) actually verifies.
- [`README.md`](../README.md) — what this module actually
  installs/gives you.
- [`.claude/skills/conventional-commits/SKILL.md`](../.claude/skills/conventional-commits/SKILL.md) —
  read before writing any commit message or PR title in this repo.

## Non-negotiables

These hold regardless of how a request is phrased — flag back rather
than silently reinterpreting one of these away:

- **Bash 3.2 compatible**: everything under `shell/`, `hooks/`,
  `tests/`. No associative arrays, no `${var,,}`/`${var^^}`, no
  `mapfile`.
- **Destinations are always engine-computed by `workbench-core`** —
  this module's manifest never specifies where its own registered
  content lands. Don't add a `dest`-style field.
- **No `git` assumed at runtime** — this module is fetched as an
  immutable tarball snapshot, same as core; `git` is a developer-only
  convenience, never a production dependency.
- **Conventional Commits on every commit, and the PR title itself
  must also parse as one** — this repo squash-merges PRs; see the
  skill file above before writing either.
- **A `CHANGELOG.md` `[Unreleased]` entry for anything user-facing** —
  `release.yml` refuses to cut a release with an empty one.
- **No Windows/PowerShell support** — out of scope by design, same as
  `workbench-core`.
````

### `.claude/skills/conventional-commits/SKILL.md`

Identical across all eleven modules — no `<module>` substitution needed
anywhere in this file.

````markdown
---
name: conventional-commits
description: Use before writing any commit message or PR title in this module repo. Covers Conventional Commit grammar, why the PR title matters (squash-merge), and what type maps to what version-bump severity.
---

# Conventional Commits & PR titles — workbench module repos

This repo's release pipeline (its own thin `.github/workflows/release.yml`,
calling `workbench-core`'s reusable `module-release.yml` and
`.github/scripts/module-release/`) parses every commit and the PR title
as a Conventional Commit and takes the highest severity of any commit
since the last tag. There's a single overall module version — no
per-file versions, no `core` scope (those are `workbench-core`-only
concepts; see `workbench-core`'s `docs/decisions-log.md` D40).

## Type → severity

| `type` | Severity | Notes |
|---|---|---|
| `feat` | minor | |
| `fix`, `perf` | patch | |
| `refactor`, `docs`, `test`, `chore`, `ci`, `build` | none | informational only, no version effect |
| any type + `!` after type/scope, or a `BREAKING CHANGE:` footer | major | overrides the type's own severity |

Scope is optional and, unlike `workbench-core`, unvalidated — there's no
registered-file list to check it against. Omit it unless it genuinely
clarifies the subject.

## The PR title matters as much as the commit message

This repo squash-merges every PR. GitHub's squash commit message is the
PR *title*, not any individual commit's message — so the title needs
`type[(scope)][!]: subject` grammar too. A perfectly-formatted commit
inside a badly-titled PR still lands on `main` unparseable, and that
merge's severity is silently dropped — no version bump, no release, for
a real change. This repo's own `.github/workflows/pr-check.yml`
(`commit-format` job, calling `workbench-core`'s reusable
`module-pr-check.yml`) catches this before merge; don't rely on it
as the first time you check the title.

## Before opening the PR

- [ ] Every commit follows `type[(scope)][!]: subject`.
- [ ] The PR title itself is a valid Conventional Commit header.
- [ ] `CHANGELOG.md`'s `[Unreleased]` section has an entry for anything
      user-facing — the release workflow refuses to cut a release with
      an empty one.

Full mechanics live in `workbench-core`'s `docs/release-process.md` and
`docs/decisions-log.md` (D40, D47, D57).
````

## Governance files for module repos

Every `workbench-*` module repo carries the same seven repo-governance
files, ported from this repo's own topology (`docs/decisions-log.md`
D31, D60): `.github/PULL_REQUEST_TEMPLATE.md`, three
`.github/ISSUE_TEMPLATE/*` files (`bug_report.yml`,
`feature_request.yml`, `config.yml`), `.github/CODEOWNERS`,
`CONTRIBUTING.md`, and `SECURITY.md`.

Three differences from core's own versions, not oversights:

- **No `module_proposal.yml`.** Proposing a brand-new `workbench-*`
  module is a decision about `workbench-core`'s own catalog — it
  belongs on core's tracker, not any individual module repo's.
- **`CONTRIBUTING.md` has no commit-scope section.** Core's own
  `CONTRIBUTING.md` documents a `scope` naming convention because core
  has per-file registered-script versions a scope can disambiguate
  (`docs/decisions-log.md` D40). A module repo has a single overall
  version and no such registered-file list — there's nothing for a
  scope to disambiguate, so the module version omits the convention
  entirely rather than describing a validation that doesn't exist.
- **`SECURITY.md`'s trust-boundary section is scoped down.** Core's
  version documents the sync engine's own trust boundaries (no `git`
  in production, SSH deploy keys, engine-computed destinations, path
  rejection) because core *is* that engine. A module's `SECURITY.md`
  points at core's `SECURITY.md` for those and instead documents only
  what's specific to the module itself: that `hooks.post_deploy` is
  opt-in per machine (`--allow-hooks`) and that its registered shell
  content can't declare a `dest` outside its own snapshot namespace.

This section is the single source of truth for the seven templates
below — when their content needs to change, edit it here first, then
re-propagate to all eleven module repos, not the other way round.
`<module>` is literal placeholder text a module author replaces with
the repo's own short name (`git`, `gpg`, `ssh`, `shell`, `cloud`, `iac`,
`containers`, `security`, `ai`, `devtools`, `desktop`). Two of the
templates below (`bug_report.yml`, `SECURITY.md`'s "Automated PR
checks" section) are close cousins of core's own equivalents rather
than identical — see each template's surrounding note.

Two path lists below (the PR template's `shellcheck` line and
`CONTRIBUTING.md`'s Bash-3.2 note) assume a module repo has `shell/`,
`hooks/`, and `tests/` directories, matching `workbench-core`'s own
`module-ci.yml` lint job (which globs `shell/**/*.sh hooks/*.sh` —
`tests/*.sh` is deliberately excluded from shellcheck, run instead
under "structural tests"). Adjust a specific repo's copy if its layout
genuinely differs — don't carry that assumption forward silently. The
PR template's `shellcheck` line uses `find shell hooks -name '*.sh'
-exec shellcheck {} +` rather than `module-ci.yml`'s own
`shell/**/*.sh` glob: `**` needs Bash's `globstar` enabled (which
`module-ci.yml` does via `shopt -s globstar` before it globs, running
on a modern Actions-runner Bash) and isn't available in Bash 3.2 at
all, so a contributor pasting the glob form into their own shell can
silently shellcheck fewer files than CI does, or nothing at all — a
correctness gap `find` doesn't have (caught by automated review during
the ten-repo batch rollout). Drop `hooks` from the `find` invocation
for a repo with no `hooks/` directory, same as the `feature_request.yml`
option above.
`.github/ISSUE_TEMPLATE/feature_request.yml`'s "Area" dropdown has the
same assumption baked into its "Hooks (hooks.post_deploy)" option:
drop that option for a
repo with no `hooks/` directory and no `hooks:` declared in its
manifest (caught by automated review during the ten-repo batch
rollout — nine of the eleven module repos turned out not to have
`hooks/` at all, only `workbench-git` and `workbench-ssh` do).

### `.github/PULL_REQUEST_TEMPLATE.md`

````markdown
## Summary

<!-- What does this change do, and why? -->

## Related

<!-- Issue link, and/or the workbench-core docs/decisions-log.md decision
     this implements or requires. Leave blank if neither applies. -->

## Type of change

- [ ] `feat` — new capability (minor bump)
- [ ] `fix` / `perf` — bug fix or performance fix (patch bump)
- [ ] `refactor` / `docs` / `test` / `chore` / `ci` / `build` — no version effect
- [ ] Breaking change (`!` after type, or a `BREAKING CHANGE:` footer)

## Checklist

- [ ] Every commit follows Conventional Commits, and the **PR title**
      itself parses too — this repo squash-merges, and
      `module-pr-check.yml`'s `pr-title-format` job fails the PR
      otherwise. See [`CONTRIBUTING.md`](../CONTRIBUTING.md).
- [ ] If this is user-facing, `CHANGELOG.md`'s `## [Unreleased]` has a
      new entry under the right heading — `release.yml` refuses to cut
      a release with an empty one.
- [ ] `tests/check-*.sh` pass locally, if this module has any, and a
      new/updated suite exists if behaviour changed.
- [ ] `find shell hooks -name '*.sh' -exec shellcheck {} +` is clean.
- [ ] Everything under `shell/`, `hooks/`, `tests/` stays Bash 3.2
      compatible — see [`CONTRIBUTING.md`](../CONTRIBUTING.md#bash-32-compatibility).
- [ ] If this touches repo structure, the manifest schema, or the sync
      engine, `workbench-core`'s
      [`docs/decisions-log.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/decisions-log.md)
      has been checked for an existing decision.
- [ ] `README.md` updated if behaviour changed.

## How was this tested?

<!-- Manual steps, or "covered by tests/check-whatever.sh" -->
````

### `.github/ISSUE_TEMPLATE/bug_report.yml`

Adapted from core's own version: reports both this module's version
and (optionally) core's, since a module bug can stem from either side
of the sync boundary.

````yaml
name: Bug report
description: Report unexpected behaviour in workbench-<module>
title: "[Bug]: "
labels: ["bug"]
body:
  - type: markdown
    attributes:
      value: |
        Thanks for taking the time to report this. If this looks like an
        install/sync issue rather than something specific to this module,
        workbench-core's [troubleshooting guide](https://github.com/GingerGraham/workbench-core/blob/main/docs/troubleshooting.md)
        is worth a quick check first.
  - type: input
    id: module-version
    attributes:
      label: workbench-<module> version
      description: Output of `wb module info <module>`
    validations:
      required: true
  - type: input
    id: core-version
    attributes:
      label: workbench-core version
      description: Output of `wb version`
    validations:
      required: false
  - type: dropdown
    id: platform
    attributes:
      label: Platform
      options:
        - Fedora / RHEL-family Linux
        - Other Linux
        - macOS
        - WSL2
    validations:
      required: true
  - type: textarea
    id: what-happened
    attributes:
      label: What happened?
      description: What you expected to happen too, if it's not obvious.
    validations:
      required: true
  - type: textarea
    id: repro
    attributes:
      label: Steps to reproduce
    validations:
      required: false
  - type: textarea
    id: logs
    attributes:
      label: Relevant output
      description: Re-run with `WORKBENCH_DEBUG=true` if you can, and paste the relevant portion. This renders as a code block automatically.
      render: shell
  - type: checkboxes
    id: checks
    attributes:
      label: Checklist
      options:
        - label: I checked workbench-core's troubleshooting guide first, if this looked like an install/sync issue
          required: false
````

### `.github/ISSUE_TEMPLATE/feature_request.yml`

````yaml
name: Feature request
description: Propose new behaviour or a change to existing behaviour
title: "[Feature]: "
labels: ["enhancement"]
body:
  - type: textarea
    id: problem
    attributes:
      label: Problem / motivation
      description: What can't you do today, or what's awkward?
    validations:
      required: true
  - type: textarea
    id: solution
    attributes:
      label: Proposed solution
    validations:
      required: true
  - type: dropdown
    id: area
    attributes:
      label: Area
      options:
        - Aliases / shell functions
        - Installer (install-<tool> functions)
        - Hooks (hooks.post_deploy)
        - Manifest (register/deploy entries)
        - Docs (README)
        - CI / release automation
        - Other
    validations:
      required: true
  - type: textarea
    id: alternatives
    attributes:
      label: Alternatives considered
      description: Optional.
    validations:
      required: false
  - type: checkboxes
    id: checks
    attributes:
      label: Checklist
      options:
        - label: I checked workbench-core's decisions log — this isn't already a settled (or deliberately rejected) decision
          required: true
````

### `.github/ISSUE_TEMPLATE/config.yml`

````yaml
blank_issues_enabled: false
contact_links:
  - name: Troubleshooting guide
    url: https://github.com/GingerGraham/workbench-core/blob/main/docs/troubleshooting.md
    about: Check here before opening an issue — covers prereq, loader, sync, and SSH problems common to every module.
  - name: Architecture & decisions log
    url: https://github.com/GingerGraham/workbench-core/blob/main/docs/decisions-log.md
    about: Check the decisions log before proposing anything that touches repo structure, the manifest schema, or the sync engine — it may already be a settled decision.
````

**Do not add `module_proposal.yml`** — proposing a brand-new
`workbench-*` module belongs on `workbench-core`'s tracker, not an
individual module repo's.

### `.github/CODEOWNERS`

````
# Sole maintainer today — mirrors workbench-core's CODEOWNERS
# (docs/decisions-log.md D31/D33). This file exists so review requests
# are automatic and so a future collaborator's ownership boundaries are
# explicit and file-path-based rather than assumed. No branch ruleset on
# this repo requires Code Owner review yet, for the same reason core
# doesn't (D33) — a single owner can't satisfy a required-reviewer rule
# for their own PR.

* @GingerGraham
````

### `CONTRIBUTING.md`

````markdown
# Contributing to workbench-<module>

This is a `workbench` ecosystem module — it doesn't stand alone. It's
installed into a machine via `workbench-core`'s `wb add <module>`. Full
design rationale lives in `workbench-core`'s
[`docs/architecture.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/architecture.md)
and [`docs/decisions-log.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/decisions-log.md)
— check both before proposing anything that touches this module's
manifest schema or how it integrates with the sync engine.

## Non-negotiables

- **Bash 3.2 compatible** — see [below](#bash-32-compatibility).
- **Destinations are always engine-computed by `workbench-core`** — this
  module's manifest never specifies where its own registered content
  lands. Don't add a `dest`-style field to `register.shell[]` entries.
- **No `git` assumed at runtime** — this module is fetched as an
  immutable tarball snapshot; `git` is a developer-only convenience.
- **No Windows/PowerShell support** — out of scope by design, same as
  `workbench-core`.

## Dev setup

This repo isn't installed standalone. To develop against your own
working branch, from a machine that already has `workbench-core`
installed:

```sh
git clone https://github.com/GingerGraham/workbench-<module>.git
cd workbench-<module>

# if not already registered on this machine:
wb add <module>

# point this module's tracking at your working branch:
wb dev <module>
# — or directly:
wb track <module> --branch <your-branch>
```

`wb dev`/`wb track --branch` fetches a **separate**, independently
synced snapshot of your branch — your own editing clone and
workbench's fetched snapshot are two copies on disk by design, not
drift. See `workbench-core`'s `docs/architecture.md` §9.6.

## Making a change

### Commit messages

Every commit is [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>[!]: <subject>

[optional body]

[BREAKING CHANGE: <description>]
```

- `type` is one of `feat` (minor bump), `fix`/`perf` (patch bump), or
  `refactor`/`docs`/`test`/`chore`/`ci`/`build` (no version effect).
- A `!` right after `type`, or a `BREAKING CHANGE:` footer, forces
  **major** regardless of `type`.
- No `scope` convention here — unlike `workbench-core`, this repo has no
  per-file registered-script version to bump individually, so there's
  nothing for a scope to disambiguate.
- This repo squash-merges PRs, and the **PR title itself** must also
  parse as Conventional Commits — `module-pr-check.yml`'s
  `pr-title-format` job fails the PR otherwise.

### CHANGELOG

Add an entry to `CHANGELOG.md`'s `## [Unreleased]` section, under the
[Keep a Changelog](https://keepachangelog.com/) heading it belongs
under, in the same PR that makes the change. `release.yml` refuses to
cut a release if a real version bump is pending but `[Unreleased]` is
still empty.

### Tests

If this module has a `tests/` suite, run its `check-*.sh` scripts
directly before pushing — `module-ci.yml` runs the same suite on
`ubuntu-latest` and `macos-latest`. Validate the manifest with
`lib/manifest/validate.sh` from a `workbench-core` checkout (or let CI
do it for you).

### Bash 3.2 compatibility

Everything under `shell/`, `hooks/`, `tests/` must run under Bash 3.2:
no associative arrays, no `${var,,}`/`${var^^}`, no `mapfile`. This
mirrors `workbench-core`'s own constraint — see its `CONTRIBUTING.md`
for the full rationale.
````

### `SECURITY.md`

Adapted from core's own version — see this section's preamble for why
the "Supported versions" and "Reporting a vulnerability" content is
near-identical while "Trust boundaries worth knowing about" is scoped
down to what's specific to a module rather than repeating the engine's
own trust boundaries.

````markdown
# Security policy

## Supported versions

Only the latest tagged release (the latest `vX.Y.Z` tag) is supported.
There are no maintained LTS branches.

## Reporting a vulnerability

**Please don't open a public issue for a security problem.** Use
GitHub's private vulnerability reporting instead: go to the
[Security tab](https://github.com/GingerGraham/workbench-<module>/security)
→ "Report a vulnerability". This opens a private advisory only visible
to the maintainer until it's resolved.

This is a solo-maintained project — response is best-effort, not
covered by an SLA, but security reports get triaged ahead of everything
else in the backlog.

## Trust boundaries worth knowing about

This module ships shell content (aliases, functions) and, where
declared, an `install-<tool>` function and a `hooks.post_deploy`
script — but it's `workbench-core`'s sync engine that actually fetches,
places, and sources any of it. The engine-level trust boundaries
(tarball-only production fetch, SSH deploy keys for private/
`branch:`-tracked modules, engine-computed destinations, `..`/
absolute-path rejection) live in `workbench-core`'s own
[`SECURITY.md`](https://github.com/GingerGraham/workbench-core/blob/main/SECURITY.md)
— report anything that breaks those there.

What's specific to this repo:

- **`hooks.post_deploy` only runs if the machine explicitly opted in**
  with `wb add <module> --allow-hooks` — an undeclared or ungated hook
  is silently a no-op. If you find a way for this module's hook to run
  without that flag, report it.
- **This module's registered shell content is confined to its own
  snapshot namespace** — it cannot declare a `dest` and land content
  anywhere else. If you find a manifest shape that escapes that, report
  it.

## Automated PR checks

Every pull request to this repo runs three automated checks before
merge, shipped from `workbench-core` so every module stays on the same
list:

- **Secrets** (gitleaks) — hardcoded credentials, tokens, keys.
- **Malware signatures** (clamav) — known-malicious content via ClamAV's
  signature database.
- **Dangerous shell patterns** — a maintained list of known-bad
  constructs (remote-pipe-to-shell, world-writable permissions, etc).

These run alongside shellcheck and this repo's own structural tests.

## Out of scope

This pipeline only runs against code in `workbench-core` and the eleven
canonical `workbench-*` module repos. It says nothing about modules
obtained from anywhere else — `workbench` has no community module
submission or validation pipeline (deliberately, for now).
````
