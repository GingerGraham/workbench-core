#!/usr/bin/env bash
# lib/core/functions.sh — Core API: elevation helpers, distro/OS/WSL/shell/
# arch detection, prompt helpers, the getter-introspection primitives.
#
# Ported from workbench-precursor's shell/config/core/functions.sh and
# shell/config/loader.sh, renamed DOTFILES_* -> WORKBENCH_* per the build
# brief §4, plus one new fact (WORKBENCH_ARCH, raw `uname -m`, not present in
# the donor codebase at all).
#
# Bash 3.2 / zsh compatible throughout — no declare -A, mapfile/readarray,
# ${var,,}/${var^^}, declare -n, or `shopt -s globstar`. This file is the
# library every module's register.shell[] entry is sourced alongside, so a
# bash-4-only construct here would silently break macOS's default /bin/bash
# for every module, not just core.

# shellcheck source=lib/core/log.sh
_wb_functions_dir="$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
[[ -f "${_wb_functions_dir}/log.sh" ]] && source "${_wb_functions_dir}/log.sh"
unset _wb_functions_dir

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/core/functions.sh" "0.13.0" || true

# ── OS / WSL / Distro / Shell / Arch detection (run once per session) ───────
# Reconciles loader.sh's inline detection block and functions.sh's separate
# detect-distro() into one routine, per the build brief's §4 callout.
_workbench_detect_platform() {
    # The shell is a fact about this process, not the session: bin/wb is
    # always bash, even when started from zsh, which exports
    # WORKBENCH_SHELL=zsh. Detect it every time, before the cached-result
    # return below, so a module file sourced inside bin/wb never evals zsh
    # init code in bash.
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        WORKBENCH_SHELL="zsh"
    elif [[ -n "${BASH_VERSION:-}" ]]; then
        WORKBENCH_SHELL="bash"
    else
        WORKBENCH_SHELL="sh"
    fi
    export WORKBENCH_SHELL

    # A shell started before D126 exports WORKBENCH_PLATFORM_DETECTED=true
    # but no WORKBENCH_DISTRO_ID; re-detect in that case (idempotent).
    if [[ "${WORKBENCH_PLATFORM_DETECTED:-false}" == "true" && -n "${WORKBENCH_DISTRO_ID:-}" ]]; then
        return 0
    fi

    local _raw_os
    _raw_os="$(uname -s)"
    case "${_raw_os}" in
        Linux)  WORKBENCH_OS="Linux" ;;
        Darwin) WORKBENCH_OS="Mac"   ;;
        *)      WORKBENCH_OS="Linux" ;;
    esac
    export WORKBENCH_OS

    if [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
        WORKBENCH_WSL="true"
    else
        WORKBENCH_WSL="false"
    fi
    export WORKBENCH_WSL

    if [[ "${WORKBENCH_OS}" == "Linux" && -f /etc/os-release ]]; then
        local _distro_id _distro_id_like
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
        # Same rule as lib/loader.sh's inline copy (D126).
        # (Characters listed rather than ranged: ranges follow the locale.)
        case "${_distro_id}" in
            ''|*[!abcdefghijklmnopqrstuvwxyz0123456789._-]*) WORKBENCH_DISTRO_ID="unknown" ;;
            *)                 WORKBENCH_DISTRO_ID="${_distro_id}" ;;
        esac
    else
        WORKBENCH_DISTRO="unknown"
        WORKBENCH_DISTRO_ID="unknown"
    fi
    export WORKBENCH_DISTRO
    export WORKBENCH_DISTRO_ID

    # New, not a rename: raw `uname -m` output. No universal name-normalizer
    # is provided — see docs/guide/module-authoring.md for the two common
    # normalization snippets a module can use for its own tool's convention.
    WORKBENCH_ARCH="$(uname -m)"
    export WORKBENCH_ARCH

    WORKBENCH_PLATFORM_DETECTED="true"
}
_workbench_detect_platform

# ── Prompt helpers ────────────────────────────────────────────────────────
# Ported verbatim from workbench-precursor's shell/config/tools/git.sh —
# extracted into core per the build brief's Phase 2 callout: this does NOT
# travel with the rest of git.sh to workbench-git.
_read_prompt() {
    local _rp_prompt="$1"
    local _rp_var="$2"
    local _rp_value
    printf '%s' "${_rp_prompt}" >/dev/tty
    IFS= read -r _rp_value </dev/tty
    eval "${_rp_var}=\${_rp_value}"
}

# True when a person can be asked: /dev/tty opens. Works under
# `curl … | bash`, where stdin is the pipe. False under cron, systemd,
# CI and cloud-init (docs/decisions-log.md D84).
_wb_have_tty() {
    { : </dev/tty; } 2>/dev/null
}

_read_prompt_silent() {
    local _rp_prompt="$1"
    local _rp_var="$2"
    local _rp_value
    printf '%s' "${_rp_prompt}" >/dev/tty
    IFS= read -rs _rp_value </dev/tty
    printf '\n' >/dev/tty
    eval "${_rp_var}=\${_rp_value}"
}

# ── Port helpers (docs/decisions-log.md D129) ─────────────────────────────
# Moved here from workbench-cloud's shell/aws-emulator.sh (D128), so any
# module can find a free port without depending on another module. TCP
# listeners only.

# workbench_port_in_use <port> — 0 when anything listens on <port> on any
# address, 1 when nothing does, 2 when there's no tool to tell.
workbench_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -Hltn 2>/dev/null | awk -v p="${port}" '$4 ~ (":" p "$") { found = 1 } END { exit found ? 0 : 1 }'
    elif command -v lsof >/dev/null 2>&1; then
        [ -n "$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null)" ]
    else
        return 2
    fi
}

# workbench_port_pick <base> <label> [<taken>...] — prints the first port
# from <base> to <base>+99 that nothing listens on and that isn't one of
# <taken> (ports the caller has promised elsewhere, such as a stopped
# stack's). A port used on any address counts as used: deliberately
# conservative. Messages start with "<label>:". Without ss or lsof, warns
# once and prints the first port not in <taken>.
workbench_port_pick() {
    local base="$1" label="$2" candidate last rc t skip
    case "${base}" in
        ''|*[!0123456789]*)
            log_error "${label}: port base must be a number (got '${base}')"
            return 2
            ;;
    esac
    shift 2
    candidate="${base}"
    last=$((base + 99))
    while [ "${candidate}" -le "${last}" ]; do
        skip=""
        for t in "$@"; do
            if [ "${t}" = "${candidate}" ]; then
                skip=1
                break
            fi
        done
        if [ -z "${skip}" ]; then
            workbench_port_in_use "${candidate}"
            rc=$?
            case "${rc}" in
                1)
                    printf '%s\n' "${candidate}"
                    return 0
                    ;;
                0) ;;
                *)
                    log_warn "${label}: can't check ports (no ss or lsof) — trying ${candidate}"
                    printf '%s\n' "${candidate}"
                    return 0
                    ;;
            esac
        fi
        candidate=$((candidate + 1))
    done
    log_error "${label}: no free port from ${base} to ${last}"
    return 1
}

# ── Completion registration (docs/decisions-log.md D132) ──────────────────
# workbench_complete <provider> <command>... — tab completion for module
# commands, in bash and zsh, from one provider function the module writes in
# plain shell. The provider is called as
#     <provider> <index> <word0> <word1> ...
# where <word0> is the command and <index> is the position of the word being
# completed (0 is the command itself). It prints one candidate per line,
# optionally "candidate<TAB>description" (zsh shows the description, bash
# shows the candidate only), or the single line "@files" to hand the word to
# the shell's own file-name completion.
#
# zsh: a compinit run after this (the user's .zshrc, or a plugin manager
# after the first prompt) empties zsh's completion table. A precmd hook
# notices and registers everything again; the check is one table lookup per
# prompt.

_WB_COMPLETE_PROVIDERS="${_WB_COMPLETE_PROVIDERS:-}"
_WB_COMPLETE_ZSH="${_WB_COMPLETE_ZSH:-}"

