# Using workbench alongside an existing shell setup

Many hosts already have a complete shell profile before workbench arrives:
a distribution's own files, a colleague's dotfiles, or years of your own
`.bashrc`. This page says what workbench leaves alone on such a host, what it
does on purpose, and how to check.

The rule behind it is [D110](decisions-log.md): **workbench changes only state
it created.** Where something already exists, workbench keeps it, yields to
it, or adds to it. It does not reset, overwrite or reorder it.

This page assumes your login shell stays bash. The zsh behaviour (D96, D107)
is not covered here.

## What workbench guarantees

On a host with its own profile, loading workbench:

- leaves your `EDITOR`, `LANG`, aliases, functions and `PATH` order as they
  were, and never sets `LC_ALL`;
- leaves your prompt hooks in place. A reload (`source ~/.bashrc`, or the
  automatic reload after a `wb` command) removes only the hook entries
  workbench itself added. Duplicates and empty entries in your own
  `PROMPT_COMMAND` stay where they are;
- never lets a `cd` or `ls` alias or wrapper of yours change what
  workbench's own code does. Its sourced code uses `builtin cd` and
  `command ls`;
- stays quiet about your rc file once you say it is meant to stay as it is
  (see "Opting out").

The workbench-shell and workbench-devtools modules follow the same rule:

- an alias or function you already have is not replaced (workbench's `lsa`
  yields to yours);
- `VISUAL` follows an `EDITOR` that was set before workbench;
- each `FZF_*` default applies only if you have not set that variable;
- starship is not initialised a second time when your profile already did
  it;
- the lazy `nvm` / `node` / `npm` / `npx` stubs are not defined when `nvm`
  is already loaded in your shell.

## What workbench still does on purpose

- **It appends one loader line to your rc file** (`~/.bashrc`, and the zsh
  files if you use zsh), after everything already there. Before the first
  append it backs up a non-empty file (D64).
- **It puts `~/.local/bin` on `PATH` if it is missing.** If it is already
  there, at any position, nothing moves. Directories are added, never
  reordered.
- **It removes repeated `PATH` entries at the end of a load** (`dedupe-path`,
  a Core API function). It keeps the first occurrence of each, so it never
  changes which directory wins. This is the one place workbench touches
  something it did not create.
- **Some modules set defaults where you have none.** With workbench-shell
  installed and no `FZF_*` variables of your own, fzf gets its defaults
  (height, layout, `fd` as the file source). That also changes how any fzf
  alias of your own looks and where it lists files from. Set the variable
  yourself and workbench leaves it alone.

## Checking what changed

Take a snapshot in an interactive bash before installing, another after, and
compare them.

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

Paste the function into a clean interactive shell and run it:

```bash
snapshot_shell_state before
```

Install workbench, open a new interactive shell, paste the function again and
run:

```bash
snapshot_shell_state after
```

Then compare:

```bash
diff /tmp/shell-state-before.txt /tmp/shell-state-after.txt
```

Expected differences: new `WORKBENCH_*` variables, the `wb` function and
workbench's own functions, and the aliases and defaults of the modules you
added. If a line of yours changed or disappeared (an alias, `EDITOR`, a
`PROMPT_COMMAND` entry, the position of a `PATH` entry), that is a bug worth
reporting.

Take the snapshot again after each `wb add <module>`. Adding modules one at a
time makes the diff say which module changed what.

## Opting out

- **A config file you want to keep.** At the install prompt about an existing
  file, keep yours (D84). Later: `wb files policy <module> <file> skip`.
- **A tool config block you do not want.** `wb add <module> --skip-layer
  <layer>` never adds it. `wb files policy <module> <layer> skip` removes it.
  The block layers are described in [getting-started.md](getting-started.md).
- **The rc-file migration warning.** If your rc file is meant to stay as it
  is, the warning prints a `touch '<backup>.acknowledged'` line under each
  backup. Run it and that backup stops warning and stays on disk. A later
  stub rewrite that makes a new backup warns again.
- **A module's shell code.** `wb load disable <name>` turns it off in new
  shells while keeping updates and config.

## Omarchy 4.x

Omarchy's boot chain is `/etc/profile.d/omarchy.sh`, then `~/.bashrc`, which
sources an `rc` file that loads its environment variables, aliases,
functions and an init file. That init file starts `mise`, `starship`,
`zoxide`, `fzf` and `try`. Workbench's loader line is appended to
`~/.bashrc` after all of that, so workbench always runs second.

What workbench touches there:

- the loader line at the end of `~/.bashrc` (and a backup of the file as it
  was);
- files that modules deploy or layer into your config: the tmux and vim
  blocks and copied configs from workbench-shell, and the like. `wb files
  status` lists every one.

What it leaves alone: `EDITOR`, `SUDO_EDITOR`, `BAT_THEME`, `MANPAGER`,
`LANG`, the `ls`, `lsa` and `cd` aliases, the prompt hooks (`starship_precmd`,
the terminal-title update, both `__zoxide_hook` entries), the `PATH` order,
and an existing `~/.config/starship.toml` (kept at the install prompt).

Things you will see: `VISUAL` set to the same value as your `EDITOR`; the
`cat`, `top`, `python`, `pip` and `lsr` aliases; the fzf defaults described
above, which also apply to Omarchy's `ff` and `eff` aliases.

Recommended order:

1. Install core. Run the snapshot diff.
2. `wb add shell`. Run the snapshot diff.
3. Add the other modules one at a time, running the diff after each.

Your rc file is meant to stay as it is on Omarchy, so acknowledge the backup
as described under "Opting out".
