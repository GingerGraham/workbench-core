# Troubleshooting

## The installer stopped because tools are missing

You answered no, or there was no terminal to ask and no `--yes`. Install the tools it listed with your package manager (it prints the command), then run the same install command again. Or run it again with `--yes` to let the installer install them.

Workbench needs `awk`, `sed`, `tr`, `grep`, `column`, `git`, `curl`, `tar`, `ssh-keyscan` and `ssh-keygen`. Some come from packages with unexpected names:

| Tool | Fedora, RHEL | Debian, Ubuntu | Arch |
|---|---|---|---|
| `awk` | `gawk` | `mawk` | `gawk` |
| `tr` | `coreutils` | `coreutils` | `coreutils` |
| `column` | `util-linux` | `bsdextrautils` | `util-linux` |
| `git` | `git-core` | `git` | `git` |
| `ssh-keyscan`, `ssh-keygen` | `openssh-clients` | `openssh-client` | `openssh` |

On Fedora and RHEL, `git-core` is all workbench needs; the full `git` package adds Perl-based extras such as `git send-email`.

## My shell has no workbench commands after installing

1. Open a new terminal, or run `source ~/.bashrc` (`source ~/.zshrc` in zsh). Workbench loads when a shell starts.
2. Check the line was added to your startup file:

   ```sh
   grep workbench ~/.bashrc
   ```

3. Run `wb status`. If there's no `core` row, run `wb install` again.
4. Run `wb apply`. It checks everything the installer set up and fixes what's missing.
5. Still nothing? Run the loader directly to see any errors:

   ```sh
   bash -x ~/.local/share/workbench/modules/core/current/lib/loader.sh
   ```

## A module is installed, but its functions aren't there

- Check the `LOAD` column in `wb status`. If it says `false`, the module's shell code is turned off. Run `wb load enable <name>`.
- Check `wb status` for a warning under the module. A module whose version needs a newer workbench says so, with the command to fix it.
- Updated by the background timer? Your open shell doesn't know yet. Run `wb reload`, or open a new terminal.

## A function I expected isn't in `wb functions`

Look below the main list for "available once tooling is installed". A function that needs a tool you don't have is listed there, grouped by the tool it needs.

If it shows `install: wb tools install <tool>`, run that, then list again. You don't need a new shell.

The function itself still works if you call it; it just isn't listed as ready to use. To list everything regardless:

```sh
wb functions --all
```

A group headed "module gave no reason" means the module says the function isn't ready but doesn't say why. "availability check timed out" means the check took too long.

## `wb update` isn't picking up a new release

- Check `MODE` in `wb status`. A module on a `tag` or `commit` stays there on purpose. Run `wb track <name> --latest` to follow releases again.
- Check `SYNC` in `wb status`. If it's `false`, a bare `wb update` skips the module. Run `wb update <name>`, or `wb sync enable <name>`.
- GitHub limits release lookups to 60 an hour per IP address. If you hit that, the log says so, and the next update works once the hour is up. On a shared connection, set `WORKBENCH_GITHUB_TOKEN`; see [Behind a shared IP address](getting-started.md#behind-a-shared-ip-address).

## A private module won't update

- Workbench created a public key at `~/.ssh/workbench-<name>.pub`. Check it's added to the repository on GitHub as a deploy key, without write access.
- Test the connection:

  ```sh
  ssh -T workbench-<name>
  ```

  GitHub replies "Hi <repo>! You've successfully authenticated...".
- Added the key after adding the module? Run `wb update <name>`. Nothing else needs redoing.

## A module's setup step didn't run

Some modules run a setup step after an update. The `HOOKS_PENDING` column in `wb status` shows `true` when one is waiting for your approval. Background updates never run one that hasn't been approved.

Run `wb update <name>` in a terminal. It shows what changed and asks before running it.

## Modules don't update on their own

Background updates are off until you turn them on:

```sh
wb scheduler enable
wb scheduler status
```

If `wb scheduler enable` says it could not enable or start `workbench-sync.timer`, there's no systemd user session. That's common in containers and on servers you aren't logged in to. Either:

- keep a user session running without a login, then try again:

  ```sh
  loginctl enable-linger "$USER"
  wb apply
  ```

- or run `wb update` yourself, by hand or from your own cron job. Nothing else depends on the timer.

## My startup file warns about a backup in every new shell

That's workbench pointing at the copy it saved of your startup file before adding its line. See [Your existing startup file](existing-setups.md#your-existing-startup-file) to move your old setup across, or to stop the warning.

## `bashsource` fails with `syntax error near unexpected token '('`

Something defines an alias with the same name as a function in the file being re-read. Bash expands the alias before it parses `name() {`, so the line reads as something else and fails. Current workbench doesn't create that situation: it doesn't define an alias when a function of that name exists.

A shell that started before you updated workbench still holds the old aliases. Re-sourcing a file that defines a function of the same name fails in that one shell. Open a new terminal, or remove the alias first:

```sh
unalias <name>
```

Every shell started after the update is fine. The first one prints a warning if workbench left any name alone; see [Alias and function clashes](existing-setups.md#alias-and-function-clashes).

## A workbench alias is missing, and a warning said why

The warning means you already had an alias or function of that name, and workbench kept it. `wb status` lists every name it left alone. To use workbench's version instead, rename or remove yours. There's no setting yet that makes workbench's alias win.

## A file is waiting on my decision

A new shell says when a file needs your decision, and `wb status` says how many. Run `wb files status` to see them. [When a file needs your decision](config-files.md#when-a-file-needs-your-decision) explains the choices.

## I see `git` running, and thought workbench didn't use it

Workbench downloads public modules without `git`. It uses `git` only for private modules and for modules that follow a branch. Check `MODE` in `wb status` for a `branch` module.

## I switched a module to a branch and now its files are on disk twice

That's expected. Your own copy of the repository is where you edit. Workbench keeps a separate copy of the branch it follows. Changes reach workbench's copy when you push them to the branch.

## I can't edit or delete a file under `~/.local/share/workbench`

Workbench makes the copy of each module it downloads read-only, so a stray edit can't change what it deploys. To change a setting, edit the file in your home directory. A file workbench copied there is yours to edit. A file workbench links to the module's copy can be edited where it is.

To delete the whole directory by hand, first run `chmod -R u+w ~/.local/share/workbench`. `wb uninstall` does this for you.

## Still stuck

[Open an issue](https://github.com/GingerGraham/workbench-core/issues/new/choose). Include the output of `wb status` and `wb version`, and what you ran.
