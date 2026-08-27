# workbench-core

The engine repo behind `workbench` — a modular, multi-repo replacement for a
monolithic dotfiles checkout. `workbench-core` ships:

- A multi-root shell configuration loader (bash + zsh, bash 3.2 compatible).
- The Core API: elevation helpers, distro/OS/WSL/shell/arch detection, the
  getter-introspection pattern, prompt helpers.
- A generalised module registration & distribution engine — core syncs
  itself ("module zero") through the exact same mechanism any other module
  uses. No `git` on the default/production path for public repos; content
  is fetched as an immutable, atomically-swapped snapshot.
- A four-state tracking model (`latest` / `branch:<name>` / `tag:<name>` /
  `commit:<sha>`) and a single shared sync timer with dynamic cadence.
- The `wb` CLI: `install`, `apply`, `add`, `remove`, `track`, `dev`, `sync`,
  `update`, `status`, `functions`.

This is **Wave B** of the `workbench` decomposition — see `ARCHITECTURE.md`
(the authoritative design reference; copied here from `workbench-precursor`)
for the full plan, and `docs/` / `contracts/` for user- and module-author
facing documentation.

## Status

First-pass build. No ecosystem modules (`workbench-git`, `workbench-gpg`,
`workbench-ssh`, `workbench-shell`) exist yet — those are Wave C. Core is
designed and tested to work correctly standalone, with **zero** non-core
modules registered, since that's the only state that exists until Wave C
ships.

## Quick start

```sh
git clone https://github.com/GingerGraham/workbench-core.git
cd workbench-core
./bin/wb install
```

See `docs/getting-started.md` for the full walkthrough, and
`docs/module-authoring.md` if you're building a module or independent
tracked tool that hooks into the sync engine.

## Repository layout

See `ARCHITECTURE.md` §5 for the full target layout and rationale. In brief:

- `bin/wb` — the CLI dispatcher.
- `lib/` — the shell library: Core API, loader, manifest parsing, the
  distribution/sync engine, module (de)registration commands.
- `ansible/` — the one-time/occasional convergence path (`wb install`/
  `wb apply`). Nothing that runs on a timer depends on Ansible or Python.
- `contracts/` — the standing interfaces module authors build against.
- `tests/` — plain-bash checks, no test framework: numbered checks, a
  `FAIL:`/`OK:` summary line.
- `docs/` — user- and module-author-facing documentation.

## Requirements

Linux, macOS, or WSL2. Bash 3.2+ or zsh. No Windows/PowerShell support (by
design — see `ARCHITECTURE.md` D4). `wb install` checks and installs its own
prerequisites; see `docs/getting-started.md`.
