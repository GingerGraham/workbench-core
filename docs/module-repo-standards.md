# Module repo standards

The files, CI and release workflows every `workbench-*` module repo
carries, and the canonical content `workbench-template` is snapshotted
from. This is maintainer material. For writing a module, see the
[module authoring guide](guide/module-authoring.md).

When any of the content below needs to change, edit it here first,
then propagate it to every module repo and to `workbench-template`,
not the other way round.

## Commit, CI and release workflows

Every module repo's `.github/workflows/ci.yml` is a thin caller of
`workbench-core`'s reusable `module-ci.yml` (`docs/decisions-log.md`
D40). What it checks is in the module authoring guide's
[Testing your manifest](guide/module-authoring.md#testing-your-manifest)
section.

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

Each module repo's own thin `release.yml` also carries a
`workflow_dispatch` trigger (`bump_type`: patch/minor/major, optional
`reason`), passed straight through to the reusable `module-release.yml`'s
own `bump_type`/`reason` inputs — see `workbench-core`'s
`docs/release-process.md#manual-releases-workflow_dispatch` and
`docs/decisions-log.md` D67 for the full mechanics (a floor on the
computed severity, never a downgrade; the CHANGELOG gate still applies in
full). The trigger itself has to be declared in each module's own
workflow file — `workflow_call` doesn't inherit triggers — so a new
module scaffolded from `workbench-template` should carry it from the
start; check `workbench-template`'s own `release.yml` is current before
assuming a fresh module already has it.

## Agent instructions for module repos

Every `workbench-*` module repo carries the same four agent-instruction
files, ported from this repo's own topology (`docs/decisions-log.md`
D32, D58): `AGENTS.md` is the canonical, tool-agnostic entry point;
`CLAUDE.md` is a one-line `@AGENTS.md` import (Claude Code doesn't
auto-discover a root `AGENTS.md`); `.github/copilot-instructions.md` is
a maintained duplicate (Copilot's various surfaces don't uniformly
discover the root file either); and
`.claude/skills/conventional-commits/SKILL.md` is a module-scoped skill
covering this repo's own Conventional Commit grammar and PR-title
rules.

Module repos need neither a second `.github/instructions/*.instructions.md`
split (that exists in `workbench-core` only because core carries its own
`.github/scripts/**`, which is bash-4+-exempt — module repos check
core's scripts out at CI-time instead of committing anything
script-shaped locally) nor local relative doc links (a module's
`AGENTS.md` points at `workbench-core`'s docs on GitHub, since those
docs live in a different repo).

This section is the single source of truth for the four templates
below — when their content needs to change, edit it here first, then
re-propagate to all eleven module repos, not the other way round.
`<module>` is literal placeholder text a module author replaces with
the repo's own short name (`git`, `gpg`, `ssh`, `shell`, `cloud`, `iac`,
`containers`, `security`, `ai`, `devtools`, `desktop`).

### `AGENTS.md` (repo root)

````markdown
# Agent instructions — workbench-<module>

This file is the canonical, tool-agnostic entry point for any AI coding
agent working in this repo — Claude Code reads it via `CLAUDE.md`'s
`@AGENTS.md` import, GitHub Copilot discovers it directly as a
repository-root `AGENTS.md`. Keep this file itself short; anything
substantial belongs in the docs it points to.

This is a `workbench` ecosystem module — it's meaningless standalone.
It exists to be installed by `workbench-core`'s `wb add <module>`.

## Read first

