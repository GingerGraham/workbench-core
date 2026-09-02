# Release process

How `workbench-core` gets from a merged PR to a tagged release, a bumped
`VERSION`, and a GitHub Release — automatically, on every merge to `main`.
Mechanism lives in `.github/workflows/pr-check.yml`/`release.yml` and
`.github/scripts/release/`; this doc is the human-readable map. See
ARCHITECTURE.md §12 D27/§14 for the decision record.

## The three version concepts (recap)

ARCHITECTURE.md §6.1/D18 has the full detail; the short version, since this
whole pipeline exists to move two of these three automatically:

- **Contract versions** (`CORE_API_VERSION`, `MANIFEST_SCHEMA_VERSION`,
  `STATE_SCHEMA_VERSION`) — unrelated to this pipeline. Bumped by hand,
  rarely, when the actual contract changes.
- **Release version** (`VERSION` at the repo root, `vX.Y.Z` tags) — what
  this pipeline bumps and tags. "The overall product version."
- **Script-local versions** (`_workbench_register_script_version` calls, one
  per operational file) — what this pipeline also bumps, per file, based on
  what actually changed. `wb version` shows the full list.

## Writing a commit that should bump something

Every commit that should influence a version bump follows Conventional
Commits:

```
<type>[(<scope>)][!]: <subject>

[optional body]

[BREAKING CHANGE: <description>]
```

- `type` is one of `feat` (minor), `fix`/`perf` (patch), or
  `refactor`/`docs`/`test`/`chore`/`ci`/`build` (no version effect —
  informational only).
- A `!` right after `type`/`scope`, or a `BREAKING CHANGE:` footer, forces
  **major** regardless of `type`.
- `scope`, if you give one, is either:
  - the exact repo-relative path of the one file this commit's bump
    applies to (`fix(lib/core/semver.sh): ...`) — use this when a commit
    touches several files but should only bump the one that actually
    changed behaviour (a comment-only edit to another file, say), or
  - the literal `core` (`feat(core): ...`) — see below.
- No `scope` at all → auto-detected: every registered file this commit's
  diff actually touches gets this commit's severity. This is the common
  case; reach for an explicit scope only when auto-detection would bump
  the wrong thing.
- A commit that touches a registered file but whose `type` doesn't parse
  fails `pr-check.yml` at PR time — fix it with `git commit --amend` or an
  interactive rebase before merging. If one somehow gets through anyway
  (an admin merge, say), `release.yml` logs a visible warning and simply
  doesn't count that commit toward any bump — it never blocks the release.

### `core`-scoped commits: when to reach for one

`core` doesn't map to any file — it's a way to say "this merge is a
product-level decision, independent of which files happened to change."
Its severity feeds directly into the overall `VERSION` bump, on top of
whatever the per-file rollup already produces. Reach for it when the
*decision* is the release-worthy thing, not any one file's content — e.g.
declaring a new supported platform, a policy change that touches many
files equally, or a milestone that doesn't correspond to a single
component's behaviour change. For anything that's really about one file's
(or one component's) behaviour, use auto-detection or an explicit path
scope instead — `core` is the exception, not the default.

## What happens on merge

On every push to `main` (i.e. every merge), `release.yml`:

1. Runs `ci.yml` (lint + the full test suite) as a required first job —
   this is the release's safety net; a red `ci` run blocks the release
   outright, and this workflow never runs its own separate test pass.
2. Walks every commit since the last `vX.Y.Z` tag, computing the highest
   severity that applies to each registered file and to the `core` scope.
3. If nothing qualifies (severity `none` everywhere — a docs/chore-only
   merge, say), the workflow exits cleanly: no bump, no tag, no commit.
4. Otherwise: bumps each qualifying file's script-local version, bumps the
   overall `VERSION`, renames `CHANGELOG.md`'s `## [Unreleased]` heading to
   `## [<version>] - <date>` and inserts a fresh empty `## [Unreleased]`
   above it, commits all of that as `github-actions[bot]`
   (`chore(release): v<version>`), tags it, and publishes a GitHub Release
   whose body lists every bumped file's old → new version and links back
   to `CHANGELOG.md` for the prose detail.

The bot's own release commit is guarded against re-triggering this same
workflow — it only ever runs when a human (or anything other than
`github-actions[bot]`) is the one who pushed to `main`.

## The CHANGELOG discipline

Nothing here writes changelog prose for you — it only renames the heading.
Keep filling in `## [Unreleased]` under the headings Keep a Changelog uses
(`### Added`, `### Fixed`, etc.) exactly as you do today, as part of the
same PR that makes the change. If a merge would produce a real version
bump but `[Unreleased]` is still empty, the release fails loudly, before
touching anything — that emptiness is the signal that someone forgot to
write the changelog entry, not something the pipeline can paper over.

## If a release fails

- **`ci` job red**: this is a real problem with the code on `main`, not the
  release pipeline — fix it the same way you'd fix any other CI failure,
  then push again. No bump, tag, or commit happens until it's green.
- **CHANGELOG gate fails**: add the missing `[Unreleased]` entry in a
  follow-up commit/PR to `main`; the next merge picks up the same pending
  bump (nothing was lost — the commit range still reaches back to the last
  tag).
- **`compute-bumps.sh`/`apply-bumps.sh` fails for another reason**: check
  the job log — both scripts log exactly what they were doing (`path: old
  -> new`) before failing, and the sanity assertion (new version must
  compare greater than old, via `lib/core/semver.sh`'s `_wb_semver_cmp`)
  is deliberately loud rather than silently skipping a file.
- Nothing here ever partially applies: `apply-bumps.sh` checks the
  CHANGELOG gate before writing anything, and a failed run leaves no
  partial commit on `main`.
