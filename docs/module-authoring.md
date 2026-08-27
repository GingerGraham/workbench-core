# Module authoring guide

How to make a repo — an ecosystem module (`workbench-*`) or an independent
tracked tool (`awsconfd`-style) — work with `workbench-core`'s sync engine
and shell loader.

## Table of contents

- [Do you need this at all?](#do-you-need-this-at-all)
- [The manifest](#the-manifest)
- [The tag format contract](#the-tag-format-contract)
- [Registering shell content](#registering-shell-content)
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
developer-time-only dependency — see `contracts/manifest-spec.md`).