# _wb_complete_provider <command> — the provider registered for <command>.
# Entries are " <command>=<provider>"; the last one for a command wins, so
# registering again after 'wb reload' needs no clean-up.
_wb_complete_provider() {
    local rest
    case "${_WB_COMPLETE_PROVIDERS} " in
        *" $1="*) ;;
        *) return 1 ;;
    esac
    rest="${_WB_COMPLETE_PROVIDERS##* "$1"=}"
    printf '%s\n' "${rest%% *}"
}

# _wb_complete_bash <command> — bash's -F function for every registered
# command.
_wb_complete_bash() {
    local provider line cur values="" files=""
    COMPREPLY=()
    provider="$(_wb_complete_provider "$1")" || return 0
    cur="${COMP_WORDS[COMP_CWORD]}"
    while IFS= read -r line; do
        case "${line}" in
            "") ;;
            @files) files=1 ;;
            *) values="${values}${line%%$'\t'*}
" ;;
        esac
    done < <("${provider}" "${COMP_CWORD}" "${COMP_WORDS[@]}" 2>/dev/null)
    # Nothing in COMPREPLY: complete -o default falls back to file names.
    [ -n "${files}" ] && return 0
    local IFS='
'
    # shellcheck disable=SC2207  # compgen's output, split on newlines only
    COMPREPLY=( $(compgen -W "${values}" -- "${cur}") )
}

# _wb_complete_zsh — zsh's completion function for every registered
# command.
_wb_complete_zsh() {
    local provider out line value desc files=""
    local -a described
    described=()
    # shellcheck disable=SC2154  # words and CURRENT are zsh's completion state
    provider="$(_wb_complete_provider "${words[1]}")" || return 1
    out="$("${provider}" "$((CURRENT - 1))" "${words[@]}" 2>/dev/null)"
    while IFS= read -r line; do
        case "${line}" in
            "") ;;
            @files) files=1 ;;
            *)
                value="${line%%$'\t'*}"
                desc=""
                case "${line}" in
                    *$'\t'*) desc="${line#*$'\t'}" ;;
                esac
                value="${value//:/\\:}"
                if [ -n "${desc}" ]; then
                    described+=("${value}:${desc}")
                else
                    described+=("${value}")
                fi
                ;;
        esac
    done <<EOF
${out}
EOF
    if [ -n "${files}" ]; then
        _files
        return
    fi
    [ "${#described[@]}" -gt 0 ] && _describe 'value' described
}

# _wb_complete_zsh_register <zsh-function> <command>... — compdef, kept
# registered across a later compinit. Core's own wb completion uses it too.
_wb_complete_zsh_register() {
    local fn="$1" cmd
    shift
    if ! command -v compdef >/dev/null 2>&1; then
        autoload -Uz compinit && compinit -C
    fi
    for cmd in "$@"; do
        _WB_COMPLETE_ZSH="${_WB_COMPLETE_ZSH} ${cmd}=${fn}"
    done
    compdef "${fn}" "$@"
    case " ${precmd_functions[*]:-} " in
        *" _wb_complete_rearm "*) ;;
        *) precmd_functions+=(_wb_complete_rearm) ;;
    esac
}

# _wb_complete_rearm — precmd hook. When a later compinit has emptied the
# table (the first registered command has no completion any more), it
# registers every command again.
_wb_complete_rearm() {
    local first entry
    command -v compdef >/dev/null 2>&1 || return 0
    first="${_WB_COMPLETE_ZSH# }"
    first="${first%%=*}"
    [ -n "${first}" ] || return 0
    # shellcheck disable=SC2154  # _comps is zsh's completion table
    [[ -n "${_comps[${first}]:-}" ]] && return 0
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        compdef "${entry#*=}" "${entry%%=*}"
    done <<EOF
$(printf '%s\n' "${_WB_COMPLETE_ZSH}" | tr ' ' '\n')
EOF
}

workbench_complete() {
    local provider="${1:-}" cmd
    if [ "$#" -lt 2 ]; then
        log_error "workbench_complete: usage: workbench_complete <provider> <command>..."
        return 2
    fi
    shift
    for cmd in "$@"; do
        case "${cmd}" in
            ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*)
                log_error "workbench_complete: '${cmd}' isn't a command name (letters, digits, - and _)"
                return 2
                ;;
        esac
    done
    for cmd in "$@"; do
        _WB_COMPLETE_PROVIDERS="${_WB_COMPLETE_PROVIDERS} ${cmd}=${provider}"
    done
    if [ -n "${BASH_VERSION:-}" ]; then
        complete -o default -F _wb_complete_bash "$@"
    elif [ -n "${ZSH_VERSION:-}" ]; then
        _wb_complete_zsh_register _wb_complete_zsh "$@"
    fi
}

# ── PATH deduplication ────────────────────────────────────────────────────
dedupe-path() {
    if ! command -v awk &>/dev/null || ! command -v tr &>/dev/null || ! command -v sed &>/dev/null; then
        log_error "dedupe-path: awk, tr, and sed are required"
        return 1
    fi
    # shellcheck disable=SC2155
    export PATH="$(echo "${PATH}" | tr ':' '\n' | awk '!seen[$0]++' | tr '\n' ':' | sed 's/:$//')"
}

# ── String helpers ─────────────────────────────────────────────────────────
# _str_lower <string>
# Lowercases via `tr`, not `${var,,}` — the latter is a bash-4+-only
# construct (docs/architecture.md §7 item 11) and breaks on bash 3.2/zsh. Ported
# from workbench-precursor's core/functions.sh — used across multiple Wave
# C modules (workbench-git, workbench-gpg, workbench-security) for
# case-insensitive comparisons, so it belongs in Core API rather than each
# module carrying its own copy.
_str_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ── Package manager detection ─────────────────────────────────────────────
detect-package-manager() {
    if command -v apt     &>/dev/null; then PACKAGE_MANAGER="apt"
    elif command -v dnf   &>/dev/null; then PACKAGE_MANAGER="dnf"
    elif command -v yum   &>/dev/null; then PACKAGE_MANAGER="yum"
    elif command -v zypper &>/dev/null; then PACKAGE_MANAGER="zypper"
    elif command -v pacman &>/dev/null; then PACKAGE_MANAGER="pacman"
    elif command -v brew  &>/dev/null; then PACKAGE_MANAGER="brew"
    else
        log_error "detect-package-manager: no supported package manager found"
        return 1
    fi
    export PACKAGE_MANAGER
    log_info "Using package manager: ${PACKAGE_MANAGER}"
}

# ── Plain shell ─────────────────────────────────────────────────────────
# Re-exec the current shell with prompt styling and colour disabled.
# Useful when capturing terminal output for pasting elsewhere: no prompt
# escapes, no SGR sequences from NO_COLOR-aware tools.
#
# exec REPLACES this process rather than nesting it — the plain shell is
# not a child of the styled one, it takes over the same PID. There is no
# styled shell left to fall back to: `exit` here ends the session (closes
# the terminal, or drops an SSH connection), the same as `exit` in any
# top-level shell. To get back to a styled shell, open a new session.
# Background jobs in the pre-exec shell are also lost — same as any exec.
#
# WORKBENCH_PLAIN_SHELL=true is the only var this sets — lib/loader.sh's
# behaviour-flags block derives NO_COLOR and WORKBENCH_SHOW_FUNCTIONS=false
# from it on the run that follows, same as any other flag read at loader
# start; nothing here duplicates that.
#
# The interpreter is resolved from WORKBENCH_SHELL (the shell actually
# running, a Core API fact) rather than $SHELL (the passwd login shell),
# which can differ.
#
# `exec env VAR=... cmd` rather than a `VAR=... exec cmd` assignment
# prefix: assignment prefixes on special builtins behave inconsistently
# across bash and zsh, whereas env(1) is unambiguous in both. Ported from
# workbench-precursor's core/functions.sh.
plain-shell() {
    local _sh
    _sh="$(command -v "${WORKBENCH_SHELL:-bash}" 2>/dev/null)"
    [[ -z "${_sh}" ]] && _sh="${SHELL:-/bin/bash}"
    log_warn "Re-execing ${_sh} with prompt styling and colour disabled (plain mode). Use 'pretty-shell' to restore normal prompt behaviour. This shell will exit normally when you type 'exit'."
    exec env WORKBENCH_PLAIN_SHELL=true "${_sh}" -i
}

