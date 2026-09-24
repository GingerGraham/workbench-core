# Core API contract

The interface `workbench-core` guarantees to every module — checked via a
manifest's `core_api: ">=X.Y <A.B>"` range against `CORE_API_VERSION`
(`~/.config/workbench/core/version`, see `contracts/state-schema.md`) before
any of that module's `register.shell[]` files are sourced. A module whose
declared range isn't satisfied is refused loudly (a warning naming the
module and the mismatch), never silently skipped.

**Before editing anything below this line:** adding a function, variable,
or platform fact to this file's documented surface requires bumping
`CORE_API_VERSION`'s minor segment in the same change (`lib/core/version.sh`
and `lib/core/version-defaults.conf`). Removing or changing the behaviour
of anything already documented here requires a major bump instead (reset
minor to `0`) — this invalidates every module's existing `<A.B>` upper
bound, so treat it as a real break, not a routine edit. See docs/decisions-log.md D29.

## Platform facts

Exported once per shell session (`lib/loader.sh`, re-affirmed idempotently
by `_workbench_detect_platform()` in `lib/core/functions.sh` if core's own
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
- `_str_lower <string>` — lowercases via `tr`, bash-3.2/zsh-safe (no
  `${var,,}`). **New in `CORE_API_VERSION` 1.1.**
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
  `register.getters[]`) is built from. `_get_functions_in`/
  `_get_aliases_in` also filter on the `_<name>-available` predicate
  convention below and print a hidden-count hint line — additive,
  script-transparent to a getter that never declares any predicates.
- `_wb_declare_availability <command> <name> [<name> ...]` /
  `_wb_alias_availability <check-function> <name> [<name> ...]` —
  bulk-declare a `_<name>-available` predicate for one or more
  function/alias names, backed by a `command -v <command>` check or an
  existing boolean-returning `<check-function>` respectively. **New in
  `CORE_API_VERSION` 1.2.** A module may also hand-write `_<name>-available`
  directly for anything more specific — that's a naming convention
  `_get_functions_in`/`_get_aliases_in` read, not a function this contract
  needs to declare. Exit 0 means the paired `<name>` is available/shown,
  exit 1 hides it from every listing surface; a `<name>` with no predicate
  declared is always shown. `wb functions --all` /
  `WORKBENCH_FUNCTIONS_SHOW_ALL=true` bypasses gating regardless of any
  predicate. See `docs/module-authoring.md`, "Declaring function
  availability", for the full contract.
