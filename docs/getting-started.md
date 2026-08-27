# Getting started

## Requirements

Linux, macOS, or WSL2. Bash 3.2+ or zsh. No Windows/PowerShell support.
`wb install` checks for (and offers to install) `awk`, `sed`, `tr`, `grep`,
`column`, `git`, `curl`, `ssh-keyscan`, `ssh-keygen` — everything else it
needs, it installs itself.

## Install

```sh
git clone https://github.com/GingerGraham/workbench-core.git
cd workbench-core
./bin/wb install
```

This will:

1. Check and (with your permission) install missing prerequisites.
2. Write the version taxonomy file (`~/.config/workbench/core/version`).
3. Register core itself as "module zero," pointing its `current` snapshot
   at the checkout you just ran `wb install` from.
4. Add a loader stub to `~/.bashrc` (and `~/.zshrc` if present).
5. Run the Ansible convergence pass (if `ansible-playbook` is available —
   see below if it isn't).
6. Set up SSH deploy keys for any private module you've already registered
   (none, on a fresh install).

Start a new shell (or `source ~/.bashrc`) and you're done. Nothing else is
required — `workbench-core` works standalone, with zero other modules
registered.

### Without Ansible

`wb install` still produces a fully working shell without
`ansible-playbook` on `PATH` — the Ansible step only formalizes host-state
templating for modules declared in `ansible/host_vars/localhost.yml`
(none, by default in Wave B). You'll see a warning, not a failure.

## Adding a module or independent tool

```sh
wb add awsconfd git@github.com:you/awsconfd.git --private
```

`--private` triggers SSH deploy-key generation automatically — follow the
printed instructions to add the shown public key to the repo (Settings →
Deploy keys → Add deploy key → **do not** allow write access).

Once added, `wb status` shows its tracking state, and its `register:`
declarations (if any) are live in your very next new shell.

## Everyday commands

```sh
wb status                          # what's registered, what it's tracking
wb update                          # sync everything now, bypassing cadence
wb update awsconfd                 # sync just one module now
wb track awsconfd --tag v1.2.0     # pin to an exact tag
wb track awsconfd --latest         # back to auto-tracking the newest release
wb dev awsconfd                    # guided switch to your own dev branch
wb sync disable awsconfd           # pause auto-sync without deregistering
wb remove awsconfd                 # deregister (deployed content stays)
wb functions                       # what shell functions/getters are live
```

## Uninstalling a module cleanly

`wb remove <name>` deregisters without touching anything it deployed —
if you also want the deployed files gone, remove them by hand (they're
listed in the module's manifest `deploy:` entries, or check
`~/.local/share/workbench/modules/<name>/`).

## Troubleshooting

See `docs/troubleshooting.md`.
