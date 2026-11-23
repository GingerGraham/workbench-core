# Module authoring guide

How to write a module for workbench: a repository that workbench can add with `wb add`, update, and load into the user's shell. The same applies to an independent tool you want workbench to track for you.

The full field reference is the [manifest specification](https://github.com/GingerGraham/workbench-core/blob/main/contracts/manifest-spec.md). The shell functions and variables a module can rely on are in the [Core API reference](https://github.com/GingerGraham/workbench-core/blob/main/contracts/core-api.md). This guide explains how to use them.

## Contents

- [Do you need a manifest?](#do-you-need-a-manifest)
- [Start from the template](#start-from-the-template)
- [The manifest](#the-manifest)
- [Release tags](#release-tags)
- [Registering shell content](#registering-shell-content)
- [Getters](#getters)
- [Defining aliases](#defining-aliases)
- [Shipping overridable defaults (`overrides_src`)](#shipping-overridable-defaults-overrides_src)
- [Deploying files](#deploying-files)
- [Layering config into a tool the user already uses](#layering-config-into-a-tool-the-user-already-uses)
- [Declaring installers (`wb tools`)](#declaring-installers-wb-tools)
- [Reporting install status](#reporting-install-status)
- [Declaring function availability](#declaring-function-availability)
- [Writing for bash and zsh](#writing-for-bash-and-zsh)
- [Keeping shell start clean](#keeping-shell-start-clean)
- [Publishing module info and docs](#publishing-module-info-and-docs)
- [Normalising the CPU architecture name](#normalising-the-cpu-architecture-name)
- [Hooks](#hooks)
- [Dev-mode disk duplication](#dev-mode-disk-duplication)
- [Testing your manifest](#testing-your-manifest)

## Do you need a manifest?

No. A repository with no manifest can still be added: workbench fetches it and keeps it up to date, and does nothing else with it.

You need a manifest if you want workbench to put files on disk, load shell functions, offer installers, or run a setup step for you.

## Start from the template

For a new module, generate a repository from [`GingerGraham/workbench-template`](https://github.com/GingerGraham/workbench-template), with GitHub's "Use this template" button or:

```sh
gh repo create --template GingerGraham/workbench-template
```

Don't start from scratch or copy another module. The template has the directory layout, a manifest to start from, CI, and the repository files every module carries, and it fills in your module's name on the first push.

## The manifest

Add `workbench.yml` to the root of your repository. Declare `deploy:` entries for files that should land on disk and, for shell integration, `core_api:` plus `register:`:

```yaml
# workbench.yml
version: 2
branch: main
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/mytool.sh
      tier: tools
```

`core_api:` is the range of Core API versions your module works with. Without it, workbench ignores `register:` and treats the manifest as deploy-only.

The older name, `.dotfiles-sync.yml` with `version: 1`, still works the same way. Use `workbench.yml` for anything new. The [manifest specification](https://github.com/GingerGraham/workbench-core/blob/main/contracts/manifest-spec.md) lists every field, and which filenames are found in what order.

## Release tags

A module following the latest release (the default for `wb add`) gets the highest tag in the form `X.Y.Z`, with an optional leading `v`.

- `v1.0.0` and `1.0.0` count as releases.
- `v1.0` (two parts), `v1.0.0.0` (four parts) and `v1.0.0-rc1` (a pre-release) don't. They aren't an error; they're skipped.
- A pre-release tag can still be pinned on purpose: `wb track <name> --tag v1.0.0-rc1`.

Any tag shaped like three numbers counts, whether you meant it as a release or not. If you tag other things that way, such as dates or build numbers, they'll be picked up as releases. Use a different shape for those.

Workbench doesn't check your tags for you yet. Follow this format.

## Registering shell content

`register.shell[].src` is a path relative to your repository root. `register.shell[].tier` (default `tools`) picks when the file loads, in this order: `env`, `core`, `tools`, `platform`, `distro`, `lazy`.

Two tiers load a file only on matching hosts:

- `platform`: the file's name (without `.sh`) must be `linux`, `macos` or `wsl`.
- `distro`: the file's name must match the distribution family (`rhel`, `debian`, `suse`, `arch`) or the exact `ID` from `/etc/os-release` (`fedora`, `ubuntu`, `pop`, `opensuse-leap`, …). On Fedora, `rhel.sh` and `fedora.sh` both load; list the family file first so the specific one wins. `debian.sh`, `rhel.sh` and `arch.sh` are always family files, so guard anything meant for that one distribution on `WORKBENCH_DISTRO_ID`. Exact-ID files need `core_api: ">=1.11 <2.0"`.

The [Core API reference](https://github.com/GingerGraham/workbench-core/blob/main/contracts/core-api.md) has the full tier rules.

Don't put a `dest:` on a `register.shell[]` entry. It isn't a supported field, and the validator rejects it. Workbench decides where registered files go, and keeps them inside your module's own directory. That's what makes `register:` safe for users to trust.

## Getters

A getter (`get-<domain>-functions`) lists the functions and aliases your module gives the user. Declare it in `register.getters[]` and don't write it yourself: workbench generates it.

```yaml
register:
  getters:
    - name: git
      function: get-git-functions
      label: "Git identity, project-context, and CLI-wiring helpers"
```

The generated getter lists every function and alias in your `register.shell[]` files under your `label`. It uses the same files the loader loads, so platform and distro files that don't apply to the host are left out. It works the same in bash and zsh, and under whatever name the user added your module with. A module that relies on it declares `core_api: ">=1.8 <2.0"`.

`function` must not be empty, must not start with `_`, and can only use `A-Z a-z 0-9 _ -`. Workbench skips any other entry with a warning.

A getter you write yourself still works, and wins over the generated one. If you keep one, don't use `BASH_SOURCE` inside the function to find your own files: zsh doesn't set it, so the getter prints `(none)` there.

## Defining aliases

Define every alias with `workbench_alias_define <name> <module> <value>`, never with a bare `alias`. It defines the alias only when the name is free, so your module never replaces an alias or function the user already has:

```bash
# before
alias gst="git status"
alias gitkeep='find . -type d -empty -exec touch {}/.gitkeep \;'

# after
workbench_alias_define gst git "git status"
workbench_alias_define gitkeep git 'find . -type d -empty -exec touch {}/.gitkeep \;'
```

`<module>` is your module's name; it appears in the warning the user sees when a name was already in use. Keep each value's original quoting, so it expands at the same time as before.

- A name is free when nothing uses it, when workbench defined it earlier in this shell (a reload refreshes it), or when an alias with the identical definition exists. It's taken when a function of that name exists or a different alias does. A command on `PATH` doesn't count.
- When a name is taken the call returns 1, defines nothing, and records the clash. The loader reports it once and `wb status` lists it. Don't rename your alias to dodge one: on that host the existing name is the user's.
- Put each call at the start of a line, in an `if` block, not after `&&`. The getter finds names only at the start of a line.
- It's a Core API function, available from the `core` tier on, so don't call it from an `env`-tier file. Declare `core_api: ">=1.10 <2.0"`.
- Aliases that a tool creates for itself (`eval "$(tool init)"`) can't go through the function; they're the tool's.

Why this matters: bash expands an alias when it reads a line, including the name in `name() {`. A bare alias breaks any file of the user's that later defines a function with the same name, with `syntax error near unexpected token '('`. The template's `tests/check-no-bare-alias.sh` fails on a bare `alias` definition; end a line with `# wb-allow-bare-alias` to allow one on purpose.

## Shipping overridable defaults (`overrides_src`)

If your module has a default a user might reasonably want to change, such as a theme name, a plugin list, or which of several tools it prefers, don't hardcode it in a file your module ships.

Your module's files live in its own snapshot directory, which is replaced on every update. A user who edits one of those files loses the edit at the next update.

Instead:

1. Read the setting from a variable with a default:

   ```bash
   # shell/omp.sh, tier: tools
   OMP_THEME="${OMP_THEME:-atomic}"
   ```

2. Declare an `overrides_src` in your manifest: a small, commented file containing the variables a user can uncomment to change.

   ```yaml
   overrides_src: shell/overrides.sh
   ```

   ```bash
   # shell/overrides.sh
   # Uncomment to change this module's defaults. This file is yours —
   # workbench-core deploys it once and never touches it again.

   # export OMP_THEME="jandedobbeleer"
   ```

Workbench copies this file once, to `~/.config/workbench/local/overrides/<your-module-name>.sh`, and never touches it again. It's loaded before your module's own shell files and before the user's `settings.sh`. So a value set there reaches your `${VAR:-default}` code, and a value the user sets in `settings.sh` still wins.

You don't choose where the file goes, and there's no `dest` field. It lands in the one directory the user's shell loads unconditionally, so workbench controls the path.

If you don't have a default worth exposing yet, leave `overrides_src` out. There's nothing to create now and nothing to migrate when you add one later.

### Letting users override a choice between tools (`WORKBENCH_OVERRIDE_<SCOPE>`)

A default like `OMP_THEME` is already overridable: anyone can set `OMP_THEME` before your file runs. It needs no special name.

A choice between tools is different. workbench-shell, for example, prefers oh-my-posh, then starship, then oh-my-zsh, decided by `command -v <tool>` checks rather than a variable, so there's nothing for a user to set.

If your module makes a choice like this and you want it overridable, name the variable `WORKBENCH_OVERRIDE_<SCOPE>` and check it at the top of every guard in the choice, before the `command -v` check:

```bash
# shell/starship.sh
command -v oh-my-posh &>/dev/null && [[ "${WORKBENCH_OVERRIDE_PROMPT_ENGINE:-}" != "starship" ]] && return 0
command -v starship &>/dev/null || return 0
```

Choosing `<SCOPE>`:

- If the thing you're overriding already has a name in the [Core API reference](https://github.com/GingerGraham/workbench-core/blob/main/contracts/core-api.md), reuse it without the `WORKBENCH_` prefix. The prompt engine is `WORKBENCH_PROMPT_ENGINE`, so its override is `WORKBENCH_OVERRIDE_PROMPT_ENGINE`.
- Otherwise, use `<MODULE>_<SETTING>`, for example `WORKBENCH_OVERRIDE_SHELL_ZSH_THEME`.

Don't rename a `${VAR:-default}` setting that already works to fit this pattern. Use `WORKBENCH_OVERRIDE_*` only for choices that have no other way to change them.

## Deploying files

You declare what your module provides. Workbench decides, on each machine, what happens to each file, keeps a record of what it wrote, and never throws away a change it didn't make. Don't write backup, overwrite-check, migration or uninstall logic in your module.

For each `deploy[]` entry:

- **Copied files.** Leave `lifecycle` unset (`managed`) for an opinionated default, such as a tmux config or a `starship.toml`. Users who haven't edited it get your improvements; users who have keep theirs and are told when yours changes. Use `seed` for a file meant to be edited from day one, and `generated` for a file nobody should edit.
- **Other places the tool reads.** If the tool reads its config from more than one place, list the others in `yield_to`. A user who already has one isn't given a second, and `wb files use` can move theirs aside cleanly if they choose yours.
- **Linked files** (`link`, `link_tree`) follow every release. If the tool writes into what you link, such as a lock file or a cache, each write holds that file at its current version until the user decides. Prefer copied files for a config directory the tool writes into.

Never write outside your own directory from a hook. If a hook would need to, for example to add an `Include` line or set a global git value, declare a layer instead (next section). If neither a layer nor a `deploy` entry fits, that's a gap in workbench: [raise it](https://github.com/GingerGraham/workbench-core/issues) rather than working around it.

## Layering config into a tool the user already uses

Most users already configure git, ssh, tmux and vim. For those, don't ship a whole file. Ship your settings as a file in your module, and declare a **layer**. Workbench adds one marked block to the user's own file that includes yours, placed so anything the user sets outside the block wins. Your updates reach users with no prompts, and removing the block undoes everything.

Use a layer when the tool can include another file and the user very likely has their own config already. Use a `deploy` entry for a tool that can't include other files (starship, direnv's `direnv.toml`), or for a file only your module uses.

```yaml
core_api: ">=1.6 <2.0"
layers:
  - tool: gitconfig
    src: files/gitconfig
```

```ini
# files/gitconfig
[init]
	defaultBranch = main
[push]
	autoSetupRemote = true
```

On a machine whose `~/.gitconfig` sets `init.defaultBranch = trunk`, that stays `trunk`. `push.autoSetupRemote` becomes `true`, because the user didn't set it.

The four layer types are `gitconfig`, `ssh_config`, `tmux.conf` and `vimrc`. The [manifest specification](https://github.com/GingerGraham/workbench-core/blob/main/contracts/manifest-spec.md) says where each one puts its block.

Rules:

- **`under` or `over`.** Leave `position` unset (`under`) for your own defaults, so the user's settings win. Use `over` only for content that records the user's *own* choices, made through your module's functions, which has to win over their global settings. workbench-git's per-project identities, created by `git-add-project`, are the example. Never use `over` to make one of your defaults stick.
- **Your layer file is replaced on every update.** Never tell users to edit it. Tell them to put their settings in their own file, outside the block, or to turn the block off: `wb files policy <module> <layer> skip`.
- **Never write the user's config file from a hook or a shell file.** Workbench owns the file; you own only what the block includes. A function the user runs that has to write there (`git config --global user.email ...`, say) calls `_wb_layers_settle <module>` afterwards, so workbench can move any block that has to stay last back to the end.
- **Moving away from lines an older hook wrote: `adopt`.** If an older version of your module's hook added lines to the user's file, list them in a file and name it in `adopt: [files/legacy/<name>]`. The first time the layer is applied, workbench backs the whole file up, removes those lines, and warns about anything that didn't match exactly. For `gitconfig`, each line is `<key> <value>`. For the others, the file is the exact block your hook wrote.
- **The include path is absolute**, and points through your module's `current` directory, so the block itself never changes between releases.

Users see and control layers with `wb files status`, `wb files diff`, `wb files use`, `wb files restore`, and `wb add <module> --skip-layer <id>`. See [Your config files](config-files.md).

## Declaring installers (`wb tools`)

List the files that hold your installers in `register.installers[]`. `src` is a path relative to your repository root, checked the same way as `register.shell[].src`.

```yaml
register:
  installers:
    - src: shell/installers.sh
```

Every top-level function in that file named `install-<name>` is offered by `wb tools list`, `wb tools install` and `wb tools upgrade` as `<name>`. The `install-` prefix is required: it's the only way workbench finds your function.

```sh
# shell/installers.sh
install-terraform() {
    # ... your own idempotency/version-checking logic here ...
}
```

Workbench finds `install-<name>` functions and runs the one the user asks for. It doesn't know how your tool is installed, checked or updated, and it never runs an installer unless told to:

- `wb tools install <name>` runs that one installer.
- `wb tools install all` lists every installer and asks for a `y` before running any.
- `wb tools upgrade` only runs an installer whose `installed-<name>` check (next section) says the tool is already installed.

**Making `install-<name>` safe to run again is your job.** Workbench calls your function and reports what it prints and returns. It doesn't track installed versions. Write it the way you'd write any script meant to run repeatedly: check what's already installed, and do nothing or upgrade accordingly.

If your installer unpacks a `.zip` download, `wb install` checks for `unzip` and reports it as an optional tool, but doesn't install it. Your function should check for it and install it, or ask the user to, if it's missing. `zip` is treated the same way.

`wb tools` only runs when the user asks. It never runs during background updates, and it's separate from `wb update`: `wb update` keeps your module up to date, and `wb tools` keeps the software your installers install up to date.

If two modules use the same name (both define `install-terraform`, say), `wb tools` warns once and uses the first module in alphabetical order. Pick a more specific name if you don't want to rely on that.

The names `all`, `list`, `install`, `upgrade` and `status` are reserved for `wb tools` itself. An `install-all` or `install-status` is left out with a one-time warning. Pick a different name.

### The AUR is opt-in (`WORKBENCH_ALLOW_AUR`)

An installer whose only Arch route is the Arch User Repository (`yay`, or `makepkg` on a cloned PKGBUILD) must check `WORKBENCH_ALLOW_AUR` first. AUR packages are unreviewed build scripts, run as the user and then installed as root. Without the opt-in, log the exact command for the user to run themselves and return 1:

```sh
if [[ "${WORKBENCH_ALLOW_AUR:-false}" != "true" ]]; then
    log_warn "1password is only in the AUR on Arch. Install it yourself: yay -S 1password"
    log_warn "(or set WORKBENCH_ALLOW_AUR=true in ~/.config/workbench/local/settings.sh)"
    return 1
fi
```

The user sets it in `~/.config/workbench/local/settings.sh`. Workbench only documents the setting; each module checks it.

## Reporting install status

Optional, but recommended. Define `installed-<name>` in the **same file** as `install-<name>`, with no manifest entry, so `wb tools list --status` and `wb tools upgrade` know whether your tool is present:

```sh
# shell/installers.sh
install-terraform() {
    # ... your own idempotency/version-checking logic here ...
}

installed-terraform() {
    command -v terraform &>/dev/null
}
```

**Exit 0 means installed. Exit 1 means not installed.** Anything else, including no `installed-<name>` at all, means "don't know", and `wb tools upgrade` never runs `install-<name>` for it. A wrong guess either way is worse than an honest "don't know". `wb tools install <name>` still works, because it never checks status.

**If you define `installed-<name>`, it must be right.** Workbench trusts its answer and acts on it without asking. A check that always returns 0, checks the wrong thing, or goes stale makes `wb tools upgrade` run your installer every time, believing it's refreshing something already there. If you're not sure your check is correct, don't define it.

Keep it cheap and free of side effects, typically one `command -v` or file test. It runs once per tool on every `wb tools list --status` and `wb tools upgrade`.

## Declaring function availability

**Required:** a public function or alias that can't work without an external tool declares an availability check, and the check says what it needs. Module CI fails when a getter lists any name under "module gave no reason".

Put declarations before any early `return` in the file. Declare a name that's only defined inside an `if command -v …` block too: listings read the file without running it.

Define `_<name>-available` in the **same file** as `<name>`, with no manifest entry. While it reports unavailable, `<name>` is moved out of the main list in `wb functions` and your getter:

```sh
# shell/aws.sh
aws-update() {
    install-aws
}

_aws-update-available() {
    command -v aws &>/dev/null
}
```

**Exit 0 means available. Exit 1 means unavailable.** No check at all means always available: most functions have nothing to check and shouldn't need one.

### Three ways to declare one

In order of preference:

**Several names share one simple check:** `_wb_declare_availability <command> <name> [<name> ...]`.

```sh
# shell/gpg.sh
_wb_declare_availability gh gpg-github-keys gpg-push-github
```

Listings show `gh` as what these names need, and add `install: wb tools install gh` when a module provides an installer named `gh`.

**Several names share an existing, more complex check:** `_wb_alias_availability [--needs <text>] [--install <tool>] <check-function> <name> [<name> ...]`. If you already have a loud preflight helper (a `_xxx_require_yyy` function, say), write a quiet twin that only returns true or false, have the loud one call it, and use the twin here rather than repeating the check:

```sh
# shell/disk-encryption.sh
_tpm_tools_present() {
    local cmd
    for cmd in "${_tpm_required_tools[@]}"; do
        command -v "${cmd}" &>/dev/null || return 1
    done
}
_wb_alias_availability _tpm_tools_present enroll-luks-tpm2 rotate-luks-key
```

- `--needs` is what listings print for these names. It's required: without it the names are still moved out of the main list, but under "module gave no reason", and module CI fails.
- `--install` is the `wb tools` name of the installer that provides what's needed. It's optional, and only goes with `--needs`.

`--needs` matters most when the check isn't a plain `command -v`, because the listing can't work out what it was looking for:

```sh
_wb_alias_availability --needs "yq v4 (mikefarah/yq)" --install yq \
    _git_yq_present git-add-project git-list-projects
```

**Anything else**, such as an OR of several tools or a one-off check: write `_<name>-available` yourself.

```sh
# shell/editors.sh
_open-workspace-available() {
    command -v code &>/dev/null || command -v code-insiders &>/dev/null
}
```

Then say what it needs with `_wb_availability_needs [--install <tool>] <needs-text> <name> [<name> ...]`. It doesn't define a check itself, so it works beside any of the three forms:

```sh
_open-workspace-available() {
    command -v code &>/dev/null || command -v code-insiders &>/dev/null
}
_wb_availability_needs "VS Code (code or code-insiders)" open-workspace
```

If your function already has its own loud preflight for the same tool, have the preflight call the same quiet check, rather than repeating `command -v`. One check, used by the function and every listing.

Check functions start with `_`, so they're never listed themselves.

### Keep checks cheap

A check must be a quick, local test: `command -v`, or a file test. Never probe hardware, an agent or the network. Auth status and similar belong in your function's own preflight.

`wb functions` stops any check that runs longer than `WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS` (1 second by default), names it, and treats it as unavailable.

If several checks really do need one expensive test, wrap it in `_wb_cache_bool <cache-key> -- <command...>` so it runs once per listing, not once per name:

```bash
_gpg-card-status-available() { _wb_cache_bool gpg-card-live -- gpg --card-status; }
_gpg-show-available()        { _wb_cache_bool gpg-card-live -- gpg --card-status; }
```

### What users see

A check changes what a listing shows as ready to use, never what's defined. A function that fails its check is still loaded and can still be called, and still runs its own preflight if it is.

When a listing moves names out of its main list, it shows them in a block directly underneath, before the aliases:

```
[INFO] Git functions:
get-git-functions  git-cleanup  git-projects-base  git-setup-identity  gwt  gwt-cd

[INFO] Git functions — available once tooling is installed:
  yq v4 (mikefarah/yq) — install: wb tools install yq
    git-add-project  git-add-project-cli  git-list-projects  git-remove-project
```

- Names are grouped by what they need: one heading for each distinct text, with the names underneath.
- `— install: wb tools install <tool>` only appears when an installer by that name really exists.
- A check with no reason given is shown under "module gave no reason (predicate reports unavailable)", and fails module CI. Add one with `_wb_availability_needs` or `--needs`.
- A check stopped by the timeout is shown under "availability check timed out (> Ns)".
- If every name is available, there's no block. If none are, the main list reads `(none)` and the block follows.
- Checks run again on every listing, so a user who installs the tool and lists again in the same shell sees the function as available. The exception is a check wrapped in `_wb_cache_bool`, which keeps its answer for the life of the shell.

`wb functions --compact`, which the `WORKBENCH_SHOW_FUNCTIONS` startup list uses, replaces each block with one line, such as `7 functions need tooling you don't have: yq (7), gh (2) — run 'wb functions' for details`. Your getter is never compact. `wb functions --all`, or `WORKBENCH_FUNCTIONS_SHOW_ALL=true` in front of any getter, lists everything in the main list with no block.

All of this works automatically once you declare checks. `--needs` and `_wb_availability_needs` only make it more useful.

## Writing for bash and zsh

Every `register.shell` file is loaded into zsh as well as bash, and module CI tests both. In zsh:

- an unquoted `${var}` doesn't split into words;
- arrays start at 1;
- `shopt`, `read -a` and `compgen` don't exist, so use them only inside a bash-only branch;
- `${BASH_SOURCE[0]}` is empty inside a function, so work out paths at the top level of the file, as `${BASH_SOURCE[0]:-$0}`;
- a glob that matches nothing is an error, not a literal, so use `find` or check for matches first.

Installer files are never loaded into the user's shell. `wb tools` runs them in bash, with `WORKBENCH_SHELL=bash`, whatever the user's shell is.

Shell files must also run in bash 3.2, which macOS ships: no associative arrays, no `${var,,}` or `${var^^}`, and no `mapfile`.

## Keeping shell start clean

A new shell should start quietly, with or without the tools your module wraps. Module CI checks this with only workbench and your module added:

- **Don't call `install-*` functions from shell files**, in code or in a message. Installer files aren't loaded into the user's shell, so the call fails, and a message would point at a command that doesn't exist. Tell users to run `wb tools install <name>` (or `wb tools upgrade <name>`) instead.
- **Nothing on stderr** when interactive bash or zsh starts, both with a bare `PATH` (workbench's required tools and basic utilities only) and with a normal one. Guard every call to an optional tool:

  ```bash
  command -v direnv &>/dev/null && eval "$(direnv hook bash)"
  ```

- **Only use Core API functions your `core_api` floor provides.**
- **Every getter exits 0** in both shells with a bare `PATH`, and lists at least one of your own function or alias names, as ready or as needing a tool. A module that registers no names only needs its `[INFO]` heading.
- **Every check says what it needs.** No getter lists a name under "module gave no reason".

## Publishing module info and docs

Optional, but recommended. `wb module info <name>` and `wb module docs <name>` let users find out what your module is and does without leaving the shell. Neither needs `core_api:`, so they work with the simplest manifest.

**`info`**: add a one-line `info.description` to your manifest.

```yaml
info:
  description: "Git configuration, aliases, and credential helpers"
```

Everything else `wb module info` shows comes from what workbench already knows: the repository, what it follows, the commit. Without a description, users see a "not published yet" line pointing at your repository. Keep it to one line; anything longer belongs in your docs.

**`docs`**: add a `HELP.md` to your repository root, and `wb module docs <name>` prints it in full. There's no manifest field. Without `HELP.md`, your `README.md` is used. With neither, users see a pointer to your repository. No other filenames are checked, so name it exactly `HELP.md` if you want something different from your README.

## Normalising the CPU architecture name

Workbench sets `WORKBENCH_ARCH` to the raw output of `uname -m`, such as `x86_64`, `aarch64` or `arm64`. It doesn't translate it, because tools disagree on names: some want Go-style (`amd64`, `arm64`), some want uname-style (`x86_64`, `aarch64`), and a few care about 32-bit (`386`, `arm`). Use whichever snippet matches the tool you're installing, inside your installer function:

```sh
# Go-style (amd64/arm64) — common for tools distributed as Go binaries
case "${WORKBENCH_ARCH}" in
    x86_64)  _arch="amd64" ;;
    aarch64|arm64) _arch="arm64" ;;
    i386|i686) _arch="386" ;;
    armv7l)  _arch="arm" ;;
    *)       _arch="${WORKBENCH_ARCH}" ;;
esac
```

```sh
# uname-style (x86_64/aarch64) — common for tools that ship their own
# uname-based detection already and just need normalising to it
case "${WORKBENCH_ARCH}" in
    amd64)  _arch="x86_64" ;;
    arm64)  _arch="aarch64" ;;
    *)      _arch="${WORKBENCH_ARCH}" ;;
esac
```

## Hooks

`hooks.post_deploy` runs after your module is updated. It runs only if your manifest declares it **and** the user added your module with `--allow-hooks` (`wb add <name> <url> --allow-hooks`). Otherwise it quietly doesn't run; that's not an error.

```yaml
hooks:
  post_deploy:
    command: ["hooks/post-deploy.sh"]
    run_on: changed   # changed (default) | always | initial
    timeout: 60
```

Your hook runs in your module's `current` directory, which is read-only. Write caches and build output under `$XDG_CACHE_HOME` or `$XDG_DATA_HOME`, not there. Your hook runs with these environment variables:

| Variable | Value |
|---|---|
| `WORKBENCH_MODULE_NAME` | Your module's name, as the user added it. |
| `WORKBENCH_MODULE_DIR` | Your module's `current` directory. |
| `WORKBENCH_SYNC_REASON` | `add`, `track`, `manual` or `scheduled`. |

Exit non-zero on failure. The failure is logged, but never fails the update of your module or any other.

A hook must not write the user's files. See [Deploying files](#deploying-files).

**A new or changed hook waits for the user's approval.** Background updates only run a hook at a version the user has already approved on that machine. A hook that's new or has changed is left waiting until the user next runs `wb update`, `wb add` or `wb track` in a terminal, which asks. So if you change a `run_on: changed` hook in a release, don't expect it to run everywhere straight away.

## Dev-mode disk duplication

If you point your own module at your working branch (`wb dev <name>`, or `wb track <name> --branch <your-branch>`), you'll have **two copies** of your repository's files on disk:

- your own clone, wherever you keep it, which you edit and push as normal;
- a separate copy that workbench fetches from the branch, under `~/.local/share/workbench/modules/<name>/snapshots/`, refreshed on its own schedule.

**That's expected, not a bug.** Workbench never touches your clone. Following a branch means "fetch this branch the way a user's machine would", which has to be a separate copy. Your changes reach workbench's copy when you push them.

## Testing your manifest

From a checkout of [workbench-core](https://github.com/GingerGraham/workbench-core), run the validator against your manifest:

```sh
lib/manifest/validate.sh path/to/workbench.yml
```

It needs [mikefarah/yq v4](https://github.com/mikefarah/yq#install), only on the machine you develop on. Run it before pushing a manifest change, or let your module's CI run it.

### CI

A module made from the template already has CI. Its `.github/workflows/ci.yml` calls workbench-core's shared module workflow:

```yaml
name: CI
on:
  pull_request:
    branches: [main]
  workflow_dispatch:
    inputs:
      core_ref:
        description: "workbench-core ref to test against"
        required: false

jobs:
  module-ci:
    uses: GingerGraham/workbench-core/.github/workflows/module-ci.yml@main
    with:
      module_name: <your-module's-catalog-name>   # e.g. git, gpg, cloud...
      core_ref: ${{ inputs.core_ref }}
```

On every pull request it runs:

- **shellcheck** over `shell/**/*.sh` and `hooks/*.sh`.
- **The manifest validator.**
- **Your own tests**: any `tests/check-*.sh` files, on Linux and macOS.
- **Add to core.** Does this branch add correctly to workbench? It runs real `wb add`, `wb track --branch <your-PR-branch>` and `wb update` against your module's own repository (a fork's, for a pull request from a fork), in a scratch home directory. It then checks that every `deploy:` destination landed, every getter appears in `wb functions`, every installer appears in `wb tools list`, a second `wb update` changes nothing, and `wb remove` removes the module cleanly. It runs with `--allow-hooks`, so your hook runs for real.
- **Clean shell start**: the rules in [Keeping shell start clean](#keeping-shell-start-clean), in bash and zsh.

By default it tests against workbench-core's latest release, not `main`. To test against a core pull request that hasn't merged yet, run the workflow by hand and set `core_ref` to that branch.

### Checks of your own

If the shared checks can't test something specific to your module, such as what your hook is meant to do, add an executable `tests/check-add-to-core.sh`. The shared check runs it after adding your module, with `WB`, `MODULE_NAME`, `MODULE_URL`, `MODULE_BRANCH` and `MODULE_ROOT` set.

A test that needs a machine prepared *before* `wb add`, such as a user's own `~/.gitconfig` to prove your layer leaves it intact, creates its own scratch `HOME`, `XDG_CONFIG_HOME` and `XDG_DATA_HOME`, prepares them, then runs the same steps as the shared check:

```bash
"$WB" add "$MODULE_NAME" "$MODULE_URL"
"$WB" track "$MODULE_NAME" --branch "$MODULE_BRANCH"
"$WB" update "$MODULE_NAME"
```
