# Security policy

## Supported versions

Only the latest tagged release (see `VERSION` at the repo root, or the
latest `vX.Y.Z` tag) is supported. There are no maintained LTS branches
— `workbench-core` is a single-maintainer, actively-developed project,
not yet at the point of parallel-maintaining old lines.

## Reporting a vulnerability

**Please don't open a public issue for a security problem.** Use
GitHub's private vulnerability reporting instead: go to the
[Security tab](https://github.com/GingerGraham/workbench-core/security)
→ "Report a vulnerability". This opens a private advisory only visible
to the maintainer until it's resolved. (Requires the repo setting to be
enabled first — see §4 of the brief this file shipped with.)

This is a solo-maintained project — response is best-effort, not
covered by an SLA, but security reports get triaged ahead of everything
else in the backlog.

## Trust boundaries worth knowing about

`workbench-core` sources shell content from GitHub-hosted repos into an
interactive shell, and can elevate privileges via `sudo`/`run0`
(`lib/core/functions.sh`). That's real capability, not incidental —
worth reporting against specifically:

- **Production distribution never uses `git`.** `bootstrap.sh` and the
  sync engine resolve the latest release tag via the GitHub API and
  fetch a tarball — trust is rooted in GitHub's tag/release integrity,
  not an incrementally-mutated working tree.
- **Private-repo/`branch:`-tracked modules use SSH deploy keys**,
  shallow-clone-and-discard rather than a persistent checkout
  (`lib/ssh/bootstrap.sh`).
- **A module's registered shell content is engine-computed, not
  author-specified**, and confined to that module's own snapshot
  namespace (`ARCHITECTURE.md` principle 1, `lib/manifest/validate.sh`'s
  rejection of a `dest` on `register.shell[]` entries) — a module
  cannot declare where its own content lands outside itself.
- **Manifest parsing rejects `..`/absolute paths** in every
  `src`/`dest`-shaped field (`lib/manifest/validate.sh`'s
  `_is_safe_relative_path`).

If you find a way around any of these — a manifest that escapes its own
namespace, a way to get arbitrary content sourced without going through
`register:`, a gap in the no-`git`-in-production guarantee — that's
exactly what this policy wants reported privately first.

## Out of scope

The frozen `dotfiles` repo (`v1.10.0`, no further feature work) isn't
covered by this policy — report issues there against that repo directly
if it's still accepting them.
