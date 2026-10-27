# Getting started

## Requirements

Linux, macOS, or WSL2. Bash 3.2+ or zsh. No Windows/PowerShell support.
`wb install` checks for (and offers to install) `awk`, `sed`, `tr`, `grep`,
`column`, `git`, `curl`, `ssh-keyscan`, `ssh-keygen` — everything else it
needs, it installs itself.

## Install

Two ways in, depending on what you want from workbench:

- **A new machine, or "just give me workbench's setup".** Run bootstrap
  with a bundle:

  ```sh
  curl -fsSL https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh | bash -s -- --bundle workstation
  ```

  On a fresh machine there's nothing of yours to ask about, so nothing is
  asked. On a machine that already has config (a `~/.gitconfig`, a
  tmux.conf), you're shown which files would be touched — answer `u` to
  use workbench's, or add `--use-files --yes` to script it. Your files are
  backed up first; your git identity and ssh hosts are carried into the
  new files.

  The README's [Modules and bundles](../README.md#modules-and-bundles)
  table lists every module and what each bundle installs.
- **"I like my config, I want your tooling."** Run bootstrap, or `wb add
  <module>` later, and press Enter at the question (keep mine), or add
  `--keep-files`. What keep means:
  - git, ssh, tmux and vim config: your file stays as it is, and the module
    adds one marked block your own settings override (see "Workbench
    blocks in your own config files" below).
  - Whole files (a starship.toml): yours is left alone, and the module's
    isn't used.
  - Changed your mind about one file later? `wb files use <module> <file>`
    switches it; `wb files restore` switches it back.

At the question, `c` chooses per file (keep, use, or skip — leave it
completely alone), `d` shows each file of yours against workbench's, and
`q` quits with nothing changed: the module stays registered and the next
`wb update` asks again. Without a terminal — cloud-init, CI, the
scheduled sync — the answer is always keep; workbench never replaces a
file unasked.

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
   - Adds a loader stub to `~/.bashrc` (and `~/.zshrc`/`~/.zshenv` if
     present) — see "Migrating from an existing shell config" below if
     any of those already had real content. The `~/.zshenv` line loads
     workbench only for non-interactive zsh (`zsh -c`, ssh commands,
     scripts); interactive zsh loads it from `~/.zshrc`.
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
checkout, per `architecture.md` §9.6:

```sh
git clone https://github.com/GingerGraham/workbench-core.git
cd workbench-core
./bin/wb install
```

`wb install` detects the `.git` checkout and registers core with
`TRACK_MODE=branch:<your current branch>` instead of `latest` — the same
dev-tracking pathway `wb dev`/`wb track --branch` gives every other module.
See `architecture.md` §9.6 for why your own editing clone and workbench's
own fetched snapshot are expected to be two separate copies on disk, not a
bug.

### Your own module set

A bundle is a named list of modules from the catalog. To keep your own set
— the modules you want on every machine — define a bundle in
`~/.config/workbench/catalog/bundles.list`:

```
# <bundle-name>|<comma-separated module names>
mine|git,ssh,shell,cloud,iac
```

Then a new machine needs one command:

```sh
curl -fsSL .../bootstrap.sh | bash -s -- --bundle mine
```

This file replaces the shipped `bundles.list` rather than adding to it,
so copy any shipped bundle you still want into it (see
`docs/architecture.md` §10).

### Behind a shared IP: `WORKBENCH_GITHUB_TOKEN`

Resolving releases goes through GitHub's API, which allows 60
unauthenticated requests an hour per IP. Behind a shared IP (an office
NAT, a CI runner) that can run out. Set `WORKBENCH_GITHUB_TOKEN` to any
GitHub token (a fine-grained one with read-only access to public
repositories is enough), in the environment you run bootstrap or `wb` from:

```sh
export WORKBENCH_GITHUB_TOKEN=github_pat_...
curl -fsSL .../bootstrap.sh | bash
```

The token is sent only to `api.github.com`, never to the tarball host or
anywhere else, is passed to `curl` on stdin rather than its command line,
and is never written to a file. The scheduled sync doesn't see a variable
exported in your shell.

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
wb tools list                      # what install-* functions are available
wb version                         # release version + every loaded file's version
```

## Scheduled sync

By default, nothing runs in the background — `wb update`/`wb apply` only
happen when you run them. If you'd rather modules stay current on their
own, turn on the host-wide OS timer (a systemd `--user` timer on
Linux/WSL2, a launchd agent on macOS) that polls every 5 minutes and lets
the sync engine decide, in userspace, whether anything is actually due:

```sh
wb scheduler enable     # turn scheduled sync on for this host, right now
wb scheduler status     # is it enabled, and is the OS timer actually active
wb scheduler disable    # turn it off and remove the installed timer/agent
```

This is a separate, host-wide switch from `wb sync enable|disable
[<name>]` — that one controls which *registered modules* a running timer
is allowed to touch; `wb scheduler enable|disable` controls whether the
timer runs at all. Both need to be "on" for a given module to ever sync
in the background. If an older release had already set up scheduled
sync on this host, upgrading to a core release with this built-in timer
preserves that as enabled automatically the first time you
run `wb apply` — you don't need to re-run `wb scheduler enable` yourself
unless you'd rather turn it off.

## Personal shell overrides

`wb install`/`wb apply` create `~/.config/workbench/local/settings.sh` for
you (with commented examples) — this one reserved filename is where the
documented switches live (`WORKBENCH_PLAIN_SHELL`, `WORKBENCH_SHOW_FUNCTIONS`,
etc.), and it's sourced twice: once early, so a flag you set there gates
everything else that loads afterward, and again at the very end, so it
wins over anything a module also touched.

One of those switches, `WORKBENCH_ALLOW_AUR=true`, lets installers use the
Arch User Repository (`yay`/`makepkg`). It is off by default: without it,
an installer that would need the AUR prints the command to run yourself.

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

## Migrating from an existing shell config

`wb install`/`wb apply` never overwrite `.bashrc`/`.zshrc`/`.zshenv` — they
only append a loader stub line, once, the first time each file gets one. If
any of those files already had real content the very first time this ran
(a previous dotfiles setup, a distro default, your own prompt tooling), that
content is left in place but also backed up first, under
`${XDG_DATA_HOME:-~/.local/share}/workbench/backups/`, tagged `rc-stub-*` —
the same backup mechanism `wb module reset` uses. Re-running `wb
install`/`wb apply` afterward never backs the file up again; the marker
already being present is what gates it.

While any `rc-stub`-tagged backup remains under that path, every new
interactive shell prints a warning naming it. To clear the warning: open the
backup, copy anything you want to keep into a new file under
`~/.config/workbench/local/` (any filename ending `.sh`, e.g.
`90-migrated.sh` — see "Personal shell overrides" above), then delete the
backup file. There's no auto-merge — same discipline this project already
applies to `starship.toml`/`direnv.toml`-style opinionated defaults.

Separately: if your rc file already ran its own prompt tool (starship,
oh-my-posh, oh-my-zsh, powerlevel10k) before workbench's stub line, the
loader detects that (via `PROMPT_COMMAND`/`precmd_functions` already being
non-empty when it first runs) and skips its own bare fallback prompt rather
than silently overwriting it.

## Keeping your own config files

Modules ship opinionated defaults — a tmux.conf, a vimrc, a whole nvim config. Workbench never removes or replaces a file it didn't put there, and never throws away a change you made:

- If you already have one, it's left alone. That includes the other places a tool looks — an existing `~/.vim/vimrc` stops workbench creating `~/.vimrc`.
- If you edit one workbench created, it's yours from then on.
- If you delete one, workbench won't put it back.
- If something changes a file workbench links into place (`:Lazy update` rewriting `lazy-lock.json`, say), the next update holds that file where it is and asks you, rather than discarding the change.

When something needs your decision, a new shell says so in one line. `wb files status` shows every file, what's waiting, and what the next update will do; `wb files resolve` asks you:

    keep    — mine from now on, no more updates
    manage  — keep my changes, keep updating everything else
    use     — take the module's version (mine is backed up)

### Workbench blocks in your own config files

For git, ssh, tmux and vim, a module doesn't replace your file. It adds one marked block to it — `~/.gitconfig`, `~/.ssh/config`, your tmux.conf, your vimrc — that includes the module's settings:

```
# >>> workbench git/gitconfig under >>>
# Managed by workbench (wb files status). Put your settings outside this block.
[include]
	path = "/home/you/.local/share/workbench/modules/git/current/files/gitconfig"
# <<< workbench git/gitconfig under <<<
```

Anything you set outside the block wins: the block sits where the tool reads it first (git, tmux, vim) or last (ssh). The module's settings update with the module, with nothing to approve. Keep your own settings outside the block — workbench rewrites what's inside it. Delete the block's two marker lines and it never comes back. `wb files status` lists every block under "Layers".

    wb files policy <module> <layer> skip     # remove the block, stop adding it
    wb add <module> --skip-layer <layer>      # never add it in the first place
    wb files use <module> <layer>             # back up your file, keep only workbench's block
    wb files restore <module> <layer>         # remove the block (and put back what 'use' backed up)

`<layer>` is the tool's name — `gitconfig`, `ssh_config`, `tmux.conf`, `vimrc` — or `<tool>:over` for the few blocks placed to win, such as workbench-git's per-project identities.

## Using a module's versions instead of your own

To switch to a module's version of a file you already have:

    wb files use <module> <file>              # one file
    wb files use <module> all                 # every file the module ships

Your file is moved into the backups folder, along with any other config file the same tool would also read (so `~/.tmux.conf` doesn't keep loading alongside workbench's), and the module's version goes in place. Afterwards it stays current until you edit it. Add `--follow` to keep it tracking the module even after edits — your edits are backed up each time.

To do this for every module at install:

    wb install --bundle workstation --use-files --follow

Want a module but not one of its files?

    wb files policy <module> <file> skip

## Uninstalling a module cleanly

`wb remove <name>` deregisters and leaves its files where they are. `wb remove <name> --restore` first puts back everything it replaced or moved aside, from backups, and removes the files it created. `wb files restore <module> <file>` does the same for one file.

## Troubleshooting

See `docs/troubleshooting.md`.
