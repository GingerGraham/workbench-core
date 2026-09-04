# workbench-core

`workbench-core` is the engine behind `workbench` — a modular,
multi-repo replacement for a single monolithic `dotfiles` checkout. It
provides a shell configuration loader, a small platform-detection/
utility API, and a generalised module registration & distribution
engine, all driven by one CLI: `wb`.

Core is **"module zero"**: it syncs and converges itself through the
exact same engine any other `workbench-*` module or independent tracked
tool will use. There's no special-cased core path and no hardcoded
profile logic — a named **bundle** (e.g. `--bundle workstation`) is just
shorthand for a sequence of `wb add` calls, not a branch inside the
engine itself. A separate TUI repo, `workbench`, will eventually front
`wb` (Wave D) — it isn't this repo, and won't own a second copy of
anything `wb` already knows.

## What it ships

- **A multi-root shell configuration loader** — bash + zsh, bash 3.2
  compatible (macOS's default). Sources every registered, sync-enabled
  module's declared shell content in a fixed tier order
  (`env → core → tools → platform → distro → lazy`).
- **The Core API** — elevation helpers (`elevate-cmd`, `sudo-test`),
  distro/OS/WSL/shell/arch detection (`WORKBENCH_OS`, `WORKBENCH_DISTRO`,
  `WORKBENCH_ARCH`, ...), `PATH` deduplication, and the
  getter-introspection pattern (`get-<domain>-functions`) modules build
  their own discovery commands on top of. Full reference:
  [`contracts/core-api.md`](contracts/core-api.md).
- **A generalised sync/distribution engine.** Public repos are fetched
  as immutable, atomically-swapped tarball snapshots — no `git` on that
  path at all. Private repos and `branch:`-tracked development checkouts
  use a one-shot shallow-clone-and-discard instead. Four tracking states
  (`latest` / `branch:<name>` / `tag:<name>` / `commit:<sha>`) and a
  single shared sync timer with dynamic cadence (drops from weekly to
  every 5 minutes while anything is `branch:`-tracked). Full reference:
  [`contracts/tracking-spec.md`](contracts/tracking-spec.md).
- **`register:`** — lets a manifest-driven module register shell
  functions, aliases, and installers without ever specifying its own
  destination path; the engine computes that, confined to the module's
  own namespace. Full reference:
  [`contracts/manifest-spec.md`](contracts/manifest-spec.md).
- **The `wb` CLI** — `install`/`apply`/`add`/`remove`/`track`/`dev`/
  `sync`/`update`/`status`/`functions`/`tools`/`version`/`help`. See
  [Everyday use](#everyday-use) below, or run `wb help` for the live,
  grouped reference.

## Status

Wave B — core itself, including a baseline-completion pass (self-
convergence on `core` updates, the `wb tools` tool-updating framework,
per-command `wb help`, the `~/.config/workbench/local/` overrides
directory, the `bootstrap.sh` no-`git` install path) — is functionally
complete. See [`CHANGELOG.md`](CHANGELOG.md) for the detailed history.

No release has been tagged yet (`wb version` reports the release version
as `unreleased` until the first tag is cut), and no ecosystem modules
(`workbench-git`, `workbench-gpg`, `workbench-ssh`, `workbench-shell`)
exist yet — those are Wave C. Core is designed and tested to work
correctly standalone, with **zero** non-core modules registered, since
that's the only state that exists until Wave C ships.

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh | bash
```

No `git` required. This resolves the latest release tag (falling back to
`main` if none is cut yet), fetches it as a tarball straight into its
real, permanent snapshot location, and hands off to `wb install` — which
checks and offers to install its own prerequisites, symlinks `wb` onto
`PATH`, adds a loader stub to your shell rc file, and runs the one-time
Ansible convergence pass if `ansible-playbook` is available.

Start a new shell and you're done. See
[`docs/getting-started.md`](docs/getting-started.md) for the full
walkthrough, including the developer setup path (a real `git clone`, for
working on `workbench-core` itself) and what happens without Ansible
installed.

## Everyday use

```sh
wb status                      # what's registered, tracked, and in sync
wb update [<name>]             # fetch + deploy the latest content now
wb add <name> [url]            # register + immediately sync a new module
wb track <name> --tag v1.2.0   # pin what a module tracks
wb dev [<name>]                # guided switch to your own dev branch
wb tools list                  # list install-* functions modules declared
wb functions                   # list registered shell functions/getters
```

Every command has detailed help via `wb help <command>` or
`wb <command> --help` — including explicit disambiguation for the
commands people mix up most (`update` vs `apply`, `track` vs `dev`,
`sync enable|disable` vs `track`). Run bare `wb` or `wb help` for the
full grouped command summary.

## Requirements

Linux, macOS, or WSL2. Bash 3.2+ or zsh. No Windows/PowerShell support
(by design). `wb install` checks for, and offers to install via your
distro's package manager, its required prerequisites (`awk`, `sed`,
`tr`, `grep`, `column`, `git`, `curl`, `ssh-keyscan`, `ssh-keygen`) —
see [`docs/troubleshooting.md`](docs/troubleshooting.md) if one can't be
installed automatically.

## Repository layout

- `bin/wb` — the CLI dispatcher.
- `lib/` — the shell library: Core API, loader, manifest parsing, the
  distribution/sync engine, versioning, prerequisite checks, module
  (de)registration commands.
- `ansible/` — the one-time/occasional convergence path (`wb install`/
  `wb apply`). Nothing that runs on the sync timer depends on Ansible or
  Python.
- `bootstrap.sh` — the production entry point for a machine that has
  nothing installed yet.
- `contracts/` — the standing interfaces module authors build against.
- `docs/` — user- and module-author-facing how-to documentation.
- `tests/` — plain-bash checks, no framework: numbered checks, a
  `FAIL:`/`OK:` summary line.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) §5 for the full target layout
and the rationale behind it.

## Documentation map

| Document | For |
|---|---|
| [`docs/getting-started.md`](docs/getting-started.md) | Installing, adding modules, everyday commands, personal overrides. |
| [`docs/module-authoring.md`](docs/module-authoring.md) | Writing a `.dotfiles-sync.yml` for a new module or tracked tool. |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Diagnosing prereq, loader, sync, and SSH issues. |
| [`docs/release-process.md`](docs/release-process.md) | How merges to `main` become version bumps, tags, and GitHub Releases — Conventional Commit scoping, the `core` scope, and the CHANGELOG discipline. |
| [`contracts/manifest-spec.md`](contracts/manifest-spec.md) | The authoritative `.dotfiles-sync.yml` field reference. |
| [`contracts/core-api.md`](contracts/core-api.md) | The shell functions/variables every module can rely on, and the loader-tier order. |
| [`contracts/tracking-spec.md`](contracts/tracking-spec.md) | How a module's tracked ref is resolved, fetched, and re-checked. |
| [`contracts/state-schema.md`](contracts/state-schema.md) | The on-disk file/directory shapes `wb` reads and writes. |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | The full design rationale, repo topology, rollout plan, and decisions log (§12) — read this before proposing anything that touches repo structure, the manifest schema, or the sync engine. |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | How to propose a change — dev setup, commit/CHANGELOG discipline, the PR checklist. |
| [`SECURITY.md`](SECURITY.md) | How to report a vulnerability, and the trust boundaries this project actually has. |
| [`CHANGELOG.md`](CHANGELOG.md) | What's shipped, in order. |

## Design principles

A few of the load-bearing decisions, in brief (full rationale in
[`ARCHITECTURE.md`](ARCHITECTURE.md)):

- **One generalised engine.** Core is module zero, not a special case;
  bundles are sugar over `wb add`, never a hardcoded branch inside the
  sync engine.
- **Engine-computed destinations.** A module never specifies where its
  own registered shell content lands — `register:` exists precisely so
  the engine, not the module author, controls that.
- **No persistent working trees.** Production tracking never leaves an
  incrementally-`git pull`-ed checkout on disk, for any module, under
  any tracking mode.
- **Additive manifest evolution.** `.dotfiles-sync.yml version: 1` stays
  backward-compatible; a genuine break requires `version: 2`, not a new
  filename.
