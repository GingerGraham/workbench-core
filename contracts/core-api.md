# Core API contract

The interface `workbench-core` guarantees to every module — checked via a
manifest's `core_api: ">=X.Y <A.B>"` range against `CORE_API_VERSION`
(`~/.config/workbench/core/version`, see `contracts/state-schema.md`) before
any of that module's `register.shell[]` files are sourced. A module whose
declared range isn't satisfied is refused loudly (a warning naming the
module and the mismatch), never silently skipped.

## Platform facts

Exported once per shell session (`lib/loader.sh`, re-affirmed idempotently
by `workbench_detect_platform()` in `lib/core/functions.sh` if core's own
tier is sourced later):

| Variable | Values | Notes |
|---|---|---|
| `WORKBENCH_OS` | `Linux` \| `Mac` | |
| `WORKBENCH_WSL` | `true` \| `false` | |
| `WORKBENCH_DISTRO` | `rhel` \| `debian` \| `suse` \| `arch` \| `unknown` | Linux only; `unknown` on macOS. |
| `WORKBENCH_SHELL` | `bash` \| `zsh` \| `sh` | |
| `WORKBENCH_ARCH` | raw `uname -m` (e.g. `x86_64`, `arm64`, `aarch64`) | **New in workbench-core** — did not exist in the donor codebase at all. No universal name-normalizer is provided; see `docs/module-authoring.md` for the two common per-tool normalization snippets. |

## Elevation & shell utility functions

Defined in `lib/core/functions.sh`, available in every interactive shell
once core's own `core`-tier registration is sourced:

- `elevate-cmd <command...>` — runs a command elevated (`sudo` or `run0`).
- `get-elevation-command` — prints `sudo` or `run0`, whichever is usable.
- `sudo-test` — checks (without prompting) whether the current user has
  `sudo`/`run0` access.
- `dedupe-path` — removes duplicate `PATH` entries in place, preserving
  first-seen order.
- `detect-package-manager` — sets/exports `PACKAGE_MANAGER` to one of
  `apt`/`dnf`/`yum`/`zypper`/`pacman`/`brew`.
- `_read_prompt <prompt> <var>` / `_read_prompt_silent <prompt> <var>` —
  `/dev/tty`-safe interactive prompts, usable from a script even when stdin
  is not a terminal. Ported from workbench-precursor's `tools/git.sh` —
  deliberately part of core, not `workbench-git`, since it has no git-
  specific behaviour at all.
- `_extract_function_names` / `_extract_alias_names` / `_get_functions_in`
  / `_get_aliases_in` — the getter-introspection primitives every
  `get-<domain>-functions` getter (declared via a module's
  `register.getters[]`) is built from.

## Loader tiers

`register.shell[].tier` is one of `env` / `core` / `tools` / `platform` /
`distro` / `lazy`, sourced in that fixed order across every registered,
sync-enabled module (`lib/loader.sh`). Within a tier, modules are processed
in module-name order, and a module's own files in the order its
`register.list` lists them (by convention, prefix env-tier filenames
numerically — `00-`, `10-`, `20-` — the same way workbench-precursor's
`env/` directory did, to control intra-module ordering explicitly).

`platform` and `distro` are the two tiers with a filename-as-selector
convention layered on top: a `platform`-tier file only loads if its
basename (minus `.sh`) is `linux`, `macos`, or `wsl` (the last loading
*additionally* whenever `WORKBENCH_WSL=true`, not instead of the OS file); a
`distro`-tier file only loads if its basename matches `WORKBENCH_DISTRO`
exactly. Every other tier loads unconditionally — a module wanting narrower
conditional loading does so inside its own sourced file (e.g. guard on
`command -v <tool>`).

## The prompt-ownership convention

Core sets only a bare, functional fallback `PS1`/`PROMPT` — no opinionated
prompt-manager election (that belongs to `workbench-shell`, Wave C). A
module that wants to manage the prompt should do so from one of its own
registered tier files, then set `WORKBENCH_PROMPT_SET=true`; the loader
skips its own fallback whenever that variable is already set. This keeps
the loader itself free of any hardcoded list of known prompt tools.

## The tracking-variable contract

For every registered module (core included), the loader exports a
**derived, read-only** `WORKBENCH_TRACK_<MODULE>` environment variable,
sourced from that module's `sync.conf` (`TRACK_MODE:TRACK_REF`, e.g.
`latest:v1.4.2` or `branch:my-feature`) — never written back the other
direction. `<MODULE>` is the module's registration name, uppercased (ASCII,
ported through `tr` — no `${var^^}`, for bash 3.2 compatibility) with any
`-` replaced by `_`. Published now as a standing contract (ARCHITECTURE.md
§9.5/D7) so Wave C's modules have something settled to build against, even
though none exist yet. See `contracts/tracking-spec.md` for the full
`TRACK_MODE` state machine this variable reflects.

## Versioning

Three independent integers/semver in `~/.config/workbench/core/version` —
see `contracts/state-schema.md` for the full file shape and
`lib/core/semver.sh` for the range-satisfaction check.
