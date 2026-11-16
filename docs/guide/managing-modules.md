# Updating, pausing and removing modules

This page covers how modules get updates, how to hold one on a version or go back, and how to stop using a module or workbench itself.

## How updates arrive

By default, nothing runs in the background. Modules update when you run:

```sh
wb update            # every module
wb update shell      # one module
```

To have modules update on their own, turn on background updates for this machine:

```sh
wb scheduler enable     # turn background updates on
wb scheduler status     # is it on, and is it running
wb scheduler disable    # turn it off again
```

On Linux and WSL2 this is a systemd user timer. On macOS it's a launchd agent. It checks every 5 minutes whether anything is due. Most of the time nothing is: modules that follow releases are checked weekly.

Background updates never ask you anything. If a file needs your decision, it's left as it is, and the next `wb update` you run asks.

If you had background updates set up by an older version of workbench, they stay on after you upgrade.

### Turning updates off for one module

```sh
wb sync disable shell    # stop updating it
wb sync enable shell     # start again
```

A module with updates off keeps working on the version it has, and its shell functions still load. `wb update shell` still updates it when you ask.

`wb scheduler` is the switch for the whole machine. `wb sync` is the switch for one module. A module only updates in the background when both are on.

## Choosing which version a module follows

New modules follow the latest release. To change that:

```sh
wb track shell --tag v1.2.0        # stay on one release
wb track shell --commit 3f2a9c1    # stay on one commit
wb track shell --branch my-fix     # follow a branch
wb track shell --latest            # follow releases again
```

A module on a tag or a commit stays there until you change it.

A module on a branch is checked every 5 minutes while background updates are on. That's mostly useful when you're working on a module yourself: the module's own repository is where you edit, and workbench keeps a separate copy of the branch, so you'll see the files twice on disk. That's expected.

`wb dev` asks you, module by module, what each should follow, if you'd rather not remember the options.

## Going back to an earlier version

If an update breaks something:

```sh
wb revert shell --list     # the versions still on this machine
wb revert shell            # go back one version and stay there
wb track shell --latest    # when you're ready to follow releases again
```

This doesn't need the network. Workbench keeps the last 3 versions of each module. For anything older, use `wb track <name> --tag <tag>`.

Files the newer version added are removed when you go back, unless you've changed them.

## Pausing, removing and coming back

| You want to | Run | Updates | Shell functions | Config files and blocks |
|---|---|---|---|---|
| Stay on this version | `wb sync disable <name>` | Only when you run `wb update <name>` | On | On |
| Go back to an earlier version | `wb revert <name>` | Pinned until `wb track <name> --latest` | On | Earlier version |
| Check if its shell code is the problem | `wb load disable <name>` | Unchanged | Off | On |
| Check if one config file is the problem | `wb files restore <name> <file>` | Unchanged | On | That file off |
| Stop using it, keep its config | `wb remove <name>` | Off | Off | On |
| Stop using it and take its config out | `wb remove <name> --restore` | Off | Off | Off |

`wb load enable <name>` and `wb sync enable <name>` turn those back on. `wb status` shows each setting.

### Coming back to a module you removed

```sh
wb add shell
```

You don't need its URL again. Workbench shows the version you were on and the latest release, and asks which you want. It recommends the latest. Your update and load settings are kept.

If you took its config out with `--restore`, it then asks whether to put that back.

With no terminal it can't ask, so the module comes back as you left it. To decide in advance, add `--latest` or `--keep-version`, and `--use-files` or `--keep-files`.

## Uninstalling workbench

```sh
wb uninstall --dry-run    # see what would happen, and the notes it would leave
wb uninstall
```

This removes the `wb` command, the line in your shell startup files, the background timer and workbench's own files.

Your modules stay in place:

- Their config files and blocks keep applying.
- Their functions, aliases and prompt setup stop in new shells, because workbench is what loaded them.

Backups, your settings, your SSH config and keys, and software workbench installed are all left alone, so removing workbench doesn't break anything you still use.

To take a module's config out as well, run `wb remove <name> --restore` before you uninstall. That command isn't available afterwards.

`~/workbench-removal-notes.md` lists everything left behind, why it was kept, and the commands to remove each part if you don't want it.

### Coming back

Install again with the same command you used the first time. Every module still on the machine comes back on the version it was on, and the removal notes are deleted.
