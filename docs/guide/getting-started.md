# Getting started

This page takes you from nothing installed to a shell with workbench loaded and your first modules added.

## What you need

- Linux, macOS, or Windows with WSL2. Windows itself (PowerShell) isn't supported.
- bash 3.2 or newer, or zsh.
- `curl`, `tar`, `awk`, `sed`, `tr` and `grep`. Almost every system already has these.

The installer checks for the rest (`column`, `git`, `ssh-keyscan` and `ssh-keygen`) and offers to install anything missing with your system's package manager.

## Install

Most people want a bundle: workbench plus a set of modules chosen to work together. `workstation` adds the git, gpg, ssh and shell modules:

```sh
curl -fsSL https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh | bash -s -- --bundle workstation
```

Swap `workstation` for any bundle in the [modules and bundles list](https://github.com/GingerGraham/workbench-core#modules-and-bundles). `bash -s --` passes the options after it to the installer, not to `bash`.

To install workbench on its own and add modules later:

```sh
curl -fsSL https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh | bash
```

Already have workbench installed? `wb install --bundle workstation` adds a bundle at any time.

### Read the installer first

If you'd rather not pipe a script straight into `bash`, download it and read it first:

```sh
curl -fsSLO https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh
less bootstrap.sh
bash bootstrap.sh --bundle workstation
```

### If you already have config files

On a new machine there's nothing to ask about, so nothing is asked.

On a machine where you already have config that a module would touch, such as `~/.gitconfig` or a tmux config, the installer lists those files and asks what to do:

| Answer | What happens |
|---|---|
| `k` | Keep yours. This is the default. |
| `u` | Use workbench's. Yours are backed up first, and your git identity and ssh hosts are carried over. |
| `c` | Choose for each file: keep, use, or skip. |
| `d` | Show the differences, then ask again. |
| `q` | Quit. Nothing is changed, and the next `wb update` asks again. |

Keeping yours doesn't mean missing out. For git, ssh, tmux and vim, workbench adds one small marked block to your file, and anything you set yourself still wins. [Your config files](config-files.md) explains how that works and how to change your mind later.

To answer in advance, add `--keep-files`, or `--use-files --yes`, after `--bundle <name>`. With no terminal (cloud-init, CI), the answer is always keep.

### Behind a shared IP address

The installer finds the latest release through GitHub's API, which allows 60 requests an hour from each IP address. On a shared connection, such as an office network or a CI runner, that can run out.

Set `WORKBENCH_GITHUB_TOKEN` to a GitHub token first. A fine-grained token with read-only access to public repositories is enough:

```sh
export WORKBENCH_GITHUB_TOKEN=github_pat_...
curl -fsSL https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh | bash -s -- --bundle workstation
```

The token is only sent to `api.github.com`, and is never saved to a file. Scheduled updates don't see a variable you export in your shell.

## What the installer does

- Downloads the latest workbench release. It doesn't use `git`.
- Checks for the tools it needs, and offers to install any that are missing.
- Puts the `wb` command on your `PATH`.
- Adds one line to the end of `~/.bashrc`, and to `~/.zshrc` and `~/.zshenv` if you use zsh, so new shells load workbench. A file that already had content is backed up first.
- Adds the bundle's modules, if you chose a bundle.
- Creates `~/.config/workbench/local/settings.sh` for your own settings.

It doesn't turn on background updates. That's your choice: see [Updating, pausing and removing modules](managing-modules.md).

Running the installer again is safe. It checks the same things and changes only what's missing.

## Load workbench

When the installer finishes, open a new terminal, or run the `source` line it prints to load workbench into the current one. For example:

```sh
source ~/.bashrc
```

You only need to do this once. From then on, `wb` commands that change what's installed reload your shell for you.

Check that everything is in place:

```sh
wb status
```

## Add modules

Add modules from the [modules and bundles list](https://github.com/GingerGraham/workbench-core#modules-and-bundles) by name. You can add several at once:

```sh
wb add cloud iac
```

A module's commands are ready to use as soon as `wb add` finishes.

To add a module from your own repository, give a name and the repository URL:

```sh
wb add awsconfd https://github.com/you/awsconfd.git
```

For a private repository, add `--private`:

```sh
wb add awsconfd git@github.com:you/awsconfd.git --private
```

Workbench creates a deploy key and prints its public half. Add it to the repository on GitHub under Settings → Deploy keys → Add deploy key. Don't allow write access: workbench only reads.

If the first update failed because the key wasn't added yet, run `wb update awsconfd` once it is.

## Everyday commands

```sh
wb status                 # what's installed and what each module follows
wb update                 # update every module now
wb functions              # list the shell functions and aliases you have
wb tools list             # list the tools your modules can install
wb tools install <name>   # install one of them
wb help                   # every command, grouped
```

The [command reference](commands.md) has every command, with examples.

## Keep your own set of modules

A bundle is a named list of modules. To install the same set on every machine you use, define your own bundle in `~/.config/workbench/catalog/bundles.list`:

```
# <bundle-name>|<comma-separated module names>
mine|git,ssh,shell,cloud,iac
```

Then setting up a new machine is one command:

```sh
curl -fsSL https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh | bash -s -- --bundle mine
```

Your file replaces the bundles workbench ships, rather than adding to them. Copy in any shipped bundle you still want to use.

## Your own settings, functions and aliases

`~/.config/workbench/local/settings.sh` holds your settings. It's read before anything else loads, and again at the end, so what you set there wins. It starts with these settings commented out:

| Setting | What it does |
|---|---|
| `WORKBENCH_PLAIN_SHELL=true` | A plain shell: no coloured prompt, and no function list when a shell starts. |
| `WORKBENCH_SHOW_FUNCTIONS=true` | Print a short list of your functions when each new shell starts. |
| `WORKBENCH_DEBUG=true` | Detailed logging, for tracking down a problem. |
| `WORKBENCH_ALLOW_AUR=true` | Let installers use the Arch User Repository. Off by default, because AUR packages are unreviewed build scripts. Without it, an installer that needs the AUR prints the command for you to run yourself. |

For your own functions and aliases, add any other `*.sh` file to `~/.config/workbench/local/`. Those files load after `settings.sh`, in filename order. New shells pick them up, or run `wb reload` to load them into the current one.

## Next steps

- [Your config files](config-files.md): how workbench treats config you already have.
- [Updating, pausing and removing modules](managing-modules.md): background updates, pinning a version, going back, and uninstalling.
- [Using workbench alongside an existing shell setup](existing-setups.md): what workbench leaves alone, and how to check.
- [Troubleshooting](troubleshooting.md): when something isn't working.
