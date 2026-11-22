# Using workbench alongside an existing shell setup

Many machines already have a complete shell setup before workbench arrives: a distribution's own files, a colleague's dotfiles, or years of your own `.bashrc`. This page covers what workbench leaves alone on a machine like that, what it changes on purpose, and how to check for yourself.

The rule behind it: **workbench only changes things it created.** Where something already exists, workbench keeps it, works around it, or adds to it. It doesn't reset, overwrite or reorder it.

This page covers bash. zsh isn't covered here yet.

## What workbench leaves alone

On a machine with its own shell setup, loading workbench:

- leaves your `EDITOR`, `LANG`, aliases, functions and `PATH` order as they were, and never sets `LC_ALL`;
- leaves your prompt hooks in place. A reload removes only the hooks workbench itself added. Anything of yours in `PROMPT_COMMAND`, duplicates and empty entries included, stays where it is;
- isn't affected by your own `cd` or `ls` aliases or wrappers. Workbench's own code doesn't use them;
- stops warning about your startup file once you tell it the file is meant to stay as it is (see [Opting out](#opting-out)).

The [workbench-shell](https://github.com/GingerGraham/workbench-shell) and [workbench-devtools](https://github.com/GingerGraham/workbench-devtools) modules follow the same rule:

- an alias or function you already have isn't replaced (workbench's `lsa` gives way to yours);
- `VISUAL` follows an `EDITOR` you set before workbench;
- each `FZF_*` default applies only if you haven't set that variable;
- starship isn't started a second time when your setup already started it;
- the lazy-loading `nvm`, `node`, `npm` and `npx` commands aren't defined when `nvm` is already loaded in your shell.

## Alias and function clashes

Workbench never replaces an alias or function it didn't define. If a module would define an alias for a name that's already an alias or a function in your shell, workbench keeps yours and doesn't define its own. A command on your `PATH` doesn't count: aliases such as `cat` and `top` shadow commands on purpose. An existing alias that is identical to the one workbench would set isn't a clash either.

This matters beyond keeping your definition. Bash reads an alias before it parses the line, including the name in `name() {`. If workbench's alias existed, re-sourcing a file of yours that defines a function of the same name would fail with `syntax error near unexpected token '('`.

What you see:

- **The first interactive shell** after a clash appears prints one warning that lists each name, whether yours is an alias or a function, and the value workbench would have set. Nothing is changed. Later shells say nothing about a clash they've already reported; a clash that goes away and comes back warns again. Non-interactive shells never print it.
- **`wb status`** lists the clashes as of your last interactive shell start.
- **`wb functions`** and each module's `get-<name>-functions` don't list a name workbench left alone.

There's no setting yet that makes workbench's alias win. To use workbench's version, rename or remove yours. If you do, the next shell defines it and the entry disappears.

This holds on a reload too. If you redefine one of workbench's aliases after workbench has loaded (a line of your own below workbench's in your startup file, or at the prompt), `wb reload` and the reload after a `wb` command keep your version, and `wb status` lists it. Workbench's own aliases are still refreshed on a reload, so a module update's new value takes effect. A reload takes a little longer because workbench checks each alias it set earlier.

## What workbench changes on purpose

- **It adds one line to your shell startup file** (`~/.bashrc`, and the zsh files if you use zsh), after everything already there. Before adding it the first time, it backs up a file that already has content. See [Your existing startup file](#your-existing-startup-file).
- **It adds `~/.local/bin` to the end of `PATH` if it's missing.** If it's already there, in any position, nothing moves. Directories are added, never reordered. At the end, system commands win over anything in `~/.local/bin`; to prefer a tool you installed there, put the directory first in your own startup file.
- **It removes repeated `PATH` entries** once loading finishes. It keeps the first copy of each, so it never changes which directory wins. This is the one place workbench touches something it didn't create.
- **Some modules set defaults where you have none.** With workbench-shell installed and no `FZF_*` variables of your own, fzf gets workbench's defaults (height, layout, and `fd` to list files). That also changes how your own fzf aliases look and where they list files from. Set the variable yourself and workbench leaves it alone.

## Your existing startup file

Workbench never overwrites `.bashrc`, `.zshrc` or `.zshenv`. It only adds its one line, once.

If the file already had content the first time, that content stays in place, and a copy is saved under `~/.local/share/workbench/backups/` (or `$XDG_DATA_HOME/workbench/backups/` if you set `XDG_DATA_HOME`), with `rc-stub` in its name. Running the installer again never makes another copy.

While that backup is there, every new shell prints a warning naming it. The warning is there so you can move your old setup across if you want to:

1. Open the backup.
2. Copy anything you want to keep into a new file under `~/.config/workbench/local/`, such as `90-migrated.sh`. Any filename ending in `.sh` works.
3. Delete the backup.

Nothing is merged for you.

If your startup file is meant to stay exactly as it is, there's nothing to move. See [Opting out](#opting-out) to stop the warning.

If your startup file already sets up a prompt (starship, oh-my-posh, oh-my-zsh, powerlevel10k), workbench sees that and doesn't set its own.

## Checking what changed

Take a snapshot of your shell before installing, another after, and compare them.

```bash
snapshot_shell_state() {
    # usage: snapshot_shell_state before|after
    {
        echo "## bash ${BASH_VERSION}  SHLVL=${SHLVL}  login_shell=$(shopt -q login_shell && echo yes || echo no)"
        echo "## aliases";            alias
        echo "## function names";    declare -F | sed 's/^declare -f //' | sort
        echo "## cd/zd/z bodies";     declare -f cd zd z 2>/dev/null
        echo "## exported env";       env | sort
        echo "## shell-local vars"
        declare -p HISTSIZE HISTFILESIZE HISTCONTROL HISTIGNORE PS1 PS0 2>/dev/null
        echo "## PROMPT_COMMAND";     declare -p PROMPT_COMMAND 2>/dev/null
        echo "## traps";              trap -p
        echo "## shopt";              shopt -p | sort
        echo "## key bindings (bound only)"
        bind -P 2>/dev/null | grep -v 'is not bound'
    } > "/tmp/shell-state-$1.txt"
}
```

Paste the function into a new interactive shell and run it:

```bash
snapshot_shell_state before
```

Install workbench, open a new interactive shell, paste the function again and run:

```bash
snapshot_shell_state after
```

Then compare:

```bash
diff /tmp/shell-state-before.txt /tmp/shell-state-after.txt
```

You should see new `WORKBENCH_*` variables, the `wb` command and workbench's own functions, and the aliases and defaults of the modules you added. If one of your own settings changed or disappeared (an alias, `EDITOR`, a `PROMPT_COMMAND` entry, the position of a `PATH` entry), that's a bug. Please [report it](https://github.com/GingerGraham/workbench-core/issues).

Take another snapshot after each `wb add <module>`. Adding modules one at a time shows you which module changed what.

## Opting out

- **A config file you want to keep.** When the installer asks about an existing file, keep yours. Later: `wb files policy <module> <file> skip`.
- **A block you don't want in one of your config files.** `wb add <module> --skip-layer <layer>` never adds it. `wb files policy <module> <layer> skip` removes it. See [Workbench blocks in your own files](config-files.md#workbench-blocks-in-your-own-files).
- **The startup file warning.** If your startup file is meant to stay as it is, the warning prints a `touch '<backup>.acknowledged'` line under each backup. Run it, and that backup stops warning but stays on disk. If workbench later makes a new backup, you'll get a warning for that one.
- **A module's shell code.** `wb load disable <name>` turns it off in new shells, while updates and config carry on.

## Omarchy 4.x

Omarchy loads its setup in this order: `/etc/profile.d/omarchy.sh`, then `~/.bashrc`, which loads an `rc` file with its environment variables, aliases, functions and an init file. That init file starts `mise`, `starship`, `zoxide`, `fzf` and `try`. Workbench's line goes at the end of `~/.bashrc`, after all of that, so workbench always runs second.

What workbench changes there:

- the line at the end of `~/.bashrc`, and a backup of the file as it was;
- files that modules add or layer into your config, such as the tmux and vim blocks and copied config from workbench-shell. `wb files status` lists every one.

What it leaves alone: `EDITOR`, `SUDO_EDITOR`, `BAT_THEME`, `MANPAGER`, `LANG`, the `ls`, `lsa` and `cd` aliases, the prompt hooks (`starship_precmd`, the terminal-title update, both `__zoxide_hook` entries), the `PATH` order, and an existing `~/.config/starship.toml` (if you keep it when asked).

Omarchy 4.5 defines a function named `gd`, so workbench-git doesn't define its `gd` alias there. Omarchy's `gd` stays as it is, and the first interactive shell says so once. See [Alias and function clashes](#alias-and-function-clashes).

What you'll see: `VISUAL` set to the same value as your `EDITOR`; the `cat`, `top`, `python`, `pip` and `lsr` aliases; and the fzf defaults described above, which also apply to Omarchy's `ff` and `eff` aliases.

Recommended order:

1. Install workbench on its own. Run the snapshot diff.
2. `wb add shell`. Run the snapshot diff.
3. Add the other modules one at a time, running the diff after each.

Your startup file is meant to stay as it is on Omarchy, so stop the warning as described under [Opting out](#opting-out).
