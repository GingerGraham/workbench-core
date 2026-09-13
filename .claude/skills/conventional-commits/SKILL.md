---
name: conventional-commits
description: Use before writing any commit message or PR title in workbench-core. Determines whether to omit the scope, name a specific registered file, or use 'core', and what type maps to what version-bump severity. Also covers PR title requirements, since this repo squash-merges.
---

# Conventional Commits & PR titles — workbench-core

This repo's release pipeline (`release.yml`, `.github/scripts/release/`)
parses every commit and PR title as a Conventional Commit and uses
`type`/`scope` to decide what gets a version bump. Getting the scope wrong
doesn't just skip a bump loudly — it can drop it *silently*. Get this right
before you write the message, not after.

## Decision procedure

1. **Does this commit implement a change with clear file/behaviour-level
   ownership?**
   - Yes, and it touches exactly the files that own that behaviour →
     **omit `scope`**. Auto-detection bumps every registered file
     (`bin/wb`, `lib/**/*.sh`, `bootstrap.sh`) the diff actually touches,
     each at this commit's severity. This is the default — reach for an
     explicit scope only when auto-detection would bump something it
     shouldn't.
   - Yes, but the diff also touches an unrelated file for incidental
     reasons (a comment fix elsewhere, say) → scope explicitly to the one
     file that should bump: `fix(lib/core/semver.sh): ...`. The named
     file's exact repo-relative path is the only valid non-`core` scope.
2. **Is this a product-level decision with no single owning file** — a new
   supported platform, a policy that touches many files equally, a
   milestone that isn't one component's behaviour change? → `scope: core`.
   **Before using it, confirm this commit's diff touches zero registered
   files.** If it touches even one, `core` is wrong — see the failure mode
   below.
3. **Unsure?** Omit the scope. Auto-detection is always safe; an explicit
   scope is never required for a bump to happen.

## The failure mode this exists to prevent (real incident: PR #58/#59, docs/decisions-log.md D55)

```
feat(core): backup-before-overwrite for force copy/link deploys
```

This commit touched `bin/wb` and `lib/sync/engine.sh` — both registered
files. Because the scope said `core`, `compute-bumps.sh` never looked at
what the commit touched: the overall `VERSION` bumped, but `bin/wb` and
`lib/sync/engine.sh` silently kept their old script-local versions. No
warning, no failed check — at the time, nothing caught it.

**This is now enforced at PR time** (`pr-check.yml`, D55): a commit or PR
title scoped `core` that also touches a registered file fails the check
outright. If you see that failure, the fix is either:
- drop the scope entirely, or
- scope explicitly to the specific registered file(s) the commit actually
  changed.

## Type → severity

| `type` | Severity | Notes |
|---|---|---|
| `feat` | minor | |
| `fix`, `perf` | patch | |
| `refactor`, `docs`, `test`, `chore`, `ci`, `build` | none | informational only, no version effect |
| any type + `!` after type/scope, or a `BREAKING CHANGE:` footer | major | overrides the type's own severity |

## PR titles matter as much as commit messages

This repo squash-merges every PR. GitHub's squash commit message is the PR
*title*, not any individual commit's message — so the title needs the same
`type[(scope)][!]: subject` grammar, and the same `core`-vs-registered-file
rule above applies to it, checked against the PR's overall diff. A
perfectly-formatted commit inside a badly-titled PR still lands on `main`
unparseable (docs/decisions-log.md D47).

## Before opening the PR

- [ ] Every commit touching `bin/`, `lib/`, or `bootstrap.sh` follows
      `type[(scope)][!]: subject`.
- [ ] If any commit is scoped to a specific file, that file is a real
      registered file and is actually the one that changed.
- [ ] If any commit is scoped `core`, confirm it touches **no** registered
      file — if it does, rescope it.
- [ ] The PR title itself is a valid Conventional Commit header, and if
      scoped `core`, the same no-registered-file check applies to the
      whole PR's diff.
- [ ] `CHANGELOG.md`'s `[Unreleased]` section has an entry for anything
      user-facing — `release.yml` refuses to cut a release with an empty
      one.

Full rationale and the release pipeline's mechanics:
`docs/release-process.md`. Decision history: `docs/decisions-log.md` (D27,
D42, D47, D55).
