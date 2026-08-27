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

# ── OS / WSL / Distro / Shell / Arch detection (run once per session) ───────
# Reconciles loader.sh's inline detection block and functions.sh's separate
# detect-distro() into one routine, per the build brief's §4 callout.
workbench_detect_platform() {
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
workbench_detect_platform

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

# ── Privilege elevation helpers ───────────────────────────────────────────
sudo-test() {
    if sudo -l -U "${USER}" &>/dev/null; then
        return 0
    elif command -v run0 &>/dev/null && run0 -l -U "${USER}" &>/dev/null; then
        log_debug "User has run0 access"
        return 0
    fi
    log_error "No sudo/run0 access for ${USER}"
    return 1
}

get-elevation-command() {
    if command -v sudo &>/dev/null && sudo -l -U "${USER}" &>/dev/null; then
        echo "sudo"
        return 0
    elif command -v run0 &>/dev/null && run0 -l -U "${USER}" &>/dev/null; then
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
    ${elevation_cmd} ${cmd_to_run}
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
    if [[ -z "${_names}" ]]; then
        echo "  (none)"
    else
        printf '%s\n' "${_names}" | column
    fi
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
    _names="$(printf '%s\n' "${_names}" | while IFS= read -r _an; do
        [[ -z "${_an}" ]] && continue
        alias "${_an}" &>/dev/null && echo "${_an}"
    done)"
    if [[ -z "${_names}" ]]; then
        echo "  (none)"
    else
        printf '%s\n' "${_names}" | column
    fi
    echo
}
