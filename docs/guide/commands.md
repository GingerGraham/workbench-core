# Command reference

Every `wb` command, what it's for, and examples. For every option a command takes, run `wb help <command>` or `wb <command> --help`.

In the examples, `<name>` is a module name as `wb status` shows it, such as `git` or `shell`.

- [Everyday use](#everyday-use): `status`, `update`, `functions`, `tools`
- [Setting up a machine](#setting-up-a-machine): `install`, `apply`, `scheduler`, `uninstall`
- [Managing modules](#managing-modules): `add`, `remove`, `revert`, `track`, `dev`, `sync`, `load`, `module`
- [Your config files](#your-config-files): `files`
- [Your shell](#your-shell): `reload`, `version`, `completion`, `help`

## Everyday use

### `wb status`

Shows every module you have, what version it follows, and whether its updates and shell code are turned on. It only reads; it never changes anything.

```sh
wb status
```

The columns:

| Column | Meaning |
|---|---|
| `MODE` | What the module follows: `latest`, a `tag`, a `branch` or a `commit`. |
| `REF` | The tag, branch or commit it's on. |
| `SYNC` | `true` if the module updates. |
| `LOAD` | `true` if its shell functions and aliases load. |
| `HOOKS_PENDING` | `true` if a setup step is waiting for your approval. Run `wb update <name>` to review it. |

When a file is waiting on your decision, a line says how many. `wb files status` lists them.

The last section lists any aliases workbench didn't set because you already had an alias or function of that name, or says `none`. It's as of your last interactive shell start. See [Alias and function clashes](existing-setups.md#alias-and-function-clashes).

### `wb update`

Downloads and applies the latest version of your modules now, without waiting for a scheduled update.

```sh
wb update            # every module
wb update shell      # one module
```

Your own edits to config files are never overwritten. If something needs your decision, `wb update` asks.

Modules with updates turned off (`wb sync disable`) are skipped by a bare `wb update`, but `wb update <name>` still updates them.

### `wb functions`

Lists the shell functions, aliases and helper commands your modules provide, grouped by module.

```sh
wb functions                   # everything
wb functions git               # only names containing "git", or everything from a module named git
wb functions ssh gpg           # names containing "ssh" or "gpg"
wb functions --all             # include functions whose tools aren't installed yet
wb functions --no-aliases      # functions only
```

A function that needs a tool you don't have yet is listed separately, under "available once tooling is installed", with the `wb tools install` command that installs it.

Long output is shown a page at a time: space for the next page, Enter for the next line, `a` for the rest, `q` to stop. `--no-pager` turns that off for one run. To use another pager, set `WORKBENCH_PAGER`, for example `WORKBENCH_PAGER="less -FRX"`. Set it to `none` to turn paging off.

### `wb tools`

Lists and runs the installers your modules provide, for software such as `direnv`, `terraform` or `jq`. Nothing is installed unless you ask, and installers never run on a schedule.

```sh
wb tools list                  # every installer, by module
wb tools list --status         # also show which tools are already installed
wb tools install direnv        # install one tool
wb tools install direnv jq     # install several
wb tools install all           # install everything (asks first)
wb tools upgrade               # upgrade every tool that's already installed
wb tools upgrade direnv        # upgrade one
```

`wb tools upgrade` only touches tools that are already installed. It never installs something new.

`wb update` and `wb tools` are separate. `wb update` updates your modules. `wb tools` installs and upgrades the software those modules know how to install.

## Setting up a machine

### `wb install`

Sets up workbench on this machine. The installer runs it for you, so you normally only run it yourself to add a bundle.

```sh
wb install --bundle workstation                      # add a bundle
wb install --bundle workstation --keep-files         # keep all your existing config, without asking
wb install --bundle workstation --use-files --yes    # use workbench's config everywhere, without asking
wb install --yes                                     # install any missing tools without asking
```

If tools workbench needs are missing, `wb install` lists them with their packages and the install command, and asks before installing them. `--yes` answers yes to that question and to the `--use-files` confirmation.

`--use-files` backs up your existing config before replacing it. Add `--follow` to keep those files following their module even after you edit them; your edits are backed up each time.

### `wb apply`

Runs the same setup as `wb install` again: checks the tools workbench needs, the `wb` command on your `PATH`, and the line in your shell startup files.

```sh
wb apply
```

Run it after changing something by hand. An update to workbench itself runs it for you.

### `wb scheduler`

Turns background updates on or off for this machine. They're off until you turn them on.

```sh
wb scheduler enable      # check for updates in the background
wb scheduler status      # is it on, and is it running
wb scheduler disable     # turn it off
```

On Linux this is a systemd user timer. On macOS it's a launchd agent.

Background updates only touch modules whose updates are turned on. See [`wb sync`](#wb-sync).

### `wb uninstall`

Removes workbench itself: the `wb` command, the line in your shell startup files, the background timer, and workbench's own files.

```sh
wb uninstall --dry-run    # see what would happen, change nothing
wb uninstall
```

Your modules' config files stay in place and keep working. Their functions and aliases stop in new shells. Backups, your settings, and your SSH config and keys are left alone.

It leaves a note at `~/workbench-removal-notes.md` that lists everything left behind, why, and how to remove each part. To take a module's config out too, run `wb remove <name> --restore` before uninstalling.

See [Uninstalling workbench](managing-modules.md#uninstalling-workbench).

## Managing modules

### `wb add`

Adds a module and installs it.

```sh
wb add cloud                                         # a module from the list
wb add devtools cloud ai                             # several at once
wb add awsconfd https://github.com/you/awsconfd.git  # from your own repository
wb add awsconfd git@github.com:you/awsconfd.git --private   # a private repository
```

If the module would touch config you already have, `wb add` asks first. See [If you already have config files](getting-started.md#if-you-already-have-config-files).

Useful options:

| Option | What it does |
|---|---|
| `--keep-files` | Keep your existing config, without asking. |
| `--use-files` | Use the module's config. Yours is backed up first. |
| `--skip-layer <id>` | Don't add the module's block to one of your config files. `<id>` is `gitconfig`, `ssh_config`, `tmux.conf` or `vimrc`. |
| `--private` | The repository is private. Workbench creates a deploy key for it. |
| `--allow-hooks` | Let the module run its own setup step after each update. Off unless you allow it. |

Adding back a module you removed doesn't need its URL again. Workbench shows the version you were on and the latest release, and asks which you want. `--latest` or `--keep-version` answers in advance.

### `wb remove`

Stops using a module. By default its config files stay where they are.

```sh
wb remove cloud              # stop using it, keep its config
wb remove cloud --restore    # stop using it, and put back what it replaced
```

`--restore` shows what it will put back and asks first.

To remove workbench itself, use [`wb uninstall`](#wb-uninstall).

### `wb revert`

Goes back to an earlier version of a module that's still on this machine, and stays there. It doesn't need the network.

```sh
wb revert shell --list       # the versions on this machine
wb revert shell              # go back one version
wb revert shell v1.4.0       # go back to a version from the list
wb track shell --latest      # follow new releases again
```

Workbench keeps the last 3 versions of each module. For anything older, use `wb track <name> --tag <tag>`.

### `wb track`

Sets which version a module follows, then updates it.

```sh
wb track shell --latest            # the newest release (the default)
wb track shell --tag v1.2.0        # one release, and stay there
wb track shell --commit 3f2a9c1    # one commit, and stay there
wb track shell --branch my-fix     # a branch, checked for changes often
```

While any module follows a branch, background updates check every 5 minutes instead of weekly.

### `wb dev`

A guided version of `wb track`. It asks, module by module, what each should follow.

```sh
wb dev           # go through every module
wb dev shell     # just one
```

Use `wb track` when you already know what you want.

### `wb sync`

Turns updates for one module on or off. A module with updates off keeps working on the version it has.

```sh
wb sync disable shell    # stop updating it
wb sync enable shell     # start again
```

This is separate from [`wb scheduler`](#wb-scheduler), which turns background updates on for the whole machine. A module only updates in the background when both are on.

### `wb load`

Turns a module's shell functions, aliases and prompt setup on or off in new shells. Updates and config files carry on. Use it to find out whether a module's shell code is causing a problem.

```sh
wb load disable shell    # new shells don't load it
wb load enable shell     # load it again
```

A shell that's already open keeps what it loaded. Open a new terminal to see the change.

Which one do you want?

| You want to | Run |
|---|---|
| Stop its shell code. Updates and config stay on. | `wb load disable <name>` |
| Stop its updates. Everything keeps working. | `wb sync disable <name>` |
| Take out one of its config files. | `wb files restore <name> <file>` |
| Stop using it. Its config stays in place. | `wb remove <name>` |
| Stop using it and take its config out. | `wb remove <name> --restore` |

### `wb module`

Shows what a module says about itself.

```sh
wb module info shell     # where it comes from, what it follows, and a description
wb module docs shell     # its own help or README
```

`wb module reset <name> <file>` is the same as [`wb files use`](#wb-files).

## Your config files

### `wb files`

Shows and manages the config files modules put on your machine, and the blocks they add to your own files. [Your config files](config-files.md) explains the ideas behind these commands.

```sh
wb files status                      # every file, and anything waiting on you
wb files status shell                # one module's files
wb files diff shell tmux.conf        # your copy against the module's
wb files resolve shell all           # decide about everything of shell's that's waiting
wb files use shell tmux.conf         # use the module's version (yours is backed up)
wb files use shell all               # every file the module ships
wb files restore shell tmux.conf     # put back what you had before
wb files policy                      # show every file's policy
wb files policy shell tmux.conf skip # never touch this file again
wb files settle                      # put workbench's blocks back where they belong
```

A file can be named by its path (`~/.config/tmux/tmux.conf`), its filename (`tmux.conf`), or, for a block in your own config, the tool's name (`gitconfig`, `ssh_config`, `tmux.conf`, `vimrc`).

Anything that writes shows a preview, says where backups go, and asks first.

## Your shell

### `wb reload`

Reloads workbench into the shell you're in. Commands that change what's installed already do this for you. Use it after a background update, or after adding your own files to `~/.config/workbench/local/`.

```sh
wb reload
```

### `wb version`

Shows which version of workbench you have.

```sh
wb version
```

### `wb completion`

Prints the tab-completion script for bash or zsh. Completion is set up for you, so you don't normally need this.

```sh
wb completion bash
wb completion zsh
```

Tab completes command and sub-command names, the modules, bundles and tools on your machine, and each command's flags once you type a dash (`wb add --pr<Tab>`). For `wb module reset <name>` and `wb files use <name>`, it offers that module's own files, and `all`.

### `wb help`

Lists every command, grouped. With a command name, shows everything that command can do.

```sh
wb help
wb help files
wb files --help    # the same thing
```