# ── Pretty shell ────────────────────────────────────────────────────────
# Re-exec the current shell with prompt styling and colour restored — the
# counterpart to plain-shell(). Same exec-replace semantics: this takes
# over the current PID rather than nesting, so there's no lingering
# plain-mode process left behind either.
#
# WORKBENCH_PLAIN_SHELL was exported by plain-shell(), so a bare
# `exec zsh -i` would inherit it and lib/loader.sh would stay in plain
# mode — that's the actual cause of "subshells retain plain status".
# Explicitly setting WORKBENCH_PLAIN_SHELL=false and stripping NO_COLOR
# from the child's environment is what lets the normal prompt-engine
# election chain run again.
#
# NO_COLOR is unset rather than restored to a prior value: if it's set
# permanently in settings.sh, lib/loader.sh re-applies it at the end of
# the normal run anyway, so there's nothing to lose by clearing it here.
# Ported from workbench-precursor's core/functions.sh.
pretty-shell() {
    local _sh
    _sh="$(command -v "${WORKBENCH_SHELL:-bash}" 2>/dev/null)"
    [[ -z "${_sh}" ]] && _sh="${SHELL:-/bin/bash}"
    log_info "Re-execing ${_sh} with prompt styling and colour restored (pretty mode). This shell will exit normally when you type 'exit'."
    exec env -u NO_COLOR WORKBENCH_PLAIN_SHELL=false "${_sh}" -i
}

# ── cheat.sh lookup ────────────────────────────────────────────────────
cheat() {
    curl "https://cheat.sh/$1"
}

# ── Privilege elevation helpers ───────────────────────────────────────────
# _workbench_current_user
# Resolves the invoking user without depending on $USER being exported —
# confirmed unset in a bare `docker run -it fedora:latest` root shell (no
# login/PAM session ever sets it), which crashed sudo-test/get-elevation-
# command under bin/wb's `set -u`: get-elevation-command's `${USER}`
# reference inside elevate-cmd's `elevation_cmd="$(...)"` command
# substitution killed that subshell with "unbound variable", swallowed by
# elevate-cmd's `|| return 1`, so wb install silently never actually
# invoked the package manager (docs/decisions-log.md D52). `id -un` is used
# directly, not just as a fallback — it's more reliable than $USER even
# when exported (immune to a stale value inherited across `su`), and needs
# no new prereq check: `id` is more fundamental than anything in
# _WB_SHELL_PREREQS_REQUIRED, same "assumed always present" class as the
# bare `uname` calls in _workbench_detect_platform.
_workbench_current_user() {
    id -un
}

sudo-test() {
    local _wb_user
    _wb_user="$(_workbench_current_user)"
    if sudo -l -U "${_wb_user}" &>/dev/null; then
        return 0
    elif command -v run0 &>/dev/null && run0 -l -U "${_wb_user}" &>/dev/null; then
        log_debug "User has run0 access"
        return 0
    fi
    log_error "No sudo/run0 access for ${_wb_user}"
    return 1
}

get-elevation-command() {
    local _wb_user
    _wb_user="$(_workbench_current_user)"
    if command -v sudo &>/dev/null && sudo -l -U "${_wb_user}" &>/dev/null; then
        echo "sudo"
        return 0
    elif command -v run0 &>/dev/null && run0 -l -U "${_wb_user}" &>/dev/null; then
        log_debug "Using run0 for privilege elevation"
        echo "run0"
        return 0
    fi
    log_error "No privilege elevation mechanism available"
    return 1
}

elevate-cmd() {
    local cmd_to_run="$*"
    local elevation_cmd

    if [[ -z "${cmd_to_run}" ]]; then
        log_error "elevate-cmd: no command specified"
        return 1
    fi

    elevation_cmd="$(get-elevation-command)" || return 1

    if [[ "${elevation_cmd}" == "run0" ]]; then
        log_warn "Using run0 — you may be prompted multiple times (no credential caching)"
    fi

    log_debug "Executing with ${elevation_cmd}: ${cmd_to_run}"
    # shellcheck disable=SC2086
    ${elevation_cmd} ${cmd_to_run}
}

# ── Function/alias availability gating ───────────────────────────────────
# _wb_run_with_timeout <seconds> <command> [args...]
# Portable (bash-3.2-safe) watchdog: backgrounds <command>, races it
# against a sleep/kill watchdog, and returns its real exit status if it
# finished in time. Returns 124 (GNU timeout's own convention) if it had
# to be killed, so callers can tell "ran and failed" from "never
# returned" without a second code path. `disown` on both jobs keeps this
# quiet under job control (an interactive caller, unlike bin/wb's own
# non-interactive script context) — without it, bash prints an
# unsolicited "Terminated" notification for the killed job at the next
# prompt. Deliberately disowned AFTER each `wait`, not immediately after
# backgrounding (an earlier version of this function did that and it's a
# real, confirmed bug, not a style choice): once a job is disowned, bash
# drops it from the job table, and `wait <pid>` on an already-disowned pid
# no longer returns that process's real exit status — it silently returns
# 0 instead, which made this wrapper report "available" for every
# predicate regardless of what it actually returned (caught by
# tests/check-function-availability-gating.sh). Disowning after `wait` has
# already reaped the exit status keeps both properties: the real status is
# captured, and the job is still removed from job control before an
# interactive shell's next prompt could report on it. Not GNU `timeout`,
# which is absent by default on macOS and this repo commits to bash 3.2
# portability.
_wb_run_with_timeout() {
    local _wb_rwt_timeout="$1"; shift
    "$@" &
    local _wb_rwt_pid=$!
    (
        sleep "${_wb_rwt_timeout}"
        kill -TERM "${_wb_rwt_pid}" 2>/dev/null
    ) &
    local _wb_rwt_watchdog=$!
    local _wb_rwt_rc=0
    wait "${_wb_rwt_pid}" 2>/dev/null || _wb_rwt_rc=$?
    disown "${_wb_rwt_pid}" 2>/dev/null
    kill "${_wb_rwt_watchdog}" 2>/dev/null
    wait "${_wb_rwt_watchdog}" 2>/dev/null
    disown "${_wb_rwt_watchdog}" 2>/dev/null
    [[ "${_wb_rwt_rc}" -eq 143 ]] && return 124   # 128 + SIGTERM
    return "${_wb_rwt_rc}"
}

# _wb_cache_bool <cache-key> -- <command> [args...]
# Runs <command> at most once per <cache-key> for the lifetime of this
# process, returning the cached exit status on every later call with the
# same key. For a hand-written availability predicate whose real check is
# expensive (a live agent/hardware/network probe) but conceptually shared
# across several exposed names — e.g. several gpg-* predicates all really
# asking "is a card present". <cache-key> is the author's own choice, not
# derived from <command>: this file has no way to know two differently-
# worded checks are "the same" probe, so it never guesses — the author
# says so explicitly by reusing the same key.
#
# File-backed, not an in-shell eval-indexed variable (an earlier version
# of this function used one, the same technique as
# _wb_availability_reason_<key> above): every predicate call now runs
# through _wb_run_with_timeout, which backgrounds it (`"$@" &`) to race it
# against the watchdog — a real forked subprocess, not just a nested
# shell. A variable set inside that fork via eval is gone the instant the
# fork exits; it never makes it back to the caller's shell, so two
# predicates sharing a cache key would each pay for the real check anyway
# (confirmed by tests/check-availability-timeout.sh while building this).
# One small file per <cache-key>, under a directory keyed by `$$` (stable
# across forks — only $BASHPID changes there, not $$ — so every predicate
# call anywhere in this same top-level process, `wb functions` or an
# interactive shell alike, shares the same cache), holds the cached exit
# status instead. Known, accepted limitation: nothing removes this
# directory afterwards, so it's left for the OS's normal tmp-cleanup —
# one tiny file per distinct cache key actually used, not worth a global
# EXIT trap in a file this widely sourced (which could also silently
# clobber a caller's own trap).
: "${_wb_cache_bool_dir:=${TMPDIR:-/tmp}/.wb-cache-bool.$$}"

