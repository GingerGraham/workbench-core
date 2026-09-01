# Changelog

All notable changes to `workbench-core` are documented here.

## [Unreleased]

### Added

- `unzip`/`zip` added to the optional prerequisite list
  (`_WB_SHELL_PREREQS_OPTIONAL`), ahead of Wave C modules that will
  need to unpack `.zip`-distributed tools. Same optional treatment as
  `gpg` — nothing in core itself depends on either. See
  `ARCHITECTURE.md` §12 D25.
- **`wb tools`: the tool-updating framework.** `register.installers[].src`
  was declared/parsed/validated since Wave B but nothing ever consumed it
  at runtime — closed by a new, generalised registry: each declared file
  is introspected (as plain text, never sourced at render time) for
  `install-<name>`-shaped functions, rendered into a new per-module
  `installers.list` (`workbench_render_installers_list`,
  `lib/sync/engine.sh`) at exactly the same points `register.list` is.
  `wb tools list` / `wb tools update [<name>]` (`lib/core/tools.sh`, `bin/wb`)
  discover and invoke; core has no idea how any tool is installed, checked,
  or updated — that, and idempotency/version-checking, is entirely the
  module author's responsibility. Manual-only, never on the sync timer,
  and excluded for disabled modules exactly like `register.list`. Two
  modules declaring the same friendly name is resolved by
  first-by-module-name-order-wins, warned about once. `wb help`'s
  cross-reference mechanism extended to disambiguate `wb tools` from `wb
  update`. `STATE_SCHEMA_VERSION` bumped `1` → `2` for the new
  `installers.list` file (purely additive; migrated in place by `wb
  install`/`wb apply`, `workbench_migrate_state_schema`). See
  `ARCHITECTURE.md` §12 D23, `docs/module-authoring.md`.
- **Local overrides directory.** `~/.config/workbench/local/` replaces the
  single-file `90-local.sh`: one reserved-name `settings.sh` keeps exactly
  the old early+final two-pass semantics (this is where
  `WORKBENCH_PLAIN_SHELL`/`WORKBENCH_SHOW_FUNCTIONS`/etc. live), plus any
  number of other user-authored `*.sh` files, sourced once, together,
  filename-sorted, immediately after `settings.sh`'s final pass and before
  `WORKBENCH_USER_EXT_DIR` (unchanged, still the true last word of every
  content tier). `wb install`/`wb apply` scaffold the directory and a
  default, commented `settings.sh` if one doesn't already exist, never
  overwriting one that does. See `ARCHITECTURE.md` §12 D22,
  `contracts/state-schema.md`, `docs/getting-started.md`.
- **Core self-convergence on update**: `wb update`/`wb track`/`wb dev`
  targeting `core`, and the background timer's `wb sync run-if-due`, now
  detect when `core`'s resolved commit actually changed and automatically
  re-run `wb apply` afterward, so a `core` update always leaves the host
  fully converged (PATH symlink, rc stub, prereqs, SSH bootstrap, Ansible)
  without a separate manual step. Only fires on an actual commit change,
  never on a no-op cycle; a convergence failure is logged as a warning and
  never fails the triggering command. The Ansible pass is skipped when
  triggered from the unattended timer path via a new `--skip-ansible` flag
  on `wb install`/`wb apply` (also usable directly, e.g. `wb apply
  --skip-ansible`, for a faster convergence run without Ansible). Scoped to
  `core` only. See `ARCHITECTURE.md` §12 D20.
- **`wb help` rewrite**: the top-level `wb`/`wb help`/`wb -h`/`wb --help`
  block is now grouped by purpose (daily use / setup & host-level
  convergence / managing modules / advanced-internal) and explicitly
  disambiguates `update` vs `apply`, `track` vs `dev`, and `sync
  enable|disable` vs `track` — the confusion that motivated the core
  self-convergence work above. Every command also now has detailed,
  per-command help, reachable via both `wb help <command>` and `wb
  <command> --help`/`-h`, including explicit cross-references for the
  commands people confuse with each other. An unrecognised command name
  degrades gracefully (top-level block + a one-line note) instead of
  erroring.
- `tests/check-core-auto-apply.sh` and `tests/check-wb-help.sh`.
- **`bootstrap.sh`** (repo root): the canonical, documented production
  install path — `curl -fsSL .../bootstrap.sh | bash`. No `git` anywhere;
  resolves the latest `vX.Y.Z` release tag (falling back to `main`,
  permanently, when no tag exists yet), fetches it straight into the real
  `snapshots/<ref-slug>-<shortsha>/` path (never a scratch/temp directory),
  writes core's own `sync.conf`, and hands off to `bin/wb install`.
  Idempotent — re-running it hands off to convergence instead of
  re-fetching. Closes the drift between the intended tarball-based install
  design and the git-clone-only path the first-pass build actually shipped
  (see `ARCHITECTURE.md` §9.1a, D17). The `git clone` + `./bin/wb install`
  path is unchanged and still correct — it's now documented as "Developer
  setup" rather than the only path.
