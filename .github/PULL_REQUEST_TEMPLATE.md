## Summary

<!-- What does this change do, and why? -->

## Related

<!-- Issue link, and/or the ARCHITECTURE.md §12 decision this
     implements or requires (e.g. "Implements D31"). Leave blank if
     neither applies. -->

## Type of change

- [ ] `feat` — new capability (minor bump)
- [ ] `fix` / `perf` — bug fix or performance fix (patch bump)
- [ ] `refactor` / `docs` / `test` / `chore` / `ci` / `build` — no version effect
- [ ] Breaking change (`!` after type/scope, or a `BREAKING CHANGE:` footer)

## Checklist

- [ ] Every commit touching a registered file (`bin/`, `lib/`,
      `bootstrap.sh`) follows Conventional Commits — `pr-check.yml`
      fails the PR otherwise. See [`docs/release-process.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/release-process.md).
- [ ] If this is user-facing, `CHANGELOG.md`'s `## [Unreleased]` has a
      new entry under the right heading — `release.yml` refuses to cut
      a release with an empty `[Unreleased]` section.
- [ ] `tests/check-*.sh` pass locally (`.github/scripts/ci/run-tests.sh`),
      and a new/updated suite exists if behaviour changed.
- [ ] `shellcheck bin/wb bootstrap.sh lib/**/*.sh tests/*.sh .github/scripts/**/*.sh` is clean.
- [ ] Anything under `bin/`, `lib/`, `bootstrap.sh`, or `tests/` stays
      Bash 3.2 compatible — see [`CONTRIBUTING.md`](https://github.com/GingerGraham/workbench-core/blob/main/CONTRIBUTING.md#bash-32-compatibility).
      `.github/scripts/**` is exempt.
- [ ] If this touches repo structure, the manifest schema, or the sync
      engine, [`ARCHITECTURE.md`](https://github.com/GingerGraham/workbench-core/blob/main/ARCHITECTURE.md) §12 has been
      checked for an existing decision, and a new entry added if this
      settles something new.
- [ ] Docs (`docs/`, `contracts/`, `README.md`) updated if behaviour or
      a contract changed.

## How was this tested?

<!-- Manual steps, or "covered by tests/check-whatever.sh" -->
