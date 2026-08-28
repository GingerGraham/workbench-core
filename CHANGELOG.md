# Changelog

All notable changes to `workbench-core` are documented here.

## [Unreleased]

### Added

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
