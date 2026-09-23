#!/usr/bin/env bash
# lib/loader.sh — multi-root shell configuration loader.
#
# The single entry point sourced by a stub in ~/.bashrc and ~/.zshrc
# (rendered by `wb install`/`wb apply` — see ansible/roles/module_sync).
# Rewritten from workbench-precursor's shell/config/loader.sh (which assumed
# a single SHELL_CONFIG_DIR root) to walk every registered, sync-enabled
# module's state directory instead (docs/architecture.md §3) — core is "module
# zero" here and goes through the exact same mechanism as any other module;
# there is no hardcoded module name or special first pass for core anywhere
# in this file.
#
# Bash 3.2 / zsh compatible throughout, deliberately: no `shopt -s
# globstar` (the donor's get-functions used this; it is a confirmed bash-4+
# construct that is a no-op or hard error on bash 3.2 — see
# tests/check-loader-multi-root.sh, which exercises this file under an
# actual bash 3.2 binary when one is available), no declare -A,
# mapfile/readarray, ${var,,}/${var^^}, or declare -n.

# ── Defensive bash state reset ───────────────────────────────────────────────
if [[ -n "${BASH_VERSION:-}" ]]; then
    set +o posix          2>/dev/null || true
    set +o noglob         2>/dev/null || true
    unset POSIXLY_CORRECT 2>/dev/null || true
fi

# ── Snapshot pre-existing prompt ownership ────────────────────────────────
# Captured before any tier content (including a workbench module's own
# prompt-owning tier) runs, so the fallback block further down can tell
# "nothing has claimed the prompt yet" apart from "the rc file's own
# pre-stub content (oh-my-zsh, p10k, starship, anything not
# workbench-aware) already claimed it" — the same hook points
# docs/decisions-log.md D50 already treats as the prompt-ownership
# contract (bash PROMPT_COMMAND / zsh precmd_functions), just read here
# before workbench has touched either. Deliberately not keyed on raw
# PS1/PROMPT — those are frequently already non-empty from a distro's own
# /etc/bashrc (confirmed on Fedora) regardless of any user customisation,
# and keying on that would disable the fallback for the common case it
# exists to serve. Known limitation: a bare custom PS1 with no prompt
# manager behind it is not caught by this — see docs/decisions-log.md D64.
_WB_LOADER_PROMPT_PRECLAIMED=false
if [[ -n "${BASH_VERSION:-}" && -n "${PROMPT_COMMAND:-}" ]]; then
    _WB_LOADER_PROMPT_PRECLAIMED=true
