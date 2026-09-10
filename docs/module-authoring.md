# Module authoring guide

How to make a repo — an ecosystem module (`workbench-*`) or an independent
tracked tool (`awsconfd`-style) — work with `workbench-core`'s sync engine
and shell loader.

## Table of contents

- [Do you need this at all?](#do-you-need-this-at-all)
- [The manifest](#the-manifest)
- [The tag format contract](#the-tag-format-contract)
- [Registering shell content](#registering-shell-content)
- [Declaring installers (`wb tools`)](#declaring-installers-wb-tools)
- [Publishing module info & docs (optional but recommended)](#publishing-module-info--docs-optional-but-recommended)
- [The arch-normalization snippet](#the-arch-normalization-snippet)
- [Hooks](#hooks)
- [Dev-mode disk duplication (read this before filing a "bug")](#dev-mode-disk-duplication)
- [Testing your manifest](#testing-your-manifest)

## Do you need this at all?

No — a repo with no `.dotfiles-sync.yml` at all is a valid clone-only
mirror. You only need a manifest if you want `workbench-core` to deploy
files, register shell functions, or run a hook for you.

## The manifest

See `contracts/manifest-spec.md` for the full field reference. The short
version: add `.dotfiles-sync.yml` to your repo root, declare `deploy:`
entries for anything that should land on disk, and — if you want shell
integration — `core_api:` plus `register:`.

```yaml
version: 1
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
you; see ARCHITECTURE.md §9.2 for why that's deferred.

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
your registered files land; this is deliberate (see ARCHITECTURE.md
principle 1) and is exactly what makes `register:` safe without a `dest`
denylist of its own.

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
lib/manifest/validate.sh path/to/.dotfiles-sync.yml
```

Requires [mikefarah/yq v4](https://github.com/mikefarah/yq#install) (a
developer-time-only dependency — see `contracts/manifest-spec.md`). Run
this by hand before pushing a manifest change, or let your module repo's
own CI run it for you — see below.

### CI (ARCHITECTURE.md §12 D40)

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
