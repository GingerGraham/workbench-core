# Contributing to workbench-core

`workbench-core` is a single-maintainer project today (Graham Watts,
[@GingerGraham](https://github.com/GingerGraham)) but it's public and
contributions — issues, discussion, PRs — are welcome. This doc is the
condensed, practical version of the rules; the reasoning behind them
lives in [`ARCHITECTURE.md`](ARCHITECTURE.md), which is the source of
truth if the two ever disagree.

## Before you start

Read [`ARCHITECTURE.md`](ARCHITECTURE.md) — especially its §12
decisions log — before proposing anything that touches repo structure,
the manifest schema, or the sync engine. Something you're about to
propose may already be a settled (or deliberately rejected) decision;
if it is, argue for reopening it rather than re-litigating it from
scratch.

A handful of things are non-negotiable regardless of how a change is
framed:

- **Bash 3.2 compatibility** for everything under `bin/`, `lib/`,
  `bootstrap.sh`, and `tests/` — macOS ships Bash 3.2 by default and
  this project targets it directly. No associative arrays
  (`declare -A`), no `${var,,}`/`${var^^}`, no `mapfile`/`readarray`.
  Use an indexed array plus a registration/getter function pair
  instead — see `lib/core/version.sh`'s `_WB_SCRIPT_VERSIONS` handling
  for the pattern this codebase already uses. `.github/scripts/**` is
  the one exception: it runs only on GitHub-hosted `ubuntu-latest`
  runners and is free to use Bash 4+ features (see that directory's own
  header comments) — though by convention it still avoids associative
  arrays, for consistency rather than necessity.
- **No `git` in the production distribution path.** `bootstrap.sh` and
  the sync engine resolve and fetch via the GitHub API and a tarball —
  never a clone. `git` is reserved for this repo's own developer
  checkout (see below) and for private-repo/`branch:`-tracked modules,
  which shallow-clone-and-discard rather than persist a working tree.
- **Engine-computed destinations.** A module — or a change to core
  itself — never gets to specify where its own registered shell content
  lands. See `ARCHITECTURE.md` principle 1 and `lib/manifest/validate.sh`'s
  rejection of a `dest` on `register.shell[]` entries.
- **One generalised engine.** Core is "module zero," not a special
  case. A capability that only core can trigger, with every other
  module hitting a hardcoded branch to skip it, is the wrong shape —
  extend the engine so core is just the first caller.
- **Manifest changes stay additive.** `.dotfiles-sync.yml version: 1`
  must stay backward-compatible. A genuine break needs `version: 2` per
  `ARCHITECTURE.md` §5.4 — not a silent reinterpretation of an existing
  field.
- No Windows/PowerShell support — out of scope by design.

## Dev setup

Use a real `git clone`, not `bootstrap.sh` — this is the one case
meant to track a persistent, incrementally-pulled checkout
(`ARCHITECTURE.md` §9.6):

```sh
git clone https://github.com/GingerGraham/workbench-core.git
cd workbench-core
./bin/wb install
```

`wb install` detects the `.git` checkout and registers core with
`TRACK_MODE=branch:<your current branch>` — the same dev-tracking path
`wb dev`/`wb track --branch` gives every other module. Full detail:
[`docs/getting-started.md`](docs/getting-started.md#developer-setup).

## Making a change

### Commit messages

Every commit is [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>[(<scope>)][!]: <subject>

[optional body]

[BREAKING CHANGE: <description>]
```

- `type` is one of `feat` (minor bump), `fix`/`perf` (patch bump), or
  `refactor`/`docs`/`test`/`chore`/`ci`/`build` (no version effect).
- A `!` right after `type`/`scope`, or a `BREAKING CHANGE:` footer,
  forces **major** regardless of `type`.
- Leave `scope` off unless auto-detection would bump the wrong file —
  the full scoping rules (explicit file-path scope, the literal `core`
  scope) are in [`docs/release-process.md`](docs/release-process.md).
- A commit that touches a registered file (anything under `bin/`,
  `lib/`, or `bootstrap.sh`) with an unparseable type fails
  `pr-check.yml` — fix it with `git commit --amend` or an interactive
  rebase before the PR is reviewed, not after.

### CHANGELOG

Add an entry to `CHANGELOG.md`'s `## [Unreleased]` section, under the
[Keep a Changelog](https://keepachangelog.com/) heading it belongs
under (`### Added`, `### Fixed`, etc.), in the same PR that makes the
change. This isn't optional for anything user-facing: `release.yml`
refuses to cut a release if a real version bump is pending but
`[Unreleased]` is still empty — deliberately, since that emptiness is
the signal someone forgot the entry, not something the pipeline should
paper over. See [`docs/release-process.md`](docs/release-process.md#the-changelog-discipline).

### Tests

```sh
.github/scripts/ci/run-tests.sh
```

runs every `tests/check-*.sh` suite and prints the same OK:/FAIL:
summary CI does — safe to run locally, no GitHub Actions context
needed. Add or extend a suite when you change behaviour; the existing
suites are plain bash, numbered checks, no framework — match that
style rather than introducing one.

### Lint

```sh
shopt -s globstar
shellcheck bin/wb bootstrap.sh lib/**/*.sh tests/*.sh .github/scripts/**/*.sh
```

Runs at full severity, no `.shellcheckrc`. If a warning is a
known-safe idiom (the codebase's own `cond && ok || fail` pattern, for
instance), suppress it inline with `# shellcheck disable=` at the site,
matching the existing annotation convention — don't relax severity or
add a `.shellcheckrc` to make a warning go away.

### Bash 3.2 compatibility

Covered above under "Before you start" — repeated here because it's
the single most common way a PR fails after otherwise looking fine.
`tests/check-bash32-compat.sh` catches some violations mechanically but
isn't exhaustive.

## Opening a PR

`main`'s branch ruleset requires a PR (no direct pushes), signed
commits, linear history, and passing status checks. The
[PR template](.github/PULL_REQUEST_TEMPLATE.md) walks through the
checklist above — fill it in rather than deleting it. `pr-check.yml`
enforces the commit-format rule automatically; everything else is
checked by a human (currently just Graham) at review time.

## Questions

Open an issue — the
[bug report](.github/ISSUE_TEMPLATE/bug_report.yml) and
[feature request](.github/ISSUE_TEMPLATE/feature_request.yml)
templates cover the common cases.