elif [[ -n "${ZSH_VERSION:-}" && ${#precmd_functions[@]} -gt 0 ]]; then
    _WB_LOADER_PROMPT_PRECLAIMED=true
fi

# ── Ensure ~/.local/bin is on PATH ────────────────────────────────────────
# Some distros only add this conditionally in their default .bashrc/.zshrc,
# gated on the directory existing at rc-parse time — not guaranteed the
# first time `wb install` creates ~/.local/bin/wb (bin/wb's
# _wb_link_cli_bin). Absent entirely on stock macOS zsh. Guaranteed here
# instead, every shell start, independent of core even being registered.
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *)
        # A plain "${HOME}/.local/bin:${PATH}" would leave a trailing colon
        # when PATH is empty/unset — an empty PATH element that many shells
        # treat as the current directory (flagged in PR review).
        if [[ -z "${PATH:-}" ]]; then
            PATH="${HOME}/.local/bin"
        else
            PATH="${HOME}/.local/bin:${PATH}"
        fi
        ;;
esac
export PATH

# ── Fallback logging (before any module's log.sh, including core's own, is
#    guaranteed sourced yet) ──────────────────────────────────────────────
if ! command -v log_info &>/dev/null; then
    log_info()  { printf '[INFO]  %s\n' "$*" >&2; }
fi
if ! command -v log_warn &>/dev/null; then
    log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
fi
if ! command -v log_error &>/dev/null; then
    log_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi
if ! command -v log_debug &>/dev/null; then
    log_debug() { [[ "${WORKBENCH_DEBUG:-false}" == "true" ]] && printf '[DEBUG] %s\n' "$*" >&2; return 0; }
fi

# ── Locate our own lib/ root (this file's directory) ─────────────────────────
_wb_loader_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# WORKBENCH_LOADER_PATH (docs/decisions-log.md D39) — this file's own full
# path, exported so the `wb` shell-function wrapper defined near the
# bottom of this file (and its `wb reload` pseudo-command) can re-source
# it without recomputing the path `_wb_write_rc_stub`'s rc-stub line
# already embeds, from a shell where `_wb_loader_lib_dir` itself may since
# have gone out of scope (it's unset at the end of every source pass,
# below).
export WORKBENCH_LOADER_PATH="${_wb_loader_lib_dir}/loader.sh"

# shellcheck source=lib/sync/state.sh
[[ -f "${_wb_loader_lib_dir}/sync/state.sh" ]] && source "${_wb_loader_lib_dir}/sync/state.sh"

# No explicit source of core/version.sh here on purpose — that would be
# exactly the kind of hardcoded "core" special-case this file must never
# have (principle 4, tests/check-loader-multi-root.sh's own check for it).
# lib/core/version.sh is registered like any other core-tier content
# (.dotfiles-sync.yml) and reaches this process the same generic way
# functions.sh already does, via the tier-sourcing loop below — so the
# registration/debug-log lines wait until after that loop, where
# _workbench_register_script_version is available if core's own tier loaded
# at all (silently absent otherwise, e.g. a synthetic test with no core
# module registered — no different from any other module's content). See
# the actual registration/debug-log calls after the tier loop below —
# placing them here instead, before core's own tier has been sourced,
# would make _workbench_register_script_version unavailable and the
# registration a silent no-op almost every real run.

# ── OS / WSL / Distro / Shell / Arch detection ────────────────────────────────
# Duplicated minimally here (rather than sourced from core's own
# functions.sh) because core's functions.sh is itself only reachable via
# module enumeration below — this is the one piece of detection that has to
# exist before any module, core included, has been located and sourced.
# _workbench_detect_platform() (lib/core/functions.sh) is idempotent and
# re-runs safely once core's own register.list is processed, without
# re-detecting (see WORKBENCH_PLATFORM_DETECTED guard there).
_raw_os="$(uname -s)"
case "${_raw_os}" in
    Linux)  WORKBENCH_OS="Linux" ;;
    Darwin) WORKBENCH_OS="Mac"   ;;
    *)      WORKBENCH_OS="Linux" ;;
esac
export WORKBENCH_OS
unset _raw_os

if [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
    WORKBENCH_WSL="true"
else
    WORKBENCH_WSL="false"
fi
export WORKBENCH_WSL

if [[ -n "${ZSH_VERSION:-}" ]]; then
    WORKBENCH_SHELL="zsh"
elif [[ -n "${BASH_VERSION:-}" ]]; then
    WORKBENCH_SHELL="bash"
else
    WORKBENCH_SHELL="sh"
fi
export WORKBENCH_SHELL

if [[ "${WORKBENCH_OS}" == "Linux" && -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    _distro_id="$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")"
    # shellcheck disable=SC1091
    _distro_id_like="$(. /etc/os-release 2>/dev/null && echo "${ID_LIKE:-}")"
    case "${_distro_id}" in
        fedora|rhel|centos|rocky|almalinux) WORKBENCH_DISTRO="rhel" ;;
        ubuntu|debian|linuxmint|pop)        WORKBENCH_DISTRO="debian" ;;
        opensuse*|sles)                     WORKBENCH_DISTRO="suse" ;;
        manjaro|arch|endeavouros|garuda)    WORKBENCH_DISTRO="arch" ;;
        *)
            case "${_distro_id_like}" in
                *rhel*|*fedora*|*centos*) WORKBENCH_DISTRO="rhel"   ;;
                *debian*|*ubuntu*)        WORKBENCH_DISTRO="debian" ;;
                *suse*)                   WORKBENCH_DISTRO="suse"   ;;
                *arch*)                   WORKBENCH_DISTRO="arch"   ;;
                *)                        WORKBENCH_DISTRO="unknown" ;;
            esac
            ;;
    esac
    unset _distro_id _distro_id_like