- **`wb version`**: new subcommand printing the release version
  (`workbench_release_version()`, reading the new repo-root `VERSION` file)
  and every loaded file's own script-local version. `wb install`/`wb apply`
  print the release version once at the start; `wb update`/
  `sync run-if-due`/the loader log it at `log_debug`, gated by
  `WORKBENCH_DEBUG`. Script-local versions are tracked via a new
  registration helper (`workbench_register_script_version()`/
  `workbench_print_script_versions()`, `lib/core/version.sh`) rather than a
  repeated same-named variable, avoiding clobbering across `bin/wb`'s
  ~20-file single-process source pass. See `ARCHITECTURE.md` §6.1, D18.
- `VERSION` file (repo root, `unreleased` until the first tag is cut) —
  the release/tag version, distinct from the existing contract-version
  integers and the new per-file script-local versions.
- `tests/check-bootstrap.sh` and `tests/check-wb-version.sh`.
- `tests/check-tools-registry.sh` and `tests/check-local-overrides.sh`.

- Initial `workbench-core` build (Wave B): version taxonomy, Core API
  surface (elevation helpers, distro/OS/WSL/shell/arch detection, getter
  introspection), manifest contract with `register:` ingestion, the
  multi-root shell loader, the distribution/tracking/sync engine (tarball
  fetch for public repos, shallow-clone-and-discard for private repos and
  `branch:` tracking, atomic snapshot swap, dynamic-cadence timer), SSH
  bootstrap for private-repo access, the `wb` CLI, and the Ansible
  convergence path for `wb install`/`wb apply`.
- `ARCHITECTURE.md` copied in from `workbench-precursor` as the canonical
  design reference (see its own §12 decisions log, D10-D15, for build-time
  clarifications).
- Known-modules catalog structure (`lib/modules/catalog.sh`), empty of real
  entries until Wave C.
- 14 test suites under `tests/` (plain bash, no framework), covering the
  Core API, manifest contract, multi-root loader, semver comparator,
  distribution engine (including a live no-`git`-in-`PATH` check), snapshot
  atomicity, sync-engine isolation, dynamic cadence, SSH bootstrap gating,
  and the `wb` CLI's convergence/idempotency guarantees.
- `contracts/{core-api,manifest-spec,tracking-spec,state-schema}.md` and
  `docs/{getting-started,module-authoring,troubleshooting}.md`.

### Fixed

- Fixed: **`register.list` was never rendered on a `bootstrap.sh`-driven
  install**, so `get-functions`, `sudo-test`, `get-elevation-command`,
  `dedupe-path`, and any other module's registered shell content silently
  never reached a real interactive shell, with `wb install` reporting full
  success and no warning anywhere. Root cause: `bootstrap.sh` registers
  core itself before handing off to `bin/wb install`, so
  `_wb_bootstrap_core_module`'s early-return fires and its
  `workbench_render_register_list` call (further down in that same
  function's non-early-return body) never runs — and nothing else in `wb
  install`/`wb apply`/`wb update` called it unconditionally; only a
  fetch-triggered sync cycle ever did. Fixed by making
  `register.list`/`installers.list` rendering an unconditional, idempotent
  step of `wb install`/`wb apply` for every loadable module, every run
  (`_wb_converge_module_registrations`, `bin/wb`) — one general fix, not a
  core-specific patch. `wb status` now also loudly flags a registered,
  sync-enabled module whose manifest declares register content but whose
  `register.list` is missing or empty. See `ARCHITECTURE.md` §12 D21,
  `tests/check-bootstrap-register-list.sh`.
- Fixed a latent `lib/loader.sh` ordering bug, found while reworking local
  overrides into a directory (`installers.list`/local-overrides work
  above): the "Behaviour flags" block (which forces
  `WORKBENCH_SHOW_FUNCTIONS=false` when `WORKBENCH_PLAIN_SHELL=true`) ran
  *before* the local-overrides file was ever sourced, so a
  `WORKBENCH_PLAIN_SHELL=true` set only there (rather than as a real
  pre-existing environment variable) correctly gated the prompt fallback
  but silently failed to gate `WORKBENCH_SHOW_FUNCTIONS`. The early source
  now runs first.
- Fixed: `wb` was never exposed on `PATH` after install — `wb install`/
  `wb apply` now symlink it into `~/.local/bin`, and `lib/loader.sh`
  defensively ensures `~/.local/bin` is on `PATH` on every shell start.
  See `ARCHITECTURE.md` §12 D19.