_wb_cache_bool() {
    local _key _sanitized _cache_file _rc
    _key="$1"; shift
    [[ "${1:-}" == "--" ]] && shift
    _sanitized="$(printf '%s' "${_key}" | tr -c 'A-Za-z0-9_' '_')"
    _cache_file="${_wb_cache_bool_dir}/${_sanitized}"
    _rc=""
    [[ -f "${_cache_file}" ]] && _rc="$(command cat "${_cache_file}" 2>/dev/null)"
    if [[ -z "${_rc}" ]]; then
        "$@" &>/dev/null
        _rc=$?
        mkdir -p "${_wb_cache_bool_dir}" 2>/dev/null
        printf '%s' "${_rc}" > "${_cache_file}" 2>/dev/null
    fi
    return "${_rc}"
}

# Per-predicate ceiling for _wb_function_available below. Overridable —
# a real gpg/ssh-agent probe can legitimately take longer than a plain
# command -v check, especially over WSL2's virtualised device path, so
# this is a judgment call, not a measured figure. Tune it if a real
# predicate in this repo starts getting falsely killed.
WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS="${WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS:-1}"

# Reset at the start of every `wb functions` run (bin/wb's
# _wb_cmd_functions, via _wb_availability_timeout_reset below) and
# appended to by _wb_function_available whenever a predicate hits the
# timeout instead of returning normally. Space-separated, not an array —
# bash-3.2 constraint again.
#
# File-backed as well as this in-shell variable, not just the variable
# alone — same reasoning, and the same technique, as _wb_cache_bool's own
# file-backed cache just above: _wb_function_available (via
# _wb_filter_available_names) is always invoked from inside a `$(...)`
# command substitution in _get_functions_in/_get_aliases_in/
# _wb_print_live_names, which is itself a subshell — a plain variable
# assignment made in there is gone the instant that subshell exits and
# never reaches _wb_cmd_functions' own scope, so the warning line came up
# empty even though a predicate genuinely timed out (confirmed by
# tests/check-availability-timeout.sh while building this). A file write
# is not scoped to the subshell that made it, so it survives that
# boundary; _wb_print_timeout_warning reads the file back, not the
# variable. The variable itself is kept for any caller that invokes
# _wb_function_available directly, with no subshell in between (there is
# no harm in updating both).
: "${_wb_availability_timeout_log:=${TMPDIR:-/tmp}/.wb-availability-timeouts.$$}"
_wb_availability_timed_out=""

# _wb_availability_timeout_reset
# Clears both the in-shell accumulator and its file backing — called at
# the start of every `wb functions` run (bin/wb's _wb_cmd_functions)
# rather than resetting the file inline there, since only this file knows
# the file's own path.
_wb_availability_timeout_reset() {
    _wb_availability_timed_out=""
    rm -f "${_wb_availability_timeout_log}" 2>/dev/null
}

# _wb_function_available <name>
# Looks up an optional "_<name>-available" predicate and returns its exit
# code. No predicate declared — the overwhelmingly common case, since most
# functions have nothing to gate — means available: exit 0. Also always
# available when WORKBENCH_FUNCTIONS_SHOW_ALL=true (wb functions --all,
# or WORKBENCH_FUNCTIONS_SHOW_ALL=true <any getter>) — checked here once
# so every caller gets the override for free. This is the single check
# every listing surface runs before printing a name, so there is exactly
# one place "is this actually usable right now" gets decided
# (docs/decisions-log.md D43 — never guess, an absent predicate is a
# known state, not a failure). The predicate call itself is bounded to
# WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS (docs/decisions-log.md D65) so a
# slow/hanging hand-written predicate (a live gpg/ssh-agent/network probe)
# can never block a listing command indefinitely.
_wb_function_available() {
    [[ "${WORKBENCH_FUNCTIONS_SHOW_ALL:-false}" == "true" ]] && return 0
    local _name="$1" _predicate _rc
    _predicate="_${_name}-available"
    if command -v "${_predicate}" &>/dev/null; then
        _wb_run_with_timeout "${WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS}" "${_predicate}" &>/dev/null
        _rc=$?
        if [[ "${_rc}" -eq 124 ]]; then
            _wb_availability_timed_out="${_wb_availability_timed_out:+${_wb_availability_timed_out} }${_name}"
            printf '%s\n' "${_name}" >> "${_wb_availability_timeout_log}" 2>/dev/null
            return 1
        fi
        return "${_rc}"
    fi
    return 0
}

# _wb_print_timeout_warning
# Prints one log_warn line naming every predicate that hit
# WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS during this run, if any. Reads
# the file-backed log, not the in-shell variable — see the comment above
# _wb_availability_timeout_log for why that's the one guaranteed to have
# survived every call site. A predicate that has to be killed is a bug in
# whichever module declared it (docs/guide/module-authoring.md, "Declaring
# function availability": predicates must be cheap discovery checks,
# never a live hardware/agent/network probe) — surfaced loudly, not
# blended into the listing.
_wb_print_timeout_warning() {
    [[ -s "${_wb_availability_timeout_log}" ]] || return 0
    local _names
    _names="$(sort -u "${_wb_availability_timeout_log}" 2>/dev/null | tr '\n' ' ')"
    _names="${_names% }"
    log_warn "wb functions: predicate(s) for [${_names}] exceeded ${WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS}s and were killed — see docs/guide/module-authoring.md 'Declaring function availability'"
}

# _wb_filter_available_names
# Reads names on stdin, one per line, prints only those
# _wb_function_available reports as available. Blank input passes through
# as blank output so callers that check for an empty result (and print
# "(none)") keep working unchanged.
_wb_filter_available_names() {
    local _n
    while IFS= read -r _n; do
        [[ -z "${_n}" ]] && continue
        _wb_function_available "${_n}" && printf '%s\n' "${_n}"
    done
}

# _wb_availability_key <name>
# Sets _wb_availability_key_result to <name> with every non [A-Za-z0-9_]
# character turned into "_" — the suffix of the side-channel variables
# below (bash variable names can't contain "-"). Parameter expansion, not
# `$(printf | tr)`: a listing looks up two variables per hidden name, and
# three forks per lookup made a long block measurably slower. LC_ALL=C
# keeps the bracket range plain ASCII whatever the user's locale (same
# technique as workbench_valid_module_name in lib/sync/state.sh). Sets a
# variable instead of printing, so callers pay for no subshell.
_wb_availability_key() {
    local LC_ALL=C
    _wb_availability_key_result="${1//[^A-Za-z0-9_]/_}"
}

