# Your config files

Modules ship config: a tmux config, a vimrc, a whole neovim setup, git and ssh settings. This page explains how workbench puts that config on your machine without taking over yours, and how to change your mind later.

## What workbench promises

- It never removes or replaces a file it didn't put there.
- If you already have a file, it's left alone. That includes the other places a tool looks: an existing `~/.vim/vimrc` stops workbench creating `~/.vimrc`.
- If you edit a file workbench created, it's yours from then on, and updates stop touching it.
- If you delete a file workbench created, it isn't put back.
- If something else changes a file workbench linked into place (neovim's `:Lazy update` rewriting `lazy-lock.json`, for example), the next update leaves that file as it is and asks you what to do.

## Choosing when you add a module

When a module would touch config you already have, `wb add` and the installer ask before writing anything. See [If you already have config files](getting-started.md#if-you-already-have-config-files) for the choices.

"Keep mine" means different things for different files:

- **git, ssh, tmux and vim config:** your file stays as it is, and the module adds one marked block to it. Anything you set yourself still wins. See [Workbench blocks in your own files](#workbench-blocks-in-your-own-files).
- **Whole files,** such as a `starship.toml`: yours is left alone, and the module's isn't used.

## Workbench blocks in your own files

For git, ssh, tmux and vim, a module doesn't replace your file. It adds one marked block to it, `~/.gitconfig`, `~/.ssh/config`, your tmux config or your vimrc, that pulls in the module's settings:

```
# >>> workbench git/gitconfig under >>>
# Managed by workbench (wb files status). Put your settings outside this block.
[include]
	path = "/home/you/.local/share/workbench/modules/git/current/files/gitconfig"
# <<< workbench git/gitconfig under <<<
```

The block sits where your own settings override it: before them for git, tmux and vim, which use the last value they read, and after them for ssh, which uses the first.

- Keep your own settings outside the block. Workbench rewrites what's inside it.
- The module's settings update with the module. There's nothing to approve.
- Delete the block's two marker lines and workbench never adds it back.

`wb files status` lists every block under "Layers".

To manage blocks, refer to them by the tool's name: `gitconfig`, `ssh_config`, `tmux.conf` or `vimrc`. A few blocks are placed to win over your settings, such as workbench-git's per-project identities. Those are named `<tool>:over`, for example `gitconfig:over`.

```sh
wb files policy git gitconfig skip     # remove the block and stop adding it
wb add git --skip-layer gitconfig      # never add it in the first place
wb files use git gitconfig             # back up your file and keep only workbench's block
wb files restore git gitconfig         # remove the block, and put back what 'use' backed up
```

If your config file is a symlink (managed with stow or chezmoi, for example), `wb files resolve` asks whether to write the block through the link or skip it.

## Using a module's version instead of yours

To switch to the module's version of a file you already have:

```sh
wb files use shell tmux.conf    # one file
wb files use shell all          # every file the module ships
```

Your file is moved to backups, along with any other file the same tool would also read, so an old `~/.tmux.conf` doesn't keep loading alongside workbench's. The module's version goes in its place.

After that, the file follows the module until you edit it. Add `--follow` to keep it following even after you edit it. Your edits are backed up each time.

To use workbench's files for every module from the start:

```sh
wb install --bundle workstation --use-files --follow
```

Want a module but not one of its files?

```sh
wb files policy shell tmux.conf skip
```

## When a file needs your decision

When something needs your decision, a new shell says so in one line, and `wb status` shows how many files are waiting.

```sh
wb files status          # every file, what's waiting, and what the next update will do
wb files diff shell tmux.conf   # your copy against the module's
wb files resolve shell all      # decide about everything of shell's that's waiting
```

For each file, you choose:

| Choice | What happens |
|---|---|
| `keep` | Mine from now on. No more updates to this file. |
| `manage` | Keep my changes, and keep updating everything else. |
| `use` | Take the module's version. Mine is backed up. |

`wb update` asks the same question when you run it in a terminal. Background updates never ask; they leave the file as it is.

## Policies

A policy decides how updates treat a file. `wb files policy` with no arguments shows the default and every file's policy.

| Policy | What updates do |
|---|---|
| `managed` | Update the file while you haven't edited it. The default. |
| `follow` | Always update the file. Your edits are backed up first. |
| `seed` | Create the file once and never update it. Copied files only. |
| `skip` | Never touch the file. |
| `default` | Go back to the module's or the machine's default. |

```sh
wb files policy shell tmux.conf follow   # one file
wb files policy --default follow         # every file on this machine
```

A policy applies straight away, not at the next release. For blocks in your own files, only `skip`, `managed` and `default` apply.

## Putting things back

```sh
wb files restore shell tmux.conf    # one file
wb files restore shell all          # everything from one module
wb remove shell --restore           # stop using the module and put everything back
```

Restoring brings back your originals from backups and removes the files workbench created. Anything you put in place of a workbench file is left alone.

If a command such as `git config --global` moved a workbench block inside your file, `wb files settle` puts it back where it belongs.
