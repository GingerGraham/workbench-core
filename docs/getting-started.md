# Getting started

## Requirements

Linux, macOS, or WSL2. Bash 3.2+ or zsh. No Windows/PowerShell support.
`wb install` checks for (and offers to install) `awk`, `sed`, `tr`, `grep`,
`column`, `git`, `curl`, `ssh-keyscan`, `ssh-keygen` — everything else it
needs, it installs itself.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh | bash
```

This is the production path — no `git` involved anywhere. `bootstrap.sh`
is deliberately tiny (it's the one thing that has to work before any of the
real engine code exists locally to run):

1. If core is already bootstrapped, skips straight to re-running
   convergence — safe to run more than once.
2. Checks for `curl` and `tar` (the only prerequisites it needs itself).
3. Resolves the latest `vX.Y.Z` release tag via GitHub's API (falling back
   to `main` with a warning if no release has been tagged yet).
4. Fetches that release as a tarball and extracts it straight into its
   final, permanent location — the same immutable snapshot shape an
   ordinary sync cycle produces later.
5. Writes core's own tracking state (`TRACK_MODE=latest`, the resolved
   commit) and hands off to `bin/wb install`, which then:
   - Checks and (with your permission) installs any remaining missing
     prerequisites.
   - Writes the version taxonomy file (`~/.config/workbench/core/version`).
   - Adds a loader stub to `~/.bashrc` (and `~/.zshrc` if present).
   - Runs the Ansible convergence pass (if `ansible-playbook` is available
     — see below if it isn't).
   - Sets up SSH deploy keys for any private module you've already
     registered (none, on a fresh install).

Start a new shell (or `source ~/.bashrc`) and you're done. Nothing else is
required — `workbench-core` works standalone, with zero other modules
registered.

More cautious about piping straight into `bash`? Download it first and take
a look:

```sh
curl -fsSLO https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh
less bootstrap.sh
bash bootstrap.sh
```

Passing flags through the piped form needs the `-s --` separator, same as
any script run this way:

```sh
curl -fsSL .../bootstrap.sh | bash -s -- --bundle <name>
```

(or skip bundle selection at install time entirely and just `wb add` a
module afterward — see below.)

### Developer setup

Working on `workbench-core` itself? Use a real `git clone` instead — this
is the one case that's meant to track a persistent, incrementally-pulled
checkout, per `ARCHITECTURE.md` §9.6:

```sh
git clone https://github.com/GingerGraham/workbench-core.git
cd workbench-core
./bin/wb install
```

`wb install` detects the `.git` checkout and registers core with
`TRACK_MODE=branch:<your current branch>` instead of `latest` — the same
dev-tracking pathway `wb dev`/`wb track --branch` gives every other module.
See `ARCHITECTURE.md` §9.6 for why your own editing clone and workbench's
own fetched snapshot are expected to be two separate copies on disk, not a
bug.

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

## Personal shell overrides

`wb install`/`wb apply` create `~/.config/workbench/local/settings.sh` for
you (with commented examples) — this one reserved filename is where the
documented switches live (`WORKBENCH_PLAIN_SHELL`, `WORKBENCH_SHOW_FUNCTIONS`,
etc.), and it's sourced twice: once early, so a flag you set there gates
everything else that loads afterward, and again at the very end, so it
wins over anything a module also touched.

Want your own functions or aliases, entirely separate from that switches
file? Drop any number of other `*.sh` files into the same
`~/.config/workbench/local/` directory — they're sourced once, together,
in filename order, right after `settings.sh`'s final pass, and are live in
your very next new shell. No naming convention required beyond `.sh`, and
nothing here is validated the way a module's manifest is — keep it simple
and flat.

(This is separate from `~/.config/workbench/user/*.sh`, which is for
hand-authored "pseudo-module" extensions rather than personal overrides —
see `contracts/state-schema.md` if you need the distinction.)

## Uninstalling a module cleanly

`wb remove <name>` deregisters without touching anything it deployed —
if you also want the deployed files gone, remove them by hand (they're
listed in the module's manifest `deploy:` entries, or check
`~/.local/share/workbench/modules/<name>/`).

## Troubleshooting

See `docs/troubleshooting.md`.
