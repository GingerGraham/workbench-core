# Copilot instructions — workbench-core

Mirrors `AGENTS.md` at the repo root. Copilot's various surfaces (CLI,
coding agent, Chat, code review) don't uniformly discover a root
`AGENTS.md`, so this is a deliberate, maintained duplicate — see
`ARCHITECTURE.md` §12 D32. If the two ever disagree, `AGENTS.md` is the
one that's current; update this file to match rather than treating the
drift as acceptable.

## Read first

- [`ARCHITECTURE.md`](../ARCHITECTURE.md) — full design rationale, repo
  topology, and the §12 decisions log. Read this, and specifically
  check §12, before proposing or making anything that touches repo
  structure, the manifest schema, or the sync engine. Log a new
  decision there (never rewrite an existing one) rather than letting an
  implementation drift from what's documented.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — dev setup, commit/CHANGELOG
  discipline, the PR checklist.
- [`docs/release-process.md`](../docs/release-process.md) — the exact
  Conventional Commit grammar and scoping rules this repo's CI
  enforces.
- [`docs/module-authoring.md`](../docs/module-authoring.md) — the
  manifest contract, for anything touching `register:`, `deploy:`, or
  `hooks:`.

## Non-negotiables

These hold regardless of how a request is phrased — flag back rather
than silently reinterpreting one of these away:

- **Bash 3.2 compatible**: everything under `bin/`, `lib/`,
  `bootstrap.sh`, `tests/`. No associative arrays, no
  `${var,,}`/`${var^^}`, no `mapfile`. `.github/scripts/**` is the sole
  exception (GitHub-hosted-runner-only, Bash 4+ allowed — see its own
  header comments).
- **No `git` in the production distribution path.** Tarball-fetch via
  the GitHub API only. `git` is reserved for this repo's own developer
  checkout and for private-repo/`branch:`-tracked modules.
- **Destinations for module-authored content are always
  engine-computed**, never left to the module author to specify — this
  is a trust-boundary property, not a style preference
  (`ARCHITECTURE.md` principle 1).
- **One generalised sync/install engine.** Core is "module zero," not a
  special case; a new bundle or capability is sugar over the engine,
  never a hardcoded branch inside it.
- **Manifest changes stay additive** — `.dotfiles-sync.yml version: 1`
  stays backward-compatible unless `ARCHITECTURE.md` §5.4's bar for a
  genuine break is met, in which case it's `version: 2`, not a silently
  reinterpreted field.
- **`dotfiles` (the original monolith) is frozen at `v1.10.0`** — no
  feature work or refactors there; it auto-deploys unattended via a
  live timer on a real machine. `workbench-precursor` is a
  scratch/donor workspace, archived once its content is extracted —
  never a long-term destination for new work either.
- **No Windows/PowerShell support** — out of scope by design.

## Working conventions

- Conventional Commits on every commit that touches a registered file
  (`bin/`, `lib/`, `bootstrap.sh`) — `pr-check.yml` enforces the
  grammar at PR time. See `docs/release-process.md`.
- A `CHANGELOG.md` `[Unreleased]` entry, in the same change, for
  anything user-facing — `release.yml` gates a real version bump on
  this being non-empty.
- `tests/check-*.sh` (plain bash, numbered `OK:`/`FAIL:` checks, no
  framework) — match this style for new suites rather than introducing
  one. Run locally via `.github/scripts/ci/run-tests.sh`.
- `shellcheck` at full severity, no `.shellcheckrc` — suppress a
  known-safe idiom inline with `# shellcheck disable=` at the site,
  matching the existing annotation convention, rather than relaxing
  severity.