else
    WORKBENCH_DISTRO="unknown"
fi
export WORKBENCH_DISTRO

WORKBENCH_ARCH="$(uname -m)"
export WORKBENCH_ARCH
WORKBENCH_PLATFORM_DETECTED="true"
export WORKBENCH_PLATFORM_DETECTED

# _wb_loader_source_sh_files_once <dir> <stamp-file> [exclude-basename]
# Sources every *.sh file directly in <dir> (nullglob-safe, no matches is a
# silent no-op), skipping [exclude-basename] if given. Each file gets a
# `bash -n` syntax smoke-test only on first sight or after it changes
# (tracked via <stamp-file>, `-nt` being a builtin test in both bash and
# zsh) — a failing file is skipped and warned about, and the stamp is
# withheld so it's re-checked (and re-warned) every start until fixed.
#
# Defined here, ahead of its first call site below (module-shipped
# overrides) rather than down by its other two call sites (the "other
# local/*.sh" pass and WORKBENCH_USER_EXT_DIR, further down this file) —
# bash requires a function to be defined before it's called, and this one
# now has to run before settings.sh's own early pass, which is sourced
# directly rather than through this helper (docs/decisions-log.md D48). One
# definition, three call sites total, never duplicated.
_wb_loader_source_sh_files_once() {
    local dir="$1" stamp="$2" exclude="${3:-}"
    local cache_dir dirty=false f base

    [[ -d "${dir}" ]] || return 0
    cache_dir="$(dirname "${stamp}")"

    if [[ -n "${ZSH_VERSION:-}" ]]; then
        setopt nullglob
    else
        shopt -s nullglob
    fi
    local files=("${dir}"/*.sh)
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        unsetopt nullglob
    else
        shopt -u nullglob
    fi

    for f in "${files[@]}"; do
        [[ -f "${f}" ]] || continue
        base="$(basename "${f}")"
        [[ -n "${exclude}" && "${base}" == "${exclude}" ]] && continue
        if [[ ! -f "${stamp}" ]] || [[ "${f}" -nt "${stamp}" ]]; then
            if ! bash -n "${f}" 2>/dev/null; then
                log_warn "loader: ${f} failed syntax check (bash -n) — skipping"
                dirty=true
                continue
            fi
        fi
        # shellcheck disable=SC1090
        source "${f}"
    done

    if [[ "${dirty}" == "false" ]]; then
        [[ -d "${cache_dir}" ]] || mkdir -p "${cache_dir}" 2>/dev/null
        : > "${stamp}"
    fi
}

# ── Local overrides directory (docs/decisions-log.md D22) ───────────────────────
# Machine-local, outside every module's own tree.
# ${XDG_CONFIG_HOME:-~/.config}/workbench/local/ holds `settings.sh` — the
# reserved-name direct successor to the old single-file `90-local.sh`,
# keeping exactly its two-pass semantics: sourced first (so flags it sets
# gate later tiers) and again at the very end (so it wins over anything a
# later tier also touches) — plus any number of other user-authored `*.sh`
# files, sourced once, together, filename-sorted, immediately after
# settings.sh's final pass (see below).
#
# Sourced BEFORE the "Behaviour flags" block just below, deliberately — a
# flag like WORKBENCH_PLAIN_SHELL set only in settings.sh (never exported as
# a real environment variable ahead of time) must already be a real shell
# variable by the time that block's own `${WORKBENCH_PLAIN_SHELL:-false}`
# default-and-forcing logic runs, or "settings.sh's early pass gates later
# tiers" — the documented contract this file has always claimed — would be
# true for tiers/the prompt fallback but silently false for
# WORKBENCH_SHOW_FUNCTIONS specifically (caught by
# tests/check-local-overrides.sh).
WORKBENCH_LOCAL_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/workbench/local"
WORKBENCH_LOCAL_ENV="${WORKBENCH_LOCAL_DIR}/settings.sh"

# ── Module-shipped overrides (docs/decisions-log.md D48) ────────────────────────
# ${WORKBENCH_LOCAL_DIR}/overrides/<module-name>.sh — one per module,
# deployed once by the sync engine from that module's manifest-declared
# `overrides_src`, never touched again by the engine once it exists (see
# contracts/manifest-spec.md's overrides_src section). Sourced here,
# BEFORE settings.sh's own early pass just below, so:
#   - a variable a module's opinionated default sets here is already a
#     real shell variable by the time that module's own tier content
#     runs further down this file — the same way settings.sh's early
#     pass already works for a user's own settings, ${VAR:-default}-style
#     tier code picks it up either way;
#   - a user's settings.sh, sourced immediately after this, still wins if
#     it sets the same variable — a module's shipped opinion is always
#     the lowest-precedence layer, never the last word.
# Same flat, unvalidated, filename-sorted, syntax-smoke-tested sourcing as
# the "other local/*.sh files" pass further down this file — reuses the
# identical helper just above, just a different directory and a separate
# stamp file so the two passes' change-detection never collide.
WORKBENCH_OVERRIDES_DIR="${WORKBENCH_LOCAL_DIR}/overrides"
_wb_loader_source_sh_files_once \
    "${WORKBENCH_OVERRIDES_DIR}" \
    "${XDG_CACHE_HOME:-${HOME}/.cache}/workbench/local-overrides.stamp"

# shellcheck disable=SC1090
[[ -f "${WORKBENCH_LOCAL_ENV}" ]] && source "${WORKBENCH_LOCAL_ENV}"

# ── Behaviour flags ───────────────────────────────────────────────────────────
WORKBENCH_SHOW_FUNCTIONS="${WORKBENCH_SHOW_FUNCTIONS:-false}"
WORKBENCH_USER_EXT_DIR="${WORKBENCH_USER_EXT_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/workbench/user}"
WORKBENCH_USER_EXT_ENABLED="${WORKBENCH_USER_EXT_ENABLED:-true}"

WORKBENCH_PLAIN_SHELL="${WORKBENCH_PLAIN_SHELL:-false}"
if [[ "${WORKBENCH_PLAIN_SHELL}" == "true" ]]; then
    export NO_COLOR=1
    WORKBENCH_SHOW_FUNCTIONS=false
fi

# ── register.list tier resolution ─────────────────────────────────────────────
# Six tiers, sourced in this fixed order for every loadable module — the
# same order workbench-precursor's loader.sh already enforced, just no
# longer scoped to a single root.
_WB_LOADER_TIERS="env core tools platform distro lazy"

# _wb_loader_should_source_by_name <tier> <basename-without-.sh>
# Shared with bin/wb's `wb functions` (lib/loader-select.sh) so both
# ask the identical question the identical way — no second, drifting copy.
# shellcheck source=lib/loader-select.sh
source "${_wb_loader_lib_dir}/loader-select.sh"

# _wb_loader_source_tier <tier>
# Sources every registered file declared for <tier>, across every loadable
# module, sorted by module name then by the file's own basename (so a
# module's own numeric-prefix convention, e.g. env/00-core.sh, env/10-x.sh,
# still governs intra-module ordering — exactly as workbench-precursor's
# env/ tier did within its single root).
_wb_loader_source_tier() {
    local tier="$1"
    local name reglist filepath filetier base

    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        reglist="$(workbench_module_dir "${name}")/register.list"
        [[ -f "${reglist}" ]] || continue

        while IFS='|' read -r filepath filetier; do
            [[ -z "${filepath}" ]] && continue
            [[ "${filetier}" == "${tier}" ]] || continue
            [[ -f "${filepath}" ]] || continue
            base="$(basename "${filepath}")"
            base="${base%.sh}"
            _wb_loader_should_source_by_name "${tier}" "${base}" || continue
            # shellcheck disable=SC1090
            source "${filepath}"
        done < <(sort -t'|' -k1,1 "${reglist}")
    done < <(workbench_list_loadable_modules)
}

# ── WORKBENCH_TRACK_<MODULE> (docs/architecture.md §9.5/D7) ────────────────────────
# Derived, read-only, exported for every registered module (core included),
# regardless of its sync-enabled state — sourced from sync.conf, never
# written back. <MODULE> is the registration name, uppercased via `tr`
# (bash 3.2 has no ${var^^}) with '-' folded to '_'.
if command -v workbench_list_registered_modules &>/dev/null; then
    while IFS= read -r _wb_track_name; do
        [[ -z "${_wb_track_name}" ]] && continue
        _wb_track_mode="$(workbench_module_conf_get "${_wb_track_name}" TRACK_MODE latest)"
        _wb_track_ref="$(workbench_module_conf_get "${_wb_track_name}" TRACK_REF "")"
        _wb_track_var="WORKBENCH_TRACK_$(printf '%s' "${_wb_track_name}" | tr '[:lower:]-' '[:upper:]_')"
        if [[ -n "${_wb_track_ref}" ]]; then
            export "${_wb_track_var}=${_wb_track_mode}:${_wb_track_ref}"
        else
            export "${_wb_track_var}=${_wb_track_mode}"
        fi
    done < <(workbench_list_registered_modules)
    unset _wb_track_name _wb_track_mode _wb_track_ref _wb_track_var
fi

# ── Prompt-engine reset, before the tier loop runs (docs/decisions-log.md
#    D50) ────────────────────────────────────────────────────────────────
# Re-sourcing this file in an already-running shell — 'source ~/.bashrc',
# or the wb() wrapper's own auto-reload after a state-changing command —
# is not a new process, so anything a previously-elected prompt engine
# hooked into the shell to render itself (bash's PROMPT_COMMAND, zsh's
# precmd_functions) is still live from the last run. A module switching
# which engine it elects (workbench-shell's WORKBENCH_OVERRIDE_PROMPT_ENGINE,
# docs/decisions-log.md D48, is the motivating case) correctly re-runs its own init, but
# nothing tears down the *previous* engine's hook first — well-behaved
# prompt tools preserve whatever PROMPT_COMMAND already contains rather
# than overwriting it (so they can coexist with unrelated tools), which
# is exactly wrong the moment one is meant to replace another. Confirmed
# live: the election recomputes correctly (WORKBENCH_PROMPT_ENGINE
# flips), but the visible prompt does not, until a genuinely new shell
# process starts.
#
# Cleared here, before any tier content (including a prompt-owning
# module's) runs, so every reload gives whichever engine wins a clean
# slate — the same state a brand-new shell would have. Only fires when
# WORKBENCH_PROMPT_SET was already true, i.e. only on an actual reload
# where we know for certain this loader itself is what last touched
# PROMPT_COMMAND/precmd_functions — never on a genuinely first load,
# where either could hold a user's own pre-stub customisation that has
# nothing to do with prompt-engine election and must not be wiped.
# bash's PROMPT_COMMAND is unset outright, not just blanked
# (PROMPT_COMMAND="") — bash 5.1+ treats it as an array internally, and
# an empty-string assignment does not reliably clear every element.
# zsh's precmd_functions is reset the same way.
#
# Trade-off, deliberate: if a module appends to PROMPT_COMMAND/
# precmd_functions for its own unrelated purposes from within its tier
# content on run N, and WORKBENCH_PROMPT_SET happens to be set at that
# point, run N+1's reset clears that too — but the same tier content
# re-runs on every reload regardless, so it's re-added, not lost.
# Genuinely external customisation (raw shell rc content *above* this
# loader's own stub line) is only at risk if it predates the first ever
# WORKBENCH_PROMPT_SET=true in this shell's lifetime, which this
# condition already protects.
if [[ -n "${WORKBENCH_PROMPT_SET:-}" ]]; then
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        # shellcheck disable=SC2034
        precmd_functions=()
    else
        unset PROMPT_COMMAND
    fi
fi
unset WORKBENCH_PROMPT_SET WORKBENCH_PROMPT_ENGINE

if command -v workbench_list_loadable_modules &>/dev/null; then
    for _wb_tier in ${_WB_LOADER_TIERS}; do
        _wb_loader_source_tier "${_wb_tier}"
    done
    unset _wb_tier
else
    log_warn "loader: lib/sync/state.sh not found — no modules were loaded (core itself may not be registered yet; run 'wb install')"
fi

# Script-version registration + hot-path version logging (bootstrap-fix
# brief §5.2/§5.3), debug-gated by the same WORKBENCH_DEBUG flag log_debug
# already uses above. Placed after the tier loop, not before: both
# _workbench_register_script_version and _workbench_release_version reach
# this shell the same generic way any other core-tier content does
# (lib/core/version.sh via register.list), so neither is available until
# that content has actually been sourced.
# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/loader.sh" "0.4.2" || true
# Gated on WORKBENCH_DEBUG explicitly, before ever calling
# _workbench_release_version — not just left to log_debug's own internal
# gate. Bash evaluates a command's arguments (the $(...) substitution)
# before the command (log_debug) itself runs, so `log_debug
# "...$(_workbench_release_version)..."` would fork a subshell and exec
# `head` on the VERSION file on *every* shell start regardless of the flag,
# silently contradicting this being debug-gated at all.
if [[ "${WORKBENCH_DEBUG:-false}" == "true" ]] && command -v _workbench_release_version &>/dev/null; then
    log_debug "loader: workbench-core release $(_workbench_release_version), lib/loader.sh v0.1.0"
fi

# ── Prompt fallback ────────────────────────────────────────────────────────
# Core provides only a bare, functional default — no opinionated prompt-
# manager election chain (starship/oh-my-posh/oh-my-zsh live in
# workbench-shell, Wave C). Any module wanting to manage the prompt itself
# should set WORKBENCH_PROMPT_SET=true after doing so, from one of its own
# registered tier files — this fallback is skipped when that's set, rather
# than the loader hardcoding a list of known prompt tools to check for.
if [[ "${WORKBENCH_PLAIN_SHELL}" == "true" ]]; then
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        # shellcheck disable=SC2034
        PROMPT='%n@%m:%~%# '
    else
        PS1='\u@\h:\w\$ '
    fi
    export WORKBENCH_PROMPT_ENGINE="plain"
elif [[ -z "${WORKBENCH_PROMPT_SET:-}" && "${_WB_LOADER_PROMPT_PRECLAIMED}" == "false" ]]; then
    if [[ -n "${BASH_VERSION:-}" ]]; then
        if [[ -x /usr/bin/tput ]] && tput setaf 1 &>/dev/null; then
            PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
        else
            PS1='\u@\h:\w\$ '
        fi
        case "${TERM:-}" in
            xterm*|rxvt*) PS1="\[\e]0;\u@\h: \w\a\]${PS1}" ;;
        esac
    fi
    export WORKBENCH_PROMPT_ENGINE="fallback"
fi
unset _WB_LOADER_PROMPT_PRECLAIMED

# ── Local overrides, second pass (always wins) ────────────────────────────────
# shellcheck disable=SC1090
[[ -f "${WORKBENCH_LOCAL_ENV}" ]] && source "${WORKBENCH_LOCAL_ENV}"

# ── Other local/*.sh files (genuinely open, user-owned content) ───────────────
# Everything in WORKBENCH_LOCAL_DIR except settings.sh itself — functions,
# aliases, whatever — sourced once, together, filename-sorted, immediately
# after settings.sh's final pass. Deliberately flat, not trying to
# reproduce the six loader tiers for local content (docs/decisions-log.md
# D22): this is the right level of complexity for something the loader
# can't validate the shape of the way it can a module's manifest.
_wb_loader_source_sh_files_once \
    "${WORKBENCH_LOCAL_DIR}" \
    "${XDG_CACHE_HOME:-${HOME}/.cache}/workbench/local-other.stamp" \
    "$(basename "${WORKBENCH_LOCAL_ENV}")"

# ── User extensions (always last of the content tiers) ────────────────────────
# Same shadowing/syntax-smoke-test semantics as workbench-precursor's
# DOTFILES_USER_EXT_DIR, via the shared helper above. Stays conceptually
# distinct from the local-overrides directory (hand-authored "pseudo-
# module" extensions vs. personal overrides) and sourced after it, so
# WORKBENCH_USER_EXT_DIR remains the true last word of every content tier —
# unchanged from before this directory existed.
if [[ "${WORKBENCH_USER_EXT_ENABLED}" == "true" ]]; then
    _wb_loader_source_sh_files_once \
        "${WORKBENCH_USER_EXT_DIR}" \
        "${XDG_CACHE_HOME:-${HOME}/.cache}/workbench/user-ext.stamp"
fi

# ── Interactive `wb` wrapper: auto-reload after state-changing commands ──────
# (docs/decisions-log.md D39)
#
# A subprocess (the real `bin/wb` binary) cannot alter its parent shell's
# functions/environment — Unix process semantics, not a workbench bug (see
# the debugging session this decision is built on: register.list was
# already correctly rendered, `wb functions` already listed the content
# correctly — it just was never sourced into the *already-open* shell that
# ran the update). The only way `wb apply`/`wb update` (etc.) can make
# freshly-registered content callable in the same shell the user just ran
# them from, rather than only in the next new shell, is a shell function
# of the same name that runs the real binary via `command` and then
# re-sources this file itself in the caller's own shell — the same
# "activate" pattern tools like nvm/rbenv/direnv already use for exactly
# this constraint.
#
# `command wb` bypasses this function (and any alias), reaching
# ~/.local/bin/wb → core's real bin/wb, so there is no recursion.
#
# Every subcommand that can change what's registered/loadable reloads
# unconditionally afterwards — deliberately not conditioned on "did
# anything actually change" (same reasoning as D21's unconditional,
# idempotent register.list render: re-sourcing this file is already
# idempotent by design, so a needless reload after a genuine no-op update
# is a cheap no-op itself, not a bug worth guarding against). The handful
# of purely-informational subcommands are excluded below since reloading
# after them would be pointless, not because it would be unsafe — any
# future subcommand not in that list defaults to reloading, which is the
# safe direction to default in (a missed addition here just costs one
# harmless extra reload, not a silently-stale shell again).
#
# `wb reload` itself is a pseudo-command that only exists as this function
# — it is never forwarded to the real binary (bin/wb's own `reload)` case
# exists only to explain that, for anyone who reaches it before this
# wrapper is in scope). It covers the one case the wrapper above doesn't:
# content that changed via the background scheduled-sync timer (`wb sync
# run-if-due`), not something the user ran by hand in this shell.
wb() {
    if [[ "${1:-}" == "reload" ]]; then
        # -h/--help still needs the real binary's help text (bin/wb's own
        # central help interception), not a reload — and any other extra
        # argument is rejected rather than silently ignored.
        case "${2:-}" in
            -h|--help) command wb "$@"; return $? ;;
        esac
        if [[ $# -gt 1 ]]; then
            log_error "wb reload: unexpected argument '${2}'"
            return 1
        fi
        # shellcheck disable=SC1090
        if source "${WORKBENCH_LOADER_PATH}"; then
            log_info "wb: reloaded workbench-core in this shell"
            return 0
        else
            log_error "wb: failed to reload workbench-core in this shell"
            return 1
        fi
    fi

    local _wb_wrapper_rc=0
    command wb "$@" || _wb_wrapper_rc=$?

    local _wb_should_reload=true
    case "${1:-}" in
        # __complete is the hidden dispatcher the generated bash/zsh
        # completion scripts shell out to on every keystroke past the
        # first TAB level (D54) — a read-only introspection call, exactly
        # like the other entries here, and one that runs far too often to
        # ever pay for a full shell reload. Omitting it was a gap, not a
        # deliberate choice — see docs/decisions-log.md D65. It's also
        # the single most expensive thing this wrapper could trigger now
        # that a full reload means re-sourcing every tier of every
        # loadable module under this environment's per-file-open cost.
        status|functions|tools|version|completion|__complete|help|-h|--help|"")
            _wb_should_reload=false
            ;;
        # 'wb module info'/'wb module docs' are read-only (D45/D70) — same
        # exclusion reasoning as above, one level deeper since 'module' is
        # a command group, not a single subcommand. 'wb module reset'
        # genuinely writes to disk (force-redeploys a copy-mode deploy
        # file), and any future 'wb module' subcommand nobody's excluded
        # yet defaults to reloading — same "unknown defaults to the safe
        # direction" rule as the block above.
        module)
            case "${2:-}" in
                info|docs) _wb_should_reload=false ;;
            esac
            ;;
    esac

    if [[ "${_wb_should_reload}" == "true" ]]; then
        # shellcheck disable=SC1090
        if source "${WORKBENCH_LOADER_PATH}"; then
            log_info "wb: reloaded workbench-core in this shell"
        else
            log_error "wb: failed to reload workbench-core in this shell"
        fi
    fi

    return "${_wb_wrapper_rc}"
}

# ── PATH deduplication ────────────────────────────────────────────────────────
command -v dedupe-path &>/dev/null && dedupe-path 2>/dev/null

# ── RC migration pending warning ──────────────────────────────────────────
# Fires while any rc-stub-tagged backup remains under the shared backup
# root (docs/decisions-log.md D53/D64) — cheap on-disk check, no
# subprocess beyond find. Clears itself once the user removes the file(s).
# Gated on an interactive shell, same as the "Interactive startup" block
# just below — this PR also adds the loader stub to .zshenv, which zsh
# sources for every invocation including non-interactive ones (ssh
# host cmd, zsh -c, shebang scripts); without this gate the warning would
# leak onto stderr there too (flagged in PR review).
if [[ $- == *i* ]]; then
    _wb_migration_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/workbench/backups"
    _wb_migration_found=false
    while IFS= read -r _wb_bak; do
        [[ -z "${_wb_bak}" ]] && continue
        if [[ "${_wb_migration_found}" == "false" ]]; then
            log_warn "Shell rc migration pending: workbench backed up pre-existing rc content before adding its loader stub."
            log_warn "  Review the backup(s) below and copy anything you want to keep into a new file under \${XDG_CONFIG_HOME:-\${HOME}/.config}/workbench/local/, then remove the backup to clear this warning."
            _wb_migration_found=true
        fi
        log_warn "  ${_wb_bak}"
    done < <(find "${_wb_migration_dir}" -maxdepth 3 -name 'rc-stub-*' -type f 2>/dev/null)
    unset _wb_migration_dir _wb_migration_found _wb_bak
fi

# ── Interactive startup ───────────────────────────────────────────────────────
# --no-pager --no-aliases (docs/decisions-log.md D73): this fires on every
# new interactive shell, so it must never itself drop into an interactive
# pager session (surprising and confusing on plain shell launch/reload —
# real report) and stays trimmed to functions + getters, skipping the
# aliases section, to keep it a quick summary rather than the full listing
# `wb functions` by hand still gives you.
if [[ $- == *i* ]] && [[ "${WORKBENCH_SHOW_FUNCTIONS}" == "true" ]] && command -v get-functions &>/dev/null; then
    get-functions --no-pager --no-aliases
fi

unset _wb_loader_lib_dir
