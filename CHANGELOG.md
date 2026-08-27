# Changelog

All notable changes to `workbench-core` are documented here.

## [Unreleased]

### Added

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