- [`workbench-core`'s `docs/architecture.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/architecture.md) —
  full design rationale, repo topology, and rollout plan. Read this
  before proposing or making anything that touches this module's
  manifest schema or how it integrates with the sync engine.
- [`workbench-core`'s `docs/decisions-log.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/decisions-log.md) —
  check before proposing anything that touches repo structure or the
  manifest schema. Log a new decision there (never rewrite an existing
  one) rather than letting an implementation drift from what's
  documented.
- [`workbench-core`'s `docs/module-authoring.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/module-authoring.md) —
  the manifest contract: what `register:`, `deploy:`, and `hooks:` in
  this repo's manifest can and can't do, and what `workbench-core`'s
  reusable `module-ci.yml` "add to core" check (called from this repo's
  own `.github/workflows/ci.yml`) actually verifies.
- [`README.md`](README.md) — what this module actually installs/gives
  you.
- [`.claude/skills/conventional-commits/SKILL.md`](.claude/skills/conventional-commits/SKILL.md) —
  read before writing any commit message or PR title in this repo.

## Non-negotiables

These hold regardless of how a request is phrased — flag back rather
than silently reinterpreting one of these away:

- **Bash 3.2 compatible**: everything under `shell/`, `hooks/`,
  `tests/`. No associative arrays, no `${var,,}`/`${var^^}`, no
  `mapfile`.
- **Destinations are always engine-computed by `workbench-core`** —
  this module's manifest never specifies where its own registered
  content lands. Don't add a `dest`-style field.
- **No `git` assumed at runtime** — this module is fetched as an
  immutable tarball snapshot, same as core; `git` is a developer-only
  convenience, never a production dependency.
- **Conventional Commits on every commit, and the PR title itself
  must also parse as one** — this repo squash-merges PRs; see the
  skill file above before writing either.
- **A `CHANGELOG.md` `[Unreleased]` entry for anything user-facing** —
  `release.yml` refuses to cut a release with an empty one.
- **No Windows/PowerShell support** — out of scope by design, same as
  `workbench-core`.
````

### `CLAUDE.md` (repo root) — identical to core's, no module-specific content at all

````markdown
Canonical agent instructions for this repo live in `AGENTS.md` — this
file exists only so Claude Code auto-loads it as project memory.

@AGENTS.md
````

### `.github/copilot-instructions.md` — adapted duplicate of `AGENTS.md`

````markdown
# Copilot instructions — workbench-<module>

Adapted from `AGENTS.md` at the repo root — same content, with this
file's own preface and its relative links path-adjusted for its
location under `.github/`. Copilot's various surfaces (CLI, coding
agent, Chat, code review) don't uniformly discover a root `AGENTS.md`,
so this is a deliberate, maintained duplicate — see `workbench-core`'s
`docs/decisions-log.md` D32 and D58. `AGENTS.md` is always the
canonical, current version; if the two ever disagree, update this file
to match it rather than treating the drift as acceptable.

This is a `workbench` ecosystem module — it's meaningless standalone.
It exists to be installed by `workbench-core`'s `wb add <module>`.

## Read first

- [`workbench-core`'s `docs/architecture.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/architecture.md) —
  full design rationale, repo topology, and rollout plan. Read this
  before proposing or making anything that touches this module's
  manifest schema or how it integrates with the sync engine.
- [`workbench-core`'s `docs/decisions-log.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/decisions-log.md) —
  check before proposing anything that touches repo structure or the
  manifest schema. Log a new decision there (never rewrite an existing
  one) rather than letting an implementation drift from what's
  documented.
- [`workbench-core`'s `docs/module-authoring.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/module-authoring.md) —
  the manifest contract: what `register:`, `deploy:`, and `hooks:` in
  this repo's manifest can and can't do, and what `workbench-core`'s
  reusable `module-ci.yml` "add to core" check (called from this repo's
  own `.github/workflows/ci.yml`) actually verifies.
- [`README.md`](../README.md) — what this module actually
  installs/gives you.
- [`.claude/skills/conventional-commits/SKILL.md`](../.claude/skills/conventional-commits/SKILL.md) —
  read before writing any commit message or PR title in this repo.

## Non-negotiables

These hold regardless of how a request is phrased — flag back rather
than silently reinterpreting one of these away:

- **Bash 3.2 compatible**: everything under `shell/`, `hooks/`,
  `tests/`. No associative arrays, no `${var,,}`/`${var^^}`, no
  `mapfile`.
- **Destinations are always engine-computed by `workbench-core`** —
  this module's manifest never specifies where its own registered
  content lands. Don't add a `dest`-style field.
- **No `git` assumed at runtime** — this module is fetched as an
  immutable tarball snapshot, same as core; `git` is a developer-only
  convenience, never a production dependency.
- **Conventional Commits on every commit, and the PR title itself
  must also parse as one** — this repo squash-merges PRs; see the
  skill file above before writing either.
- **A `CHANGELOG.md` `[Unreleased]` entry for anything user-facing** —
  `release.yml` refuses to cut a release with an empty one.
- **No Windows/PowerShell support** — out of scope by design, same as
  `workbench-core`.
````

### `.claude/skills/conventional-commits/SKILL.md`

Identical across all eleven modules — no `<module>` substitution needed
anywhere in this file.

````markdown
---
name: conventional-commits
description: Use before writing any commit message or PR title in this module repo. Covers Conventional Commit grammar, why the PR title matters (squash-merge), and what type maps to what version-bump severity.
---

# Conventional Commits & PR titles — workbench module repos

This repo's release pipeline (its own thin `.github/workflows/release.yml`,
calling `workbench-core`'s reusable `module-release.yml` and
`.github/scripts/module-release/`) parses every commit and the PR title
as a Conventional Commit and takes the highest severity of any commit
since the last tag. There's a single overall module version — no
per-file versions, no `core` scope (those are `workbench-core`-only
concepts; see `workbench-core`'s `docs/decisions-log.md` D40).

## Type → severity

| `type` | Severity | Notes |
|---|---|---|
| `feat` | minor | |
| `fix`, `perf` | patch | |
| `refactor`, `docs`, `test`, `chore`, `ci`, `build` | none | informational only, no version effect |
| any type + `!` after type/scope, or a `BREAKING CHANGE:` footer | major | overrides the type's own severity |

Scope is optional and, unlike `workbench-core`, unvalidated — there's no
registered-file list to check it against. Omit it unless it genuinely
clarifies the subject.

## The PR title matters as much as the commit message

This repo squash-merges every PR. GitHub's squash commit message is the
PR *title*, not any individual commit's message — so the title needs
`type[(scope)][!]: subject` grammar too. A perfectly-formatted commit
inside a badly-titled PR still lands on `main` unparseable, and that
merge's severity is silently dropped — no version bump, no release, for
a real change. This repo's own `.github/workflows/pr-check.yml`
(`commit-format` job, calling `workbench-core`'s reusable
`module-pr-check.yml`) catches this before merge; don't rely on it
as the first time you check the title.

## Before opening the PR

- [ ] Every commit follows `type[(scope)][!]: subject`.
- [ ] The PR title itself is a valid Conventional Commit header.
- [ ] `CHANGELOG.md`'s `[Unreleased]` section has an entry for anything
      user-facing — the release workflow refuses to cut a release with
      an empty one.

Full mechanics live in `workbench-core`'s `docs/release-process.md` and
`docs/decisions-log.md` (D40, D47, D57).
````

## Governance files for module repos

Every `workbench-*` module repo carries the same seven repo-governance
files, ported from this repo's own topology (`docs/decisions-log.md`
D31, D60): `.github/PULL_REQUEST_TEMPLATE.md`, three
`.github/ISSUE_TEMPLATE/*` files (`bug_report.yml`,
`feature_request.yml`, `config.yml`), `.github/CODEOWNERS`,
`CONTRIBUTING.md`, and `SECURITY.md`.

Three differences from core's own versions, not oversights:

- **No `module_proposal.yml`.** Proposing a brand-new `workbench-*`
  module is a decision about `workbench-core`'s own catalog — it
  belongs on core's tracker, not any individual module repo's.
- **`CONTRIBUTING.md` has no commit-scope section.** Core's own
  `CONTRIBUTING.md` documents a `scope` naming convention because core
  has per-file registered-script versions a scope can disambiguate
  (`docs/decisions-log.md` D40). A module repo has a single overall
  version and no such registered-file list — there's nothing for a
  scope to disambiguate, so the module version omits the convention
  entirely rather than describing a validation that doesn't exist.
- **`SECURITY.md`'s trust-boundary section is scoped down.** Core's
  version documents the sync engine's own trust boundaries (no `git`
  in production, SSH deploy keys, engine-computed destinations, path
  rejection) because core *is* that engine. A module's `SECURITY.md`
  points at core's `SECURITY.md` for those and instead documents only
  what's specific to the module itself: that `hooks.post_deploy` is
  opt-in per machine (`--allow-hooks`) and that its registered shell
  content can't declare a `dest` outside its own snapshot namespace.

This section is the single source of truth for the seven templates
below — when their content needs to change, edit it here first, then
re-propagate to all eleven module repos, not the other way round.
`<module>` is literal placeholder text a module author replaces with
the repo's own short name (`git`, `gpg`, `ssh`, `shell`, `cloud`, `iac`,
`containers`, `security`, `ai`, `devtools`, `desktop`). Two of the
templates below (`bug_report.yml`, `SECURITY.md`'s "Automated PR
checks" section) are close cousins of core's own equivalents rather
than identical — see each template's surrounding note.

Two path lists below (the PR template's `shellcheck` line and
`CONTRIBUTING.md`'s Bash-3.2 note) assume a module repo has `shell/`,
`hooks/`, and `tests/` directories, matching `workbench-core`'s own
`module-ci.yml` lint job (which globs `shell/**/*.sh hooks/*.sh` —
`tests/*.sh` is deliberately excluded from shellcheck, run instead
under "structural tests"). Adjust a specific repo's copy if its layout
genuinely differs — don't carry that assumption forward silently. The
PR template's `shellcheck` line uses `find shell hooks -name '*.sh'
-exec shellcheck {} +` rather than `module-ci.yml`'s own
`shell/**/*.sh` glob: `**` needs Bash's `globstar` enabled (which
`module-ci.yml` does via `shopt -s globstar` before it globs, running
on a modern Actions-runner Bash) and isn't available in Bash 3.2 at
all, so a contributor pasting the glob form into their own shell can
silently shellcheck fewer files than CI does, or nothing at all — a
correctness gap `find` doesn't have (caught by automated review during
the ten-repo batch rollout). Drop `hooks` from the `find` invocation
for a repo with no `hooks/` directory, same as the `feature_request.yml`
option above.
`.github/ISSUE_TEMPLATE/feature_request.yml`'s "Area" dropdown has the
same assumption baked into its "Hooks (hooks.post_deploy)" option:
drop that option for a
repo with no `hooks/` directory and no `hooks:` declared in its
manifest (caught by automated review during the ten-repo batch
rollout — nine of the eleven module repos turned out not to have
`hooks/` at all, only `workbench-git` and `workbench-ssh` do).

### `.github/PULL_REQUEST_TEMPLATE.md`

````markdown
## Summary

<!-- What does this change do, and why? -->

## Related

<!-- Issue link, and/or the workbench-core docs/decisions-log.md decision
     this implements or requires. Leave blank if neither applies. -->

## Type of change

- [ ] `feat` — new capability (minor bump)
- [ ] `fix` / `perf` — bug fix or performance fix (patch bump)
- [ ] `refactor` / `docs` / `test` / `chore` / `ci` / `build` — no version effect
- [ ] Breaking change (`!` after type, or a `BREAKING CHANGE:` footer)

## Checklist

- [ ] Every commit follows Conventional Commits, and the **PR title**
      itself parses too — this repo squash-merges, and
      `module-pr-check.yml`'s `pr-title-format` job fails the PR
      otherwise. See [`CONTRIBUTING.md`](../CONTRIBUTING.md).
- [ ] If this is user-facing, `CHANGELOG.md`'s `## [Unreleased]` has a
      new entry under the right heading — `release.yml` refuses to cut
      a release with an empty one.
- [ ] `tests/check-*.sh` pass locally, if this module has any, and a
      new/updated suite exists if behaviour changed.
- [ ] `find shell hooks -name '*.sh' -exec shellcheck {} +` is clean.
- [ ] Everything under `shell/`, `hooks/`, `tests/` stays Bash 3.2
      compatible — see [`CONTRIBUTING.md`](../CONTRIBUTING.md#bash-32-compatibility).
- [ ] If this touches repo structure, the manifest schema, or the sync
      engine, `workbench-core`'s
      [`docs/decisions-log.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/decisions-log.md)
      has been checked for an existing decision.
- [ ] `README.md` updated if behaviour changed.

## How was this tested?

<!-- Manual steps, or "covered by tests/check-whatever.sh" -->
````

### `.github/ISSUE_TEMPLATE/bug_report.yml`

Adapted from core's own version: reports both this module's version
and (optionally) core's, since a module bug can stem from either side
of the sync boundary.

````yaml
name: Bug report
description: Report unexpected behaviour in workbench-<module>
title: "[Bug]: "
labels: ["bug"]
body:
  - type: markdown
    attributes:
      value: |
        Thanks for taking the time to report this. If this looks like an
        install/sync issue rather than something specific to this module,
        workbench-core's [troubleshooting guide](https://github.com/GingerGraham/workbench-core/blob/main/docs/troubleshooting.md)
        is worth a quick check first.
  - type: input
    id: module-version
    attributes:
      label: workbench-<module> version
      description: Output of `wb module info <module>`
    validations:
      required: true
  - type: input
    id: core-version
    attributes:
      label: workbench-core version
      description: Output of `wb version`
    validations:
      required: false
  - type: dropdown
    id: os-family
    attributes:
      label: Operating system
      description: The OS you ran it on. For WSL2 or a container, pick the distro running inside it.
      options:
        - Fedora / RHEL family (Fedora, RHEL, CentOS Stream, Rocky, Alma)
        - Debian / Ubuntu family (Debian, Ubuntu, Linux Mint, Pop!_OS)
        - Arch family (Arch, Manjaro, EndeavourOS, CachyOS)
        - SUSE family (openSUSE Tumbleweed or Leap, SLE)
        - Other Linux
        - macOS
    validations:
      required: true
  - type: input
    id: distro-version
    attributes:
      label: Distribution and version
      description: Exact distro and release, e.g. from `/etc/os-release` (`PRETTY_NAME`) or `sw_vers` on macOS.
      placeholder: "Fedora Linux 43 (Workstation Edition)"
    validations:
      required: false
  - type: dropdown
    id: environment
    attributes:
      label: Environment
      description: Where it was running.
      options:
        - Directly on the OS (physical machine or VM)
        - Container
        - WSL2
      default: 0
    validations:
      required: true
  - type: textarea
    id: what-happened
    attributes:
      label: What happened?
      description: What you expected to happen too, if it's not obvious.
    validations:
      required: true
  - type: textarea
    id: repro
    attributes:
      label: Steps to reproduce
    validations:
      required: false
  - type: textarea
    id: logs
    attributes:
      label: Relevant output
      description: Re-run with `WORKBENCH_DEBUG=true` if you can, and paste the relevant portion. This renders as a code block automatically.
      render: shell
  - type: checkboxes
    id: checks
    attributes:
      label: Checklist
      options:
        - label: I checked workbench-core's troubleshooting guide first, if this looked like an install/sync issue
          required: false
````

### `.github/ISSUE_TEMPLATE/feature_request.yml`

````yaml
name: Feature request
description: Propose new behaviour or a change to existing behaviour
title: "[Feature]: "
labels: ["enhancement"]
body:
  - type: textarea
    id: problem
    attributes:
      label: Problem / motivation
      description: What can't you do today, or what's awkward?
    validations:
      required: true
  - type: textarea
    id: solution
    attributes:
      label: Proposed solution
    validations:
      required: true
  - type: dropdown
    id: area
    attributes:
      label: Area
      options:
        - Aliases / shell functions
        - Installer (install-<tool> functions)
        - Hooks (hooks.post_deploy)
        - Manifest (register/deploy entries)
        - Docs (README)
        - CI / release automation
        - Other
    validations:
      required: true
  - type: textarea
    id: alternatives
    attributes:
      label: Alternatives considered
      description: Optional.
    validations:
      required: false
  - type: checkboxes
    id: checks
    attributes:
      label: Checklist
      options:
        - label: I checked workbench-core's decisions log — this isn't already a settled (or deliberately rejected) decision
          required: true
````

### `.github/ISSUE_TEMPLATE/config.yml`

````yaml
blank_issues_enabled: false
contact_links:
  - name: Troubleshooting guide
    url: https://github.com/GingerGraham/workbench-core/blob/main/docs/troubleshooting.md
    about: Check here before opening an issue — covers prereq, loader, sync, and SSH problems common to every module.
  - name: Architecture & decisions log
    url: https://github.com/GingerGraham/workbench-core/blob/main/docs/decisions-log.md
    about: Check the decisions log before proposing anything that touches repo structure, the manifest schema, or the sync engine — it may already be a settled decision.
````

**Do not add `module_proposal.yml`** — proposing a brand-new
`workbench-*` module belongs on `workbench-core`'s tracker, not an
individual module repo's.

### `.github/CODEOWNERS`

````
# Sole maintainer today — mirrors workbench-core's CODEOWNERS
# (docs/decisions-log.md D31/D33). This file exists so review requests
# are automatic and so a future collaborator's ownership boundaries are
# explicit and file-path-based rather than assumed. No branch ruleset on
# this repo requires Code Owner review yet, for the same reason core
# doesn't (D33) — a single owner can't satisfy a required-reviewer rule
# for their own PR.

* @GingerGraham
````

### `CONTRIBUTING.md`

````markdown
# Contributing to workbench-<module>

This is a `workbench` ecosystem module — it doesn't stand alone. It's
installed into a machine via `workbench-core`'s `wb add <module>`. Full
design rationale lives in `workbench-core`'s
[`docs/architecture.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/architecture.md)
and [`docs/decisions-log.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/decisions-log.md)
— check both before proposing anything that touches this module's
manifest schema or how it integrates with the sync engine.

## Non-negotiables

- **Bash 3.2 compatible** — see [below](#bash-32-compatibility).
- **Destinations are always engine-computed by `workbench-core`** — this
  module's manifest never specifies where its own registered content
  lands. Don't add a `dest`-style field to `register.shell[]` entries.
- **No `git` assumed at runtime** — this module is fetched as an
  immutable tarball snapshot; `git` is a developer-only convenience.
- **No Windows/PowerShell support** — out of scope by design, same as
  `workbench-core`.

## Dev setup

This repo isn't installed standalone. To develop against your own
working branch, from a machine that already has `workbench-core`
installed:

```sh
git clone https://github.com/GingerGraham/workbench-<module>.git
cd workbench-<module>

# if not already registered on this machine:
wb add <module>

# point this module's tracking at your working branch:
wb dev <module>
# — or directly:
wb track <module> --branch <your-branch>
```

`wb dev`/`wb track --branch` fetches a **separate**, independently
synced snapshot of your branch — your own editing clone and
workbench's fetched snapshot are two copies on disk by design, not
drift. See `workbench-core`'s `docs/architecture.md` §9.6.

## Making a change

### Commit messages

Every commit is [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>[!]: <subject>

[optional body]

[BREAKING CHANGE: <description>]
```

- `type` is one of `feat` (minor bump), `fix`/`perf` (patch bump), or
  `refactor`/`docs`/`test`/`chore`/`ci`/`build` (no version effect).
- A `!` right after `type`, or a `BREAKING CHANGE:` footer, forces
  **major** regardless of `type`.
- No `scope` convention here — unlike `workbench-core`, this repo has no
  per-file registered-script version to bump individually, so there's
  nothing for a scope to disambiguate.
- This repo squash-merges PRs, and the **PR title itself** must also
  parse as Conventional Commits — `module-pr-check.yml`'s
  `pr-title-format` job fails the PR otherwise.

### CHANGELOG

Add an entry to `CHANGELOG.md`'s `## [Unreleased]` section, under the
[Keep a Changelog](https://keepachangelog.com/) heading it belongs
under, in the same PR that makes the change. `release.yml` refuses to
cut a release if a real version bump is pending but `[Unreleased]` is
still empty.

### Tests

If this module has a `tests/` suite, run its `check-*.sh` scripts
directly before pushing — `module-ci.yml` runs the same suite on
`ubuntu-latest` and `macos-latest`. Validate the manifest with
`lib/manifest/validate.sh` from a `workbench-core` checkout (or let CI
do it for you).

### Bash 3.2 compatibility

Everything under `shell/`, `hooks/`, `tests/` must run under Bash 3.2:
no associative arrays, no `${var,,}`/`${var^^}`, no `mapfile`. This
mirrors `workbench-core`'s own constraint — see its `CONTRIBUTING.md`
for the full rationale.
````

### `SECURITY.md`

Adapted from core's own version — see this section's preamble for why
the "Supported versions" and "Reporting a vulnerability" content is
near-identical while "Trust boundaries worth knowing about" is scoped
down to what's specific to a module rather than repeating the engine's
own trust boundaries.

````markdown
# Security policy

## Supported versions

Only the latest tagged release (the latest `vX.Y.Z` tag) is supported.
There are no maintained LTS branches.

## Reporting a vulnerability

**Please don't open a public issue for a security problem.** Use
GitHub's private vulnerability reporting instead: go to the
[Security tab](https://github.com/GingerGraham/workbench-<module>/security)
→ "Report a vulnerability". This opens a private advisory only visible
to the maintainer until it's resolved.

This is a solo-maintained project — response is best-effort, not
covered by an SLA, but security reports get triaged ahead of everything
else in the backlog.

## Trust boundaries worth knowing about

This module ships shell content (aliases, functions) and, where
declared, an `install-<tool>` function and a `hooks.post_deploy`
script — but it's `workbench-core`'s sync engine that actually fetches,
places, and sources any of it. The engine-level trust boundaries
(tarball-only production fetch, SSH deploy keys for private/
`branch:`-tracked modules, engine-computed destinations, `..`/
absolute-path rejection) live in `workbench-core`'s own
[`SECURITY.md`](https://github.com/GingerGraham/workbench-core/blob/main/SECURITY.md)
— report anything that breaks those there.

What's specific to this repo:

- **`hooks.post_deploy` only runs if the machine explicitly opted in**
  with `wb add <module> --allow-hooks` — an undeclared or ungated hook
  is silently a no-op. If you find a way for this module's hook to run
  without that flag, report it.
- **This module's registered shell content is confined to its own
  snapshot namespace** — it cannot declare a `dest` and land content
  anywhere else. If you find a manifest shape that escapes that, report
  it.

## Automated PR checks

Every pull request to this repo runs three automated checks before
merge, shipped from `workbench-core` so every module stays on the same
list:

- **Secrets** (gitleaks) — hardcoded credentials, tokens, keys.
- **Malware signatures** (clamav) — known-malicious content via ClamAV's
  signature database.
- **Dangerous shell patterns** — a maintained list of known-bad
  constructs (remote-pipe-to-shell, world-writable permissions, etc).

These run alongside shellcheck and this repo's own structural tests.

## Out of scope

This pipeline only runs against code in `workbench-core` and the eleven
canonical `workbench-*` module repos. It says nothing about modules
obtained from anywhere else — `workbench` has no community module
submission or validation pipeline (deliberately, for now).
````
