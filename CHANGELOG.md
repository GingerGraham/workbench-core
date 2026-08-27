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
  design reference (see its own §12 decisions log, D10-D12, for build-time
  clarifications).
