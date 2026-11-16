# Workbench Core

`workbench-core` is the core library of the Workbench ecosystem.

## What is Workbench?

Workbench is a modular platform designed to streamline the setup and ongoing administration
of Unix-like operating systems including Linux and macOS. Workbench was conceived by [Graham Watts](https://github.com/GingerGraham)
to address the twin, but related, challenges of managing "dotfiles" and custom shell functions and aliases across
multiple systems. Both of these challenges are common pain points for users who work across multiple systems or
frequently distro-hop. Workbench is composed of a core engine (this repo) which delivers the fundamental functionality,
and a set of optional modules that extend its capabilities. Workbench provides a set of opinionated modules covering a
range of common developer and system administrator tasks; however users are free to create and integrate their own
custom modules with whatever functionality they require.

See [ShellTools](https://shelltools.pro/products/shell-scripting/workbench/) for more information on Workbench and
the range of available modules.

A [template module](https://github.com/GingerGraham/workbench-template) is available to help developers create their
own custom modules for Workbench.

## What does `workbench-core` provide?

Core is **"module zero"**: it syncs and converges itself through the
exact same engine any other `workbench-*` module or independent tracked
tool will use. There's no special-cased core path and no hardcoded
profile logic — a named **bundle** (e.g. `--bundle workstation`) is just
shorthand for a sequence of `wb add` calls, not a branch inside the
engine itself. A separate TUI repo, `workbench`, is planned as a front
end for `wb` — it isn't this repo, and won't own a second copy of
anything `wb` already knows.

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
  `sync`/`update`/`status`/`functions`/`tools`/`module`/`version`/
  `completion`/`help`. See
  [Everyday use](#everyday-use) below, or run `wb help` for the live,
  grouped reference.

## Modules and bundles

Install a bundle at bootstrap, or `wb add <name>` any module later. Each
module works with only core installed.

| Module | What it adds |
|---|---|
| [`git`](https://github.com/GingerGraham/workbench-git) | Git identity, multi-context project management, and CLI-wiring helpers |
| [`gpg`](https://github.com/GingerGraham/workbench-gpg) | GPG day-to-day and key-lifecycle management |
| [`ssh`](https://github.com/GingerGraham/workbench-ssh) | Hardened SSH client config, agent routing, and pinned forge host keys |
| [`shell`](https://github.com/GingerGraham/workbench-shell) | Shell, editor and prompt layer: aliases, direnv, fzf, and the omp/starship/omz prompt engines |
| [`cloud`](https://github.com/GingerGraham/workbench-cloud) | AWS/Azure/GCP CLI aliases and installers |
| [`iac`](https://github.com/GingerGraham/workbench-iac) | Terraform/OpenTofu/Terragrunt/Ansible aliases and installers |
| [`containers`](https://github.com/GingerGraham/workbench-containers) | Docker/Podman/Kubernetes aliases and installers |
| [`security`](https://github.com/GingerGraham/workbench-security) | Security scanners, signing tooling, password manager CLIs/apps, and LUKS2+TPM2 disk encryption management |
| [`ai`](https://github.com/GingerGraham/workbench-ai) | Installers for AI CLIs (Claude Code, GitHub Copilot CLI, Antigravity, Specify/spec-kit) |
| [`desktop`](https://github.com/GingerGraham/workbench-desktop) | GUI desktop app installers and Flatpak |
| [`devtools`](https://github.com/GingerGraham/workbench-devtools) | Go/Python/Node dev environment wiring, plus nvm/Edit/jq/uv/snapd installers |

| Bundle | Modules |
|---|---|
| `workstation` | git, gpg, ssh, shell |
| `server` | git, ssh, shell |
| `minimal` | git, ssh |
| `full` | every module above |

## Quick start

Most new machines want a bundle: core plus a planned set of modules.
`workstation` is git, gpg, ssh and shell:

```sh
curl -fsSL https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh | bash -s -- --bundle workstation
```

Swap `workstation` for any bundle in the [table above](#modules-and-bundles).
`bash -s --` passes what follows it to the script instead of to `bash`.

Core on its own, adding modules later with `wb add <name>...`:

```sh
curl -fsSL https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh | bash
```

Already have core installed? `wb install --bundle workstation` adds a
bundle at any time.

No `git` required. Bootstrap resolves the latest release tag, fetches it
as a tarball straight into its permanent snapshot location, and hands off
to `wb install`. `wb install` checks for its prerequisites and offers to
install them, symlinks `wb` onto `PATH`, adds a loader stub to your shell
rc file and, with `--bundle`, registers that bundle's modules.

If a module would touch config you already have (a `~/.gitconfig`, a
`tmux.conf`), you're asked first, and pressing Enter keeps yours. On a
fresh machine nothing is asked. See
[Install](docs/guide/getting-started.md#install) for the choices, including the
scripted `--use-files --yes` form.

When it finishes, open a new terminal, or run the `source` line it prints
to load workbench into the current one. After that, `wb` commands that
change what's installed reload the shell they ran in.

See [Getting started](docs/guide/getting-started.md) for the full
walkthrough, including how to keep your own set of modules. Working on
`workbench-core` itself? See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Everyday use

```sh
wb status                      # what's registered, tracked, and in sync
wb update [<name>]             # fetch + deploy the latest content now
wb add <name>...               # register + immediately sync catalog modules
wb track <name> --tag v1.2.0   # pin what a module tracks
wb dev [<name>]                # guided switch to your own dev branch
wb tools list                  # list install-* functions modules declared
wb tools install <name>...     # install the named tools in one run
wb functions [<filter>...]     # list registered shell functions/getters
```

Every command has detailed help via `wb help <command>` or
`wb <command> --help` — including explicit disambiguation for the
commands people mix up most (`update` vs `apply`, `track` vs `dev`,
`sync enable|disable` vs `track`). Run bare `wb` or `wb help` for the
full grouped command summary. The [command reference](docs/guide/commands.md)
lists every command with examples.

## Requirements

Linux, macOS, or WSL2. Bash 3.2+ or zsh. No Windows/PowerShell support
(by design). `wb install` checks for, and offers to install via your
distro's package manager, its required prerequisites (`awk`, `sed`,
`tr`, `grep`, `column`, `git`, `curl`, `ssh-keyscan`, `ssh-keygen`) —
see [Troubleshooting](docs/guide/troubleshooting.md) if one can't be
installed automatically.

## Repository layout

- `bin/wb` — the CLI dispatcher.
- `lib/` — the shell library: Core API, loader, manifest parsing, the
  distribution/sync engine, versioning, prerequisite checks, module
  (de)registration commands.
- `bootstrap.sh` — the production entry point for a machine that has
  nothing installed yet.
- `contracts/` — the standing interfaces module authors build against.
- `docs/guide/` — the user guide: installing and using workbench.
- `docs/` — design, decisions, module authoring and release documentation.
- `tests/` — plain-bash checks, no framework: numbered checks, a
  `FAIL:`/`OK:` summary line.

See [`docs/architecture.md`](docs/architecture.md) §5 for the full target layout
and the rationale behind it.

## Documentation map

Using workbench:

| Document | For |
|---|---|
| [Getting started](docs/guide/getting-started.md) | Installing, adding modules, and your own settings. |
| [Command reference](docs/guide/commands.md) | Every `wb` command, with examples. |
| [Your config files](docs/guide/config-files.md) | How modules treat config you already have, and how to change your mind. |
| [Updating, pausing and removing modules](docs/guide/managing-modules.md) | Background updates, pinning and reverting versions, removing modules, uninstalling. |
| [Existing shell setups](docs/guide/existing-setups.md) | What workbench leaves alone on a machine with its own shell profile. |
| [Troubleshooting](docs/guide/troubleshooting.md) | When something isn't working. |
| [Module authoring guide](docs/guide/module-authoring.md) | Writing your own module: the manifest, shell content, installers, and testing. |
| [`SECURITY.md`](SECURITY.md) | How to report a vulnerability, and the trust boundaries this project actually has. |
| [`CHANGELOG.md`](CHANGELOG.md) | What's shipped, in order. |

Working on workbench, or writing a module:

| Document | For |
|---|---|
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | How to propose a change — dev setup, commit/CHANGELOG discipline, the PR checklist, and the documentation rules. |
| [`docs/module-repo-standards.md`](docs/module-repo-standards.md) | The agent-instruction, governance, CI and release files every `workbench-*` module repo carries. |
| [`contracts/manifest-spec.md`](contracts/manifest-spec.md) | The authoritative manifest (`workbench.yml`, or legacy `.dotfiles-sync.yml`) field reference. |
| [`contracts/core-api.md`](contracts/core-api.md) | The shell functions/variables every module can rely on, and the loader-tier order. |
| [`contracts/tracking-spec.md`](contracts/tracking-spec.md) | How a module's tracked ref is resolved, fetched, and re-checked. |
| [`contracts/state-schema.md`](contracts/state-schema.md) | The on-disk file/directory shapes `wb` reads and writes. |
| [`docs/architecture.md`](docs/architecture.md) | The full design rationale, repo topology, and rollout plan — read this before proposing anything that touches repo structure, the manifest schema, or the sync engine. |
| [`docs/decisions-log.md`](docs/decisions-log.md) | The full, numbered decisions log referenced from `docs/architecture.md` §12. |
| [`docs/release-process.md`](docs/release-process.md) | How merges to `main` become version bumps, tags, and GitHub Releases — Conventional Commit scoping, the `core` scope, and the CHANGELOG discipline. |

## Design principles

A few of the load-bearing decisions, in brief (full rationale in
[`docs/architecture.md`](docs/architecture.md)):

- **One generalised engine.** Core is module zero, not a special case;
  bundles are sugar over `wb add`, never a hardcoded branch inside the
  sync engine.
- **Engine-computed destinations.** A module never specifies where its
  own registered shell content lands — `register:` exists precisely so
  the engine, not the module author, controls that.
- **No persistent working trees.** Production tracking never leaves an
  incrementally-`git pull`-ed checkout on disk, for any module, under
  any tracking mode.
- **Additive manifest evolution.** `.dotfiles-sync.yml version: 1` is
  permanent, unchanged, zero behavioural difference. `version: 2` —
  `workbench.yml`/`workbench.yaml`/`wb.yml`/`wb.yaml` — is the same,
  already-additive field set under a workbench-focused name; new or
  migrating repos should prefer it (`docs/decisions-log.md` D46).
