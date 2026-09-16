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
_wb_functions_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[[ -f "${_wb_functions_dir}/log.sh" ]] && source "${_wb_functions_dir}/log.sh"
unset _wb_functions_dir

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/core/functions.sh" "0.2.0" || true

# ── OS / WSL / Distro / Shell / Arch detection (run once per session) ───────
# Reconciles loader.sh's inline detection block and functions.sh's separate
# detect-distro() into one routine, per the build brief's §4 callout.
_workbench_detect_platform() {
    [[ "${WORKBENCH_PLATFORM_DETECTED:-false}" == "true" ]] && return 0

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
    else
        WORKBENCH_DISTRO="unknown"
    fi
    export WORKBENCH_DISTRO

    if [[ -n "${ZSH_VERSION:-}" ]]; then
        WORKBENCH_SHELL="zsh"
    elif [[ -n "${BASH_VERSION:-}" ]]; then
        WORKBENCH_SHELL="bash"
    else
        WORKBENCH_SHELL="sh"
    fi
    export WORKBENCH_SHELL

    # New, not a rename: raw `uname -m` output. No universal name-normalizer
    # is provided — see docs/module-authoring.md for the two common
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

_read_prompt_silent() {
    local _rp_prompt="$1"
    local _rp_var="$2"
    local _rp_value
    printf '%s' "${_rp_prompt}" >/dev/tty
    IFS= read -rs _rp_value </dev/tty
    printf '\n' >/dev/tty
    eval "${_rp_var}=\${_rp_value}"
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
# known state, not a failure).
_wb_function_available() {
    [[ "${WORKBENCH_FUNCTIONS_SHOW_ALL:-false}" == "true" ]] && return 0
    local _name="$1" _predicate
    _predicate="_${_name}-available"
    if command -v "${_predicate}" &>/dev/null; then
        "${_predicate}" &>/dev/null
        return $?
    fi
    return 0
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

# _wb_declare_availability <command> <function-name> [<function-name> ...]
# Bulk-declares a "_<name>-available" predicate for each <function-name>,
# each checking the same one <command> via `command -v`. Turns "these N
# names all need the same external tool" into one line instead of N
# near-identical predicate bodies. eval is required to build a function
# whose name is only known at runtime (bash 3.2 has no declare -n) — same
# technique workbench-gpg's own _array_get already uses for array
# indirection. See docs/module-authoring.md "Declaring function
# availability" for the full contract, including when to use
# _wb_alias_availability or a hand-written predicate instead.
_wb_declare_availability() {
    local _cmd="$1"; shift
    local _fn
    for _fn in "$@"; do
        eval "_${_fn}-available() { command -v \"${_cmd}\" &>/dev/null; }"
    done
}

# _wb_alias_availability <check-function> <function-name> [<function-name> ...]
# Bulk-declares a "_<name>-available" predicate for each <function-name>,
# each a thin wrapper around an existing boolean-returning
# <check-function> — for when several names share a check more complex
# than a single command-v (a version/variant check, several required
# tools together) that the module already has, or is worth extracting
# once as a quiet twin of an existing loud "_xxx_require_yyy" preflight
# helper (see the workbench-git and workbench-security examples in
# docs/module-authoring.md).
_wb_alias_availability() {
    local _check="$1"; shift
    local _fn
    for _fn in "$@"; do
        eval "_${_fn}-available() { ${_check}; }"
    done
}

# _wb_function_missing_reason <name>
# If <name>'s predicate was generated by _wb_declare_availability —
# recovered by reading the predicate's own source back via `declare -f`
# and normalising it, then matching the *entire* body against the exact
# literal shape that helper generates — returns the command it checked.
# Anything else (a predicate from _wb_alias_availability, a hand-written
# one, or a body that merely happens to contain a matching substring
# among other conditions) returns empty. This is a read-back of what we
# generated, not an inference about what an arbitrary predicate does —
# printing a reason we can't actually confirm would be a guess, so it
# says nothing instead (same principle as installed-<name>'s
# "unresponsive").
_wb_function_missing_reason() {
    local _name="$1" _predicate _norm
    _predicate="_${_name}-available"
    command -v "${_predicate}" &>/dev/null || return 0
    _norm="$(declare -f "${_predicate}" 2>/dev/null | tr '\n' ' ' | tr -s '[:space:]' ' ')"
    # Two alternatives for the redirect, not one: bash 3.2 (macOS's default
    # /bin/bash) reprints a parsed "&>word" redirection as the older
    # two-token "> word 2>&1" form when declare -f serializes it back out,
    # while bash 4+ reprints it as "&> word" — same redirection, different
    # text, depending only on which bash is running this check, not on
    # anything the predicate itself did differently. Confirmed via a real
    # macOS CI run (workbench-core#75) after the single-form version of
    # this regex silently matched nothing there. Both alternatives are
    # still anchored to the exact rest of the shape, so this stays a
    # read-back of what we generated, not a loosened guess.
    if [[ "${_norm}" =~ ^[a-zA-Z0-9_-]+\ \(\)\ \{\ command\ -v\ \"([A-Za-z0-9_./-]+)\"\ (\&\>\ ?/dev/null|\>\ ?/dev/null\ ?2\>\&1)\ \}\ $ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# _wb_print_hidden_hint <all-names> <shown-names>
# Both newline-separated. If anything was hidden by availability gating,
# prints one summary line: a count, plus the specific missing commands
# for any hidden name _wb_function_missing_reason can confirm, and just
# the count (with the WORKBENCH_FUNCTIONS_SHOW_ALL pointer) for the rest.
# Prints nothing when nothing was hidden — including when
# WORKBENCH_FUNCTIONS_SHOW_ALL=true is set, since _wb_function_available
# already makes filtering a no-op in that case, so <shown-names> equals
# <all-names> and there's nothing to diff.
_wb_print_hidden_hint() {
    local _all="$1" _shown="$2"
    local _n _is_shown _s _hidden_count=0 _reasons="" _reason
    while IFS= read -r _n; do
        [[ -z "${_n}" ]] && continue
        _is_shown="false"
        while IFS= read -r _s; do
            [[ "${_s}" == "${_n}" ]] && { _is_shown="true"; break; }
        done <<< "${_shown}"
        [[ "${_is_shown}" == "true" ]] && continue
        _hidden_count=$((_hidden_count + 1))
        _reason="$(_wb_function_missing_reason "${_n}")"
        if [[ -n "${_reason}" ]] && [[ ",${_reasons}," != *",${_reason},"* ]]; then
            _reasons="${_reasons:+${_reasons}, }${_reason}"
        fi
    done <<< "${_all}"

    [[ "${_hidden_count}" -eq 0 ]] && return 0

    if [[ -n "${_reasons}" ]]; then
        echo "  ${_hidden_count} more hidden (missing: ${_reasons}) — set WORKBENCH_FUNCTIONS_SHOW_ALL=true to see them"
    else
        echo "  ${_hidden_count} more hidden — set WORKBENCH_FUNCTIONS_SHOW_ALL=true to see them"
    fi
}

# ── Getter pattern ────────────────────────────────────────────────────────
# Two generic primitives every "get-<domain>-functions" getter is built from
# — verbatim from the donor codebase, already domain-agnostic. Private
# (_-prefixed) functions are always excluded from the function extractor;
# there's no equivalent alias convention so none are excluded there.
_extract_function_names() {
    grep -Eho '^[[:space:]]*[a-zA-Z_-][a-zA-Z0-9_-]*[[:space:]]*\(\)' "$@" 2>/dev/null \
        | sed -E 's/^[[:space:]]*//; s/[[:space:]]*\(\)$//' \
        | grep -v '^_' \
        | sort -u
}

_extract_alias_names() {
    grep -Eho '^[[:space:]]*alias [a-zA-Z0-9_-]+=' "$@" 2>/dev/null \
        | sed -E 's/^[[:space:]]*alias ([a-zA-Z0-9_-]+)=.*/\1/' \
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
    _names="$(printf '%s\n' "${_names}" | _wb_filter_available_names)"
    if [[ -z "${_names}" ]]; then
        echo "  (none)"
    else
        printf '%s\n' "${_names}" | column
    fi
    _wb_print_hidden_hint "${_names_all}" "${_names}"
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
    if [[ "${_pattern}" == \!* ]]; then
        _names="$(printf '%s\n' "${_names}" | grep -Ev "${_pattern#!}")"
    elif [[ -n "${_pattern}" ]]; then
        _names="$(printf '%s\n' "${_names}" | grep -E "${_pattern}")"
    fi
    local _names_all="${_names}"
    _names="$(printf '%s\n' "${_names}" | _wb_filter_available_names)"
    if [[ -z "${_names}" ]]; then
        echo "  (none)"
    else
        printf '%s\n' "${_names}" | column
    fi
    _wb_print_hidden_hint "${_names_all}" "${_names}"
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
get-functions() {
    local core_current="${XDG_DATA_HOME:-${HOME}/.local/share}/workbench/modules/core/current"
    if [[ -x "${core_current}/bin/wb" ]]; then
        "${core_current}/bin/wb" functions
    else
        log_error "get-functions: workbench-core's bin/wb not found under ${core_current} — is core registered? (wb status)"
        return 1
    fi
}