# _wb_availability_needs [--install <tool>] <needs-text> <name> [<name> ...]
# Records, for each <name>, what it needs (shown in listings) and, with
# --install, the `wb tools` friendly name that would provide it. Defines no
# predicate — pair it with a hand-written _<name>-available, or reach it via
# _wb_alias_availability --needs / _wb_declare_availability, which call it.
# Works for any predicate however it was written (docs/decisions-log.md
# D86), so a listing can say what is missing even when the predicate is a
# version check or an OR of several tools.
#
# Stored in "_wb_availability_reason_<key>" / "_wb_availability_install_<key>"
# (<key> = <name> with every non [A-Za-z0-9_] character turned into "_",
# since bash variable names can't contain "-"). A side-channel variable set
# at declaration time, not a re-parse of the predicate's `declare -f` output:
# bash 3.2 reprints a parsed function body differently from bash 4+ (see
# _wb_function_missing_reason below).
#
# The values are read through "\${_needs}" inside eval, never interpolated
# into the eval string, so quotes or $( ) in a needs text stay inert. Tabs
# and newlines are stripped from both values: _wb_print_unavailable_block
# uses tab as its row separator.
_wb_availability_needs() {
    local _install=""
    if [[ "${1:-}" == "--install" ]]; then
        if [[ $# -lt 2 ]]; then
            log_error "_wb_availability_needs: --install needs a tool name"
            return 2
        fi
        _install="$2"
        shift 2
    fi
    local _needs="${1:-}"
    [[ $# -gt 0 ]] && shift
    _needs="${_needs//$'\t'/ }"
    _needs="${_needs//$'\n'/ }"
    _install="${_install//$'\t'/ }"
    _install="${_install//$'\n'/ }"
    local _fn _key
    for _fn in "$@"; do
        _wb_availability_key "${_fn}"
        _key="${_wb_availability_key_result}"
        eval "_wb_availability_reason_${_key}=\"\${_needs}\""
        eval "_wb_availability_install_${_key}=\"\${_install}\""
    done
}

# _wb_declare_availability <command> <function-name> [<function-name> ...]
# Bulk-declares a "_<name>-available" predicate for each <function-name>,
# each checking the same one <command> via `command -v`. Turns "these N
# names all need the same external tool" into one line instead of N
# near-identical predicate bodies. eval is required to build a function
# whose name is only known at runtime (bash 3.2 has no declare -n) — same
# technique workbench-gpg's own _array_get already uses for array
# indirection. See docs/guide/module-authoring.md "Declaring function
# availability" for the full contract, including when to use
# _wb_alias_availability or a hand-written predicate instead.
#
# Also records <command> as both the needs text and the `wb tools` name via
# _wb_availability_needs, so a listing shows what is missing and — if an
# installer of that name is registered — how to get it.
_wb_declare_availability() {
    local _cmd="$1"; shift
    local _fn
    for _fn in "$@"; do
        eval "_${_fn}-available() { command -v \"${_cmd}\" &>/dev/null; }"
    done
    _wb_availability_needs --install "${_cmd}" "${_cmd}" "$@"
}

# _wb_alias_availability [--needs <text>] [--install <tool>] <check-function> <function-name> [<function-name> ...]
# Bulk-declares a "_<name>-available" predicate for each <function-name>,
# each a thin wrapper around an existing boolean-returning
# <check-function> — for when several names share a check more complex
# than a single command-v (a version/variant check, several required
# tools together) that the module already has, or is worth extracting
# once as a quiet twin of an existing loud "_xxx_require_yyy" preflight
# helper (see the workbench-git and workbench-security examples in
# docs/guide/module-authoring.md).
#
# The leading flags are optional. --needs records what the check requires,
# for listings (_wb_availability_needs); --install adds the `wb tools` name
# that would provide it, and only makes sense with --needs. Without --needs
# the names still list correctly, under "module gave no reason". An unknown
# --flag is an error (status 2) and declares nothing.
_wb_alias_availability() {
    local _needs="" _install="" _have_needs="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --needs)
                if [[ $# -lt 2 ]]; then
                    log_error "_wb_alias_availability: --needs needs a text argument"
                    return 2
                fi
                _needs="$2"
                _have_needs="true"
                shift 2
                ;;
            --install)
                if [[ $# -lt 2 ]]; then
                    log_error "_wb_alias_availability: --install needs a tool name"
                    return 2
                fi
                _install="$2"
                shift 2
                ;;
            --*)
                log_error "_wb_alias_availability: unknown option '$1'"
                return 2
                ;;
            *) break ;;
        esac
    done
    if [[ -n "${_install}" && "${_have_needs}" == "false" ]]; then
        log_error "_wb_alias_availability: --install needs --needs (nothing to show the install hint next to)"
        return 2
    fi

    local _check="$1"; shift
    local _fn
    for _fn in "$@"; do
        eval "_${_fn}-available() { ${_check}; }"
    done
    if [[ "${_have_needs}" == "true" ]]; then
        if [[ -n "${_install}" ]]; then
            _wb_availability_needs --install "${_install}" "${_needs}" "$@"
        else
            _wb_availability_needs "${_needs}" "$@"
        fi
    fi
}

# _wb_function_missing_reason <name>
# Prints the needs text recorded for <name> by _wb_availability_needs
# (directly, or via _wb_declare_availability / _wb_alias_availability
# --needs); prints nothing if none was recorded. Reads the
# "_wb_availability_reason_<key>" side-channel variable set at declaration
# time (same <key> derivation as there) rather than inferring it from the
# predicate function's own source. This is a read-back of what we recorded,
# not an inference about what an arbitrary predicate does — printing a
# reason we can't actually confirm would be a guess, so it says nothing
# instead (same principle as installed-<name>'s "unresponsive").
#
# Deliberately not `declare -f`-based (an earlier version was): bash 3.2
# (macOS's default /bin/bash) reprints a parsed function body differently
# from bash 4+ in ways this file has no reliable way to enumerate ahead
# of time, confirmed by a real macOS CI run (workbench-core#75) where a
# textual-reprint regex silently matched nothing. A side-channel variable
# set once at declaration time has no such version-dependent formatting
# to account for.
_wb_function_missing_reason() {
    _wb_availability_key "$1"
    eval "printf '%s' \"\${_wb_availability_reason_${_wb_availability_key_result}:-}\""
}

# _wb_function_install_tool <name>
# Sibling of _wb_function_missing_reason: prints the `wb tools` friendly
# name recorded for <name> (--install, or _wb_declare_availability's
# <command>), or nothing. A recorded name is a claim by the module, not
# proof an installer exists — _wb_installer_known is the check for that.
_wb_function_install_tool() {
    _wb_availability_key "$1"
    eval "printf '%s' \"\${_wb_availability_install_${_wb_availability_key_result}:-}\""
}

# _wb_installer_known <tool>
# Returns 0 only if `wb tools` has a registered installer whose friendly
# name is <tool> — the condition for printing "install: wb tools install
# <tool>" in a listing, so we never suggest a command that would answer
# "no discovered installer".
#
# Reads each module's rendered installers.list (lines of
# "abs_path|function|friendly", see workbench_render_installers_list in
# lib/sync/engine.sh) with a plain grep. No network, no sourcing of
# installer files, no `wb` subprocess, and no dependency on lib/core/
# tools.sh: this file also runs inside an interactive shell where only
# lib/sync/state.sh is guaranteed to be loaded (lib/loader.sh), so the
# modules directory is resolved the way workbench_modules_dir does when
# that helper is absent.
#
# Mirrors workbench_tools_collect's rules where they are cheap to check: the
# owning module must be registered (when state.sh's helpers are loaded), and
# the reserved wb-tools words are never installers. It does
# not re-implement collision resolution — two modules declaring the same
# friendly name still means "an installer exists".
_wb_installer_known() {
    local _tool="${1:-}" _root _list _module
    [[ -n "${_tool}" ]] || return 1
    case "${_tool}" in
        all|list|install|upgrade|status) return 1 ;;
        *[!A-Za-z0-9_-]*) return 1 ;;
    esac
    if command -v workbench_modules_dir &>/dev/null; then
        _root="$(workbench_modules_dir)"
    else
        _root="${WORKBENCH_MODULES_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/workbench/modules}"
    fi
    for _list in "${_root}"/*/installers.list; do
        [[ -f "${_list}" ]] || continue
        grep -q "^[^|]*|[^|]*|${_tool}\$" "${_list}" 2>/dev/null || continue
        _module="$(basename "$(dirname "${_list}")")"
        if command -v workbench_is_registered &>/dev/null; then
            workbench_is_registered "${_module}" || continue
        fi
        return 0
    done
    return 1
}

# _wb_print_unavailable_group <needs> <install-tool> <names>
# One group of _wb_print_unavailable_block: a header line, then the names
# in columns beneath it, indented four spaces. <install-tool> is the
# placeholder "-" when the module named none. Appends the install command
# only when _wb_installer_known confirms it (cached per tool for the rest
# of the enclosing block, so each distinct tool is looked up once).
_wb_print_unavailable_group() {
    local _needs="$1" _install="$2" _names="$3"
    local _header="  ${_needs}"
    if [[ "${_install}" != "-" ]]; then
        case "${_wb_known_tools}" in
            *$'\n'"${_install}"$'\n'*) _header="${_header} — install: wb tools install ${_install}" ;;
            *)
                case "${_wb_unknown_tools}" in
                    *$'\n'"${_install}"$'\n'*) ;;
                    *)
                        if _wb_installer_known "${_install}"; then
                            _wb_known_tools="${_wb_known_tools}${_install}"$'\n'
                            _header="${_header} — install: wb tools install ${_install}"
                        else
                            _wb_unknown_tools="${_wb_unknown_tools}${_install}"$'\n'
                        fi
                        ;;
                esac
                ;;
        esac
    fi
    echo "${_header}"
    # Indent is four spaces, so give column four fewer — it reads COLUMNS
    # (set for the whole run by _wb_cmd_functions, D73) and would otherwise
    # wrap four past the edge.
    if [[ "${COLUMNS:-}" =~ ^[0-9]+$ ]] && [[ "${COLUMNS}" -gt 8 ]]; then
        printf '%s' "${_names}" | COLUMNS=$((COLUMNS - 4)) column | sed 's/^/    /'
    else
        printf '%s' "${_names}" | column | sed 's/^/    /'
    fi
}

# _wb_print_unavailable_block <label> <all-names> <shown-names> [<noun>]
# Both name lists newline-separated. Prints nothing if nothing is hidden.
# Otherwise prints a blank line, then
#   [INFO] <label> — available once tooling is installed:
# then one group per distinct needs text (sorted), names in columns beneath
# (docs/decisions-log.md D86). Replaces _wb_print_hidden_hint. <noun> is
# only used by the compact form and defaults to "functions".
#
# Hidden = in <all-names> and not in <shown-names>, the same test the old
# hint used. Each hidden name lands in exactly one group:
#   - its predicate hit WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS ->
#     "availability check timed out (> Ns)" (read from the file-backed
#     timeout log, not the in-shell variable — a predicate runs inside a
#     command substitution, D65);
#   - else the needs text recorded by _wb_availability_needs;
#   - else "module gave no reason (predicate reports unavailable)". Shown,
#     never dropped.
#
# Compact form: when _wb_functions_compact is "true" (set only by
# `wb functions --compact`, never by a module getter) the whole block is one
# line, with a per-tool count — the install name if there is one, otherwise
# the needs text.
#
# Rows are "needs<TAB>install<TAB>name"; an empty install is written "-",
# since `read` with a whitespace IFS would collapse the empty field and
# shift the columns. No caching of availability here or in the callers: the
# listing is recomputed on every call, so "install the tool, run the
# getter again" works in the same shell.
_wb_print_unavailable_block() {
    local _label="$1" _all="$2" _shown="$3" _noun="${4:-functions}"
    local _shown_nl _timed_out_nl="" _n _needs _install _rows="" _hidden_count=0 _tab _timeout_needs
    _tab=$'\t'
    _shown_nl=$'\n'"${_shown}"$'\n'
    if [[ -s "${_wb_availability_timeout_log}" ]]; then
        _timed_out_nl=$'\n'"$(sort -u "${_wb_availability_timeout_log}" 2>/dev/null)"$'\n'
    fi
    _timeout_needs="availability check timed out (> ${WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS}s)"

    while IFS= read -r _n; do
        [[ -z "${_n}" ]] && continue
        [[ "${_shown_nl}" == *$'\n'"${_n}"$'\n'* ]] && continue
        _hidden_count=$((_hidden_count + 1))
        if [[ "${_timed_out_nl}" == *$'\n'"${_n}"$'\n'* ]]; then
            _needs="${_timeout_needs}"
            _install="-"
        else
            # Read the variables directly rather than through the two
            # read-back functions: those print, so each call is a subshell.
            _wb_availability_key "${_n}"
            eval "_needs=\"\${_wb_availability_reason_${_wb_availability_key_result}:-}\""
            eval "_install=\"\${_wb_availability_install_${_wb_availability_key_result}:-}\""
            [[ -n "${_needs}" ]] || _needs="module gave no reason (predicate reports unavailable)"
            [[ -n "${_install}" ]] || _install="-"
        fi
        _rows="${_rows}${_needs}${_tab}${_install}${_tab}${_n}"$'\n'
    done <<< "${_all}"

    [[ "${_hidden_count}" -eq 0 ]] && return 0

    if [[ "${_wb_functions_compact:-false}" == "true" ]]; then
        local _count _key _summary=""
        while read -r _count _key; do
            _summary="${_summary:+${_summary}, }${_key} (${_count})"
        done < <(
            printf '%s' "${_rows}" \
                | while IFS="${_tab}" read -r _needs _install _n; do
                    if [[ "${_install}" != "-" ]]; then
                        printf '%s\n' "${_install}"
                    else
                        printf '%s\n' "${_needs}"
                    fi
                done \
                | LC_ALL=C sort | uniq -c | sed -E 's/^ +//' | LC_ALL=C sort -t ' ' -k1,1nr -k2
        )
        echo "  ${_hidden_count} ${_noun} need tooling you don't have: ${_summary} — run 'wb functions' for details"
        return 0
    fi

    echo
    echo "[INFO] ${_label} — available once tooling is installed:"
    local _wb_known_tools=$'\n' _wb_unknown_tools=$'\n'
    local _cur_needs="" _cur_install="" _cur_names="" _started="false"
    while IFS="${_tab}" read -r _needs _install _n; do
        if [[ "${_started}" == "true" ]] && { [[ "${_needs}" != "${_cur_needs}" ]] || [[ "${_install}" != "${_cur_install}" ]]; }; then
            _wb_print_unavailable_group "${_cur_needs}" "${_cur_install}" "${_cur_names}"
            _cur_names=""
        fi
        _started="true"
        _cur_needs="${_needs}"
        _cur_install="${_install}"
        _cur_names="${_cur_names}${_n}"$'\n'
    done < <(printf '%s' "${_rows}" | LC_ALL=C sort -t "${_tab}" -k1,1 -k2,2 -k3,3)
    _wb_print_unavailable_group "${_cur_needs}" "${_cur_install}" "${_cur_names}"
}

# ── Alias definitions that yield (docs/decisions-log.md D124) ─────────────
# Workbench never replaces an alias or function it did not define. A module
# defines an alias only through workbench_alias_define; if the name is
# already in use, the existing definition stays, nothing is defined, and the
# loader reports the clash once (lib/loader.sh) and `wb status` lists it.
#
# Why this matters beyond "don't clobber": bash expands an alias when a line
# is READ, including the name in `name() {`. Once an alias exists, a host
# file that defines a function of the same name fails to parse
# ("syntax error near unexpected token `('"). Yielding to a function is
# what keeps a re-sourced host profile working.
#
# Shared state, WORKBENCH_-prefixed and never unset by the loader's reset:
#   WORKBENCH_ALIASES_OURS   space-separated names workbench has defined in
#                            this shell. Never cleared, so a reload
#                            refreshes our own aliases instead of
#                            reporting them as someone else's.
#   WORKBENCH_ALIAS_VALUES   newline-separated name=value records: the value
#                            workbench last set for each name in OURS. It is
#                            how a reload tells "still the alias we set, so
#                            refresh it" from "the user has put their own in
#                            its place, so leave it". Later records win.
#   WORKBENCH_ALIAS_CLASHES  newline-separated name|module|kind|value
#                            records. The loader empties it at the start
#                            of each pass, so a clash the user has since
#                            fixed disappears.
# Not exported. Space/newline-delimited strings, not arrays: bash 3.2 has
# no associative arrays. BASH_ALIASES is not read for the same reason.
WORKBENCH_ALIASES_OURS="${WORKBENCH_ALIASES_OURS:-}"
WORKBENCH_ALIAS_VALUES="${WORKBENCH_ALIAS_VALUES:-}"
WORKBENCH_ALIAS_CLASHES="${WORKBENCH_ALIAS_CLASHES:-}"

# workbench_alias_define <name> <module> <value>
# Returns 0 if the alias was defined (or refreshed, or already identical),
# 1 if an existing definition was left in place.
#
# The name is free when any of these holds:
#   1. workbench defined it earlier in this shell and it is still the alias
#      workbench set (a reload refreshes it, so a module update's new value
#      takes effect); or nothing of that name exists now,
#   2. nothing of that name exists,
#   3. an alias exists and its definition is identical to <value>'s.
# It is not free when a function of that name exists (never compared), or a
# different alias exists. That includes an alias workbench set earlier and
# the user has since replaced: it stops being workbench's, and a reload
# (`wb reload`) leaves the user's version in place. A command on PATH is not
# a clash: aliases such as cat, top and python shadow commands on purpose.
#
# `builtin` in front of alias, unalias and typeset is deliberate: this
# body must not be rewritten by a host alias of the same name (D110). The
# subshells below run only when an alias of that name already exists, so
# the normal path forks nothing.
workbench_alias_define() {
    local name="$1" module="$2" value="$3" existing wanted kind="" prev="" found="" line pair half
    local newline=$'\n' flat padded
    flat="${value//"${newline}"/ }"

    case " ${WORKBENCH_ALIASES_OURS:-} " in
        *" ${name} "*)
            # Defined by workbench earlier in this shell: a reload. Check
            # that what is there now is still what workbench set.
            if builtin typeset -f "${name}" >/dev/null 2>&1; then
                kind="function"
            elif builtin alias "${name}" >/dev/null 2>&1; then
                while IFS= read -r line; do
                    case "${line}" in
                        "${name}="*) prev="${line#*=}"; found="yes" ;;
                    esac
                done <<< "${WORKBENCH_ALIAS_VALUES:-}"
                # With no record (state from before values were kept) there
                # is nothing to compare, so refresh as a reload always did.
                if [[ -n "${found}" ]]; then
                    # One subshell prints the alias as it is, then as it
                    # would read had workbench's own value been set: the two
                    # texts, a newline between. Equal texts make the halves
                    # of that string equal, a newline in the middle (a value
                    # with a newline of its own is still compared whole).
                    # shellcheck disable=SC2139  # expands now, in a subshell that keeps nothing
                    pair="$( builtin alias "${name}"; builtin unalias "${name}"; builtin alias "${name}=${prev}"; builtin alias "${name}" )"  # wb-allow-bare-alias
                    half=$(( (${#pair} - 1) / 2 ))
                    if [[ $(( ${#pair} % 2 )) -ne 1 || "${pair:${half}:1}" != "${newline}" \
                        || "${pair:0:${half}}" != "${pair:$(( half + 1 ))}" ]]; then
                        kind="alias"
                    fi
                fi
            fi
            if [[ -z "${kind}" ]]; then
                # shellcheck disable=SC2139  # the value is meant to expand now, as a plain alias would
                builtin alias "${name}=${value}"  # wb-allow-bare-alias
                # A new record only when the value changed: a reload that
                # changes nothing adds nothing.
                [[ "${found}" == "yes" && "${prev}" == "${flat}" ]] \
                    || WORKBENCH_ALIAS_VALUES="${WORKBENCH_ALIAS_VALUES:-}${name}=${flat}${newline}"
                return 0
            fi
            # Replaced since by something of the user's: no longer ours.
            padded=" ${WORKBENCH_ALIASES_OURS:-} "
            padded="${padded/ ${name} / }"
            WORKBENCH_ALIASES_OURS="${padded% }"
            ;;
        *)
            if builtin typeset -f "${name}" >/dev/null 2>&1; then
                kind="function"
            elif builtin alias "${name}" >/dev/null 2>&1; then
                # An alias exists. Print what ours would look like, in this
                # shell's own format (bash: alias gd='git diff'; zsh:
                # gd='git diff'), and compare. Identical means there is
                # nothing to protect. The test above is a plain builtin and
                # forks nothing; only this branch forks, so a free name (the
                # normal case) costs no process.
                existing="$(builtin alias "${name}" 2>/dev/null)"
                # shellcheck disable=SC2139  # same: expands now, in a subshell that keeps nothing
                wanted="$( builtin unalias "${name}"; builtin alias "${name}=${value}"; builtin alias "${name}" )"  # wb-allow-bare-alias
                if [[ "${existing}" == "${wanted}" ]]; then
                    WORKBENCH_ALIASES_OURS="${WORKBENCH_ALIASES_OURS:-} ${name}"
                    WORKBENCH_ALIAS_VALUES="${WORKBENCH_ALIAS_VALUES:-}${name}=${flat}${newline}"
                    return 0
                fi
                kind="alias"
            else
                # shellcheck disable=SC2139  # same
                builtin alias "${name}=${value}"  # wb-allow-bare-alias
                WORKBENCH_ALIASES_OURS="${WORKBENCH_ALIASES_OURS:-} ${name}"
                WORKBENCH_ALIAS_VALUES="${WORKBENCH_ALIAS_VALUES:-}${name}=${flat}${newline}"
                return 0
            fi
            ;;
    esac

    # name|module|kind|value, one record per line. value is last so it may
    # contain "|"; a newline in it would split the record, so it is flat.
    WORKBENCH_ALIAS_CLASHES="${WORKBENCH_ALIAS_CLASHES:-}${name}|${module}|${kind}|${flat}${newline}"
    return 1
}

# workbench_alias_is_ours <name>
# True when workbench has defined an alias of that name in this shell.
workbench_alias_is_ours() {
    case " ${WORKBENCH_ALIASES_OURS:-} " in
        *" ${1} "*) return 0 ;;
    esac
    return 1
}

# _wb_alias_clash_names
# Names workbench did not set because they were already in use: this shell's
# live record plus the list the last interactive shell start persisted.
# Both are read because `wb functions` runs as its own process and sees no
# live shell state, only the file.
_wb_alias_clash_names() {
    local _clash_file _name _rest
    _clash_file="${XDG_DATA_HOME:-${HOME}/.local/share}/workbench/alias-clashes.list"
    while IFS='|' read -r _name _rest; do
        [[ -n "${_name}" ]] && printf '%s\n' "${_name}"
    done <<< "${WORKBENCH_ALIAS_CLASHES:-}"
    if [[ -r "${_clash_file}" ]]; then
        while IFS='|' read -r _name _rest || [[ -n "${_name}" ]]; do
            [[ -n "${_name}" ]] && printf '%s\n' "${_name}"
        done < "${_clash_file}"
    fi
}

# _wb_alias_drop_clashed
# Filter: reads alias names on stdin, one per line, and prints those that
# are not clashed. A clashed name is the host's alias or function, not
# workbench's, so no listing may show it under a module's heading (D124).
_wb_alias_drop_clashed() {
    local _clashed _n
    _clashed=$'\n'"$(_wb_alias_clash_names)"$'\n'
    while IFS= read -r _n; do
        [[ -n "${_n}" ]] || continue
        case "${_clashed}" in
            *$'\n'"${_n}"$'\n'*) continue ;;
        esac
        printf '%s\n' "${_n}"
    done
}

# ── Getter pattern ────────────────────────────────────────────────────────
# Two generic primitives every "get-<domain>-functions" getter is built from
# — verbatim from the donor codebase, already domain-agnostic. Private
# (_-prefixed) functions are always excluded from the function extractor;
# there's no equivalent alias convention so none are excluded there.
#
# _extract_function_names matches all three definition forms, with or
# without leading whitespace: `name()`, `function name() {` and
# `function name {` (docs/decisions-log.md D89).
_extract_function_names() {
    grep -Eho \
        -e '^[[:space:]]*[a-zA-Z_-][a-zA-Z0-9_-]*[[:space:]]*\(\)' \
        -e '^[[:space:]]*function[[:space:]]+[a-zA-Z_-][a-zA-Z0-9_-]*' \
        "$@" 2>/dev/null \
        | sed -E 's/^[[:space:]]*//; s/^function[[:space:]]+//; s/[[:space:]]*\(\)$//' \
        | grep -v '^_' \
        | sort -u
}

#
# _extract_alias_names matches `alias NAME=` and, since Core API 1.10,
# `workbench_alias_define NAME <module> <value>` (D124). Both must start the
# line, so a definition belongs in an if-block, not after `&&`.
_extract_alias_names() {
    grep -Eho \
        -e '^[[:space:]]*alias [a-zA-Z0-9_.-]+=' \
        -e '^[[:space:]]*workbench_alias_define [a-zA-Z0-9_.-]+[[:space:]]' \
        "$@" 2>/dev/null \
        | sed -E 's/^[[:space:]]*(alias|workbench_alias_define) ([a-zA-Z0-9_.-]+)[=[:space:]].*/\2/' \
        | sort -u
}

# $1 label   $2 pattern (ERE, "" = none, leading "!" = exclude)   $3.. files
_get_functions_in() {
    local _label="$1" _pattern="$2"; shift 2
    echo
    echo "[INFO] ${_label}:"
    if [[ $# -eq 0 ]]; then
        echo "  (no files given)"; echo; return 1
    fi
    local _names; _names="$(_extract_function_names "$@")"
    if [[ "${_pattern}" == \!* ]]; then
        _names="$(printf '%s\n' "${_names}" | grep -Ev "${_pattern#!}")"
    elif [[ -n "${_pattern}" ]]; then
        _names="$(printf '%s\n' "${_names}" | grep -E "${_pattern}")"
    fi
    local _names_all="${_names}"
    # A getter runs in the interactive shell, whose timeout log is never
    # reset by `wb functions`; clear it so a name that timed out on an
    # earlier call isn't reported as timed out now.
    _wb_availability_timeout_reset
    _names="$(printf '%s\n' "${_names}" | _wb_filter_available_names)"
    if [[ -z "${_names}" ]]; then
        echo "  (none)"
    else
        printf '%s\n' "${_names}" | column
    fi
    _wb_print_unavailable_block "${_label}" "${_names_all}" "${_names}" functions
    echo
}

# $1 label   $2 pattern (ERE, "" = none, leading "!" = exclude)   $3.. files
_get_aliases_in() {
    local _label="$1" _pattern="$2"; shift 2
    echo
    echo "[INFO] ${_label}:"
    if [[ $# -eq 0 ]]; then
        echo "  (no files given)"; echo; return 1
    fi
    local _names; _names="$(_extract_alias_names "$@")"
    # A name workbench left alone because the host already had it is the
    # host's, not this module's: never list it here (D124).
    _names="$(printf '%s\n' "${_names}" | _wb_alias_drop_clashed)"
    if [[ "${_pattern}" == \!* ]]; then
        _names="$(printf '%s\n' "${_names}" | grep -Ev "${_pattern#!}")"
    elif [[ -n "${_pattern}" ]]; then
        _names="$(printf '%s\n' "${_names}" | grep -E "${_pattern}")"
    fi
    local _names_all="${_names}"
    _wb_availability_timeout_reset
    _names="$(printf '%s\n' "${_names}" | _wb_filter_available_names)"
    if [[ -z "${_names}" ]]; then
        echo "  (none)"
    else
        printf '%s\n' "${_names}" | column
    fi
    _wb_print_unavailable_block "${_label}" "${_names_all}" "${_names}" aliases
    echo
}

# _wb_module_getter <module> <function>
# The body of every core-generated getter (docs/decisions-log.md D89).
# Lists the functions and aliases in <module>'s registered shell files —
# the same files the loader sources, read from its register.list — so it
# needs no BASH_SOURCE and works the same in bash and zsh. Platform and
# distro files that don't apply to this host are skipped, same rule as the
# loader. The label comes from the module's getters.list.
_wb_module_getter() {
    local _module="$1" _fn="$2"
    local _root _dir _label="" _line_fn _line_label _path _tier _base
    local -a _files=()

    if command -v workbench_modules_dir &>/dev/null; then
        _root="$(workbench_modules_dir)"
    else
        _root="${WORKBENCH_MODULES_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/workbench/modules}"
    fi
    _dir="${_root}/${_module}"

    if [[ -f "${_dir}/getters.list" ]]; then
        while IFS='|' read -r _line_fn _line_label; do
            if [[ "${_line_fn}" == "${_fn}" ]]; then
                _label="${_line_label}"
                break
            fi
        done < "${_dir}/getters.list"
    fi
    [[ -n "${_label}" ]] || _label="${_module}"

    if [[ -f "${_dir}/register.list" ]]; then
        while IFS='|' read -r _path _tier; do
            [[ -z "${_path}" ]] && continue
            case "${_tier}" in
                platform|distro)
                    _base="$(basename "${_path}" .sh)"
                    if command -v _wb_loader_should_source_by_name &>/dev/null; then
                        _wb_loader_should_source_by_name "${_tier}" "${_base}" || continue
                    fi
                    ;;
            esac
            _files+=("${_path}")
        done < "${_dir}/register.list"
    fi

    if [[ "${#_files[@]}" -eq 0 ]]; then
        echo
        echo "[INFO] ${_label}: no shell content registered"
        echo
        return 0
    fi

    _get_functions_in "${_label} — functions" "" "${_files[@]}"
    if [[ -n "$(_extract_alias_names "${_files[@]}")" ]]; then
        _get_aliases_in "${_label} — aliases" "" "${_files[@]}"
    fi
}

# _wb_print_live_names <label> <newline-separated names>
# Same output shape as _get_functions_in/_get_aliases_in (availability
# gating, column formatting, unavailable-names block) but for a caller that
# already has its candidate name list from live shell state rather than
# a set of files to grep — used by _wb_cmd_functions' own top-level
# listing (bin/wb) to avoid re-reading every eager file a second time
# after already sourcing it once. Does not touch _extract_function_names/
# _extract_alias_names/_get_functions_in/_get_aliases_in themselves —
# those stay file-based and unchanged, since every existing
# get-<domain>-functions getter across every module depends on that
# exact, documented signature (contracts/core-api.md).
_wb_print_live_names() {
    local _label="$1" _names="$2"
    echo
    echo "[INFO] ${_label}:"
    local _names_all="${_names}" _noun="functions"
    # The signature is fixed (every caller depends on it), so the only way
    # to know which kind of name this is — for the compact one-liner — is
    # the label.
    case "${_label}" in
        *[Aa]lias*) _noun="aliases" ;;
    esac
    _names="$(printf '%s\n' "${_names}" | _wb_filter_available_names)"
    if [[ -z "${_names}" ]]; then
        echo "  (none)"
    else
        printf '%s\n' "${_names}" | column
    fi
    _wb_print_unavailable_block "${_label}" "${_names_all}" "${_names}" "${_noun}"
    echo
}

# ── Introspection: get-functions ─────────────────────────────────────────
# The generalised get-functions (docs/architecture.md §3): walks every registered
# module's declared shell/installer/getter entries — driven entirely by
# each module's own register: block, never a hardcoded registry in core.
# Delegates to `wb functions` (bin/wb) rather than re-implementing the
# module-enumeration/manifest-reading logic a second time here — core's own
# `current` snapshot always contains bin/wb, since the whole repo (bin/
# included) is exactly what gets fetched/symlinked as core's own module
# content (principle 4: core is module zero, no special-cased shape).
#
# "$@" is forwarded verbatim so `get-functions` run by hand stays exactly
# equivalent to `wb functions` (same flags, same output) — lib/loader.sh's
# own automatic WORKBENCH_SHOW_FUNCTIONS startup call is the one caller
# that passes --no-pager --no-aliases --compact explicitly
# (docs/decisions-log.md D73, D86); this function itself has no opinion on which flags are used.
get-functions() {
    local core_current="${XDG_DATA_HOME:-${HOME}/.local/share}/workbench/modules/core/current"
    if [[ -x "${core_current}/bin/wb" ]]; then
        "${core_current}/bin/wb" functions "$@"
    else
        log_error "get-functions: workbench-core's bin/wb not found under ${core_current} — is core registered? (wb status)"
        return 1
    fi
}

# ── Config layers and shell hooks (Core API 1.6) ─────────────────────────

# _wb_layers_settle <module>
# Re-places that module's workbench blocks after a module function has
# written to one of their target files (docs/decisions-log.md D82). Call it
# after `git config --global ...` or any other write to a layered file.
# Shells out to the real binary, like get-functions does — the interactive
# shell doesn't load lib/files/.
_wb_layers_settle() {
    [[ -n "${1:-}" ]] || return 0
    command wb files settle "$1" >/dev/null 2>&1 || true
}

# _wb_prompt_hook_registered <function-name>
# True when <function-name> is already hooked into the prompt cycle —
# bash PROMPT_COMMAND (scalar or array), zsh precmd_functions. Lets a
# module install a tool's shell hook (direnv, etc.) only when nothing else
# has, without duplicating it (docs/decisions-log.md D83).
_wb_prompt_hook_registered() {
    local fn="$1"
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        # shellcheck disable=SC2154  # zsh's own array
        [[ " ${precmd_functions[*]:-} " == *" ${fn} "* ]]
    else
        [[ "${PROMPT_COMMAND[*]:-}" == *"${fn}"* ]]
    fi
}