- `_wb_run_with_timeout <seconds> <command> [args...]` — portable
  (bash-3.2-safe) watchdog: backgrounds `<command>`, races it against a
  sleep/kill watchdog, and returns its real exit status if it finished in
  time, or `124` (GNU `timeout`'s own convention) if it had to be killed.
  `_wb_function_available` (above) now runs every `_<name>-available`
  predicate through this, bounded to
  `WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS` (default `1`, overridable) — a
  predicate that hangs is killed and hidden, never blocks a listing
  command indefinitely. **New in `CORE_API_VERSION` 1.3.**
- `_wb_cache_bool <cache-key> -- <command> [args...]` — runs `<command>`
  at most once per `<cache-key>` for the lifetime of the current
  top-level process, returning the cached exit status on every later
  call with the same key, even across the subprocess boundary
  `_wb_run_with_timeout` introduces (file-backed, not an in-shell
  variable, precisely so a predicate call backgrounded by
  `_wb_run_with_timeout` still shares the cache). For a hand-written
  predicate whose real check is expensive (a live agent/hardware/network
  probe) but conceptually shared across several exposed names. `<cache-
  key>` is the author's own choice, never derived from `<command>` — see
  `docs/module-authoring.md`, "Declaring function availability", for a
  worked example. **New in `CORE_API_VERSION` 1.3.**

## Install-helper functions (`lib/core/installers-common.sh`)

**New in `CORE_API_VERSION` 1.1.** Promoted from workbench-precursor's
`installers-common.sh` (docs/decisions-log.md D34) so every module's
`install-<name>` functions (`register.installers[]`) share one
implementation instead of each ecosystem module (`workbench-cloud`,
`workbench-iac`, `workbench-containers`, `workbench-security`,
`workbench-ai`, `workbench-devtools`, `workbench-desktop`, and any future
module) carrying its own copy:

- `_download_file_robust <url> <output_file>` — retried https-only download
  that fails on HTTP errors; writes via temp file + rename, never resumes onto
  an existing file (changed in 1.4 — D74).
- `_node_version_at_least <major>` — true if the active `node`'s major
  version is `>= <major>`.
- `_ensure_npm` — ensures `npm` resolves, preferring `nvm` (live shell
  function → unsourced `nvm.sh` → LTS install → package-manager fallback).
- `_npm_global_install <package>` — installs/updates a global npm package,
  redirecting to `~/.local` when the active npm prefix is system-owned
  (`/usr`, `/opt`) so no elevation is required.

**New in `CORE_API_VERSION` 1.4.**

- `_wb_sha256 <file>` — prints the lowercase hex SHA-256 of `<file>`, via
  `sha256sum` (Linux) or `shasum -a 256` (macOS).
- `_wb_gh_asset_digest <releases-api-json> <browser_download_url>` — prints
  the hex SHA-256 GitHub publishes for one release asset (the asset's
  `"digest": "sha256:<hex>"` field), or nothing when the asset is absent or
  its digest is null. Integrity only: it proves the bytes are the ones GitHub
  stored for that release, not that upstream is trustworthy.
- `_wb_fetch_verified <url> <dest> <expectation> [asset-name]` — downloads
  `<url>`, verifies its SHA-256, and only then moves it to `<dest>`. Fails
  closed: any missing, malformed or mismatching hash leaves `<dest>`
  untouched and returns non-zero. `<expectation>` is one of:
  - `<64 hex chars>` — the expected SHA-256 itself
  - `sums:<url>` — an upstream checksums file, lines `"<hex>  <name>"` or
    `"<hex> *<name>"`; the line for `[asset-name]` is used (default: the
    last path segment of `<url>`)
  - `hashfile:<url>` — a file whose first whitespace-separated token is the
    hex digest (e.g. kubectl's `.sha256`, helm's `.sha256sum`)
- `_wb_key_has_fingerprint <keyfile> <fingerprint>` — true iff the OpenPGP
  key file (armored or binary) contains a primary key whose fingerprint is
  exactly `<fingerprint>` (40 hex; spaces and case ignored). Modules call
  this before trusting a vendor repository key with `rpm --import` or an
  apt keyring. Uses a throwaway `GNUPGHOME` so the user's keyring is never
  touched.

Registered in core's own `.dotfiles-sync.yml` at `tier: core`, the same
tier `functions.sh`/`version.sh` use — every module's `lazy`-tier installer
file is guaranteed these are already sourced by the time it runs.

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

Before every tier pass — including a reload in an already-running shell,
not just a fresh shell start — the loader clears `WORKBENCH_PROMPT_SET`/
`WORKBENCH_PROMPT_ENGINE` and, only if a previous pass in this same shell
had already set them, resets bash's `PROMPT_COMMAND`/zsh's
`precmd_functions` too (docs/decisions-log.md D50). A prompt-owning module
can rely on this: your own guard never needs to defensively clear a
competing engine's leftover hook before running — by the time your tier
content is reached, the slate is already as clean as a brand-new shell's.

## The tracking-variable contract

For every registered module (core included), the loader exports a
**derived, read-only** `WORKBENCH_TRACK_<MODULE>` environment variable,
sourced from that module's `sync.conf` (`TRACK_MODE:TRACK_REF`, e.g.
`latest:v1.4.2` or `branch:my-feature`) — never written back the other
direction. `<MODULE>` is the module's registration name, uppercased (ASCII,
ported through `tr` — no `${var^^}`, for bash 3.2 compatibility) with any
`-` replaced by `_`. Published now as a standing contract (docs/architecture.md
§9.5/D7) so Wave C's modules have something settled to build against, even
though none exist yet. See `contracts/tracking-spec.md` for the full
`TRACK_MODE` state machine this variable reflects.

## Versioning

Three independent values (the first, `CORE_API_VERSION`, is itself `X.Y`,
not a bare integer — see D29) in `~/.config/workbench/core/version` —
see `contracts/state-schema.md` for the full file shape and
`lib/core/semver.sh` for the range-satisfaction check.

`CORE_API_VERSION` is unconditionally resynced to the currently-running
release's value on every `wb install`/`wb apply`
(`_workbench_sync_version_facts`, `lib/core/version.sh`) — it states only
what the running code provides, with no side effect to sequence, so an
existing host is never allowed to lag a fresh install (docs/decisions-log.md
D36). `STATE_SCHEMA_VERSION` keeps its separate, deliberate
migrate-then-advance semantics (`_workbench_migrate_state_schema`),
unchanged — it asserts a claim about the shape of other on-disk files, so
advancing it has to be sequenced with that shape's own migration.

The version file previously also carried a `MANIFEST_SCHEMA_VERSION`
field; it has been retired (docs/decisions-log.md D37) — its getter had zero
callers, and real manifest-schema-version enforcement was always the
separate, hardcoded `_WB_MANIFEST_SCHEMA_VERSIONS_SUPPORTED` constant
(`lib/manifest/parse.sh`/`validate.sh`).
