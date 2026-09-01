#!/usr/bin/env bash
# lib/loader.sh — multi-root shell configuration loader.
#
# The single entry point sourced by a stub in ~/.bashrc and ~/.zshrc
# (rendered by `wb install`/`wb apply` — see ansible/roles/module_sync).
# Rewritten from workbench-precursor's shell/config/loader.sh (which assumed
# a single SHELL_CONFIG_DIR root) to walk every registered, sync-enabled
# module's state directory instead (ARCHITECTURE.md §3) — core is "module
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

# shellcheck source=lib/sync/state.sh
[[ -f "${_wb_loader_lib_dir}/sync/state.sh" ]] && source "${_wb_loader_lib_dir}/sync/state.sh"

# No explicit source of core/version.sh here on purpose — that would be
# exactly the kind of hardcoded "core" special-case this file must never
# have (principle 4, tests/check-loader-multi-root.sh's own check for it).
# lib/core/version.sh is registered like any other core-tier content
# (.dotfiles-sync.yml) and reaches this process the same generic way
# functions.sh already does, via the tier-sourcing loop below — so the
# registration/debug-log lines wait until after that loop, where
# workbench_register_script_version is available if core's own tier loaded
# at all (silently absent otherwise, e.g. a synthetic test with no core
# module registered — no different from any other module's content). See
# the actual registration/debug-log calls after the tier loop below —
# placing them here instead, before core's own tier has been sourced,
# would make workbench_register_script_version unavailable and the
# registration a silent no-op almost every real run.

# ── OS / WSL / Distro / Shell / Arch detection ────────────────────────────────
# Duplicated minimally here (rather than sourced from core's own
# functions.sh) because core's functions.sh is itself only reachable via
# module enumeration below — this is the one piece of detection that has to
# exist before any module, core included, has been located and sourced.
# workbench_detect_platform() (lib/core/functions.sh) is idempotent and
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
    _distro_id="$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")"
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

# ── Local overrides directory (ARCHITECTURE.md §12 D21) ───────────────────────
# Machine-local, outside every module's own tree.
# ${XDG_CONFIG_HOME:-~/.config}/workbench/local/ holds `settings.sh` — the
# reserved-name direct successor to the old single-file `90-local.sh`,
# keeping exactly its two-pass semantics: sourced first (so flags it sets
# gate later tiers) and again at the very end (so it wins over anything a
# later tier also touches) — plus any number of other user-authored `*.sh`
# files, sourced once, together, filename-sorted, immediately after
# settings.sh's final pass (see below). `_wb_loader_source_sh_files_once`
# (defined just below) is the shared safety discipline both that "other
# files" pass and WORKBENCH_USER_EXT_DIR use: bash -n syntax smoke-test,
# skip-and-warn on failure, stamp-cache to avoid re-checking unchanged files
# on every shell start.
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

# _wb_loader_source_sh_files_once <dir> <stamp-file> [exclude-basename]
# Sources every *.sh file directly in <dir> (nullglob-safe, no matches is a
# silent no-op), skipping [exclude-basename] if given. Each file gets a
# `bash -n` syntax smoke-test only on first sight or after it changes
# (tracked via <stamp-file>, `-nt` being a builtin test in both bash and
# zsh) — a failing file is skipped and warned about, and the stamp is
# withheld so it's re-checked (and re-warned) every start until fixed.
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

# ── register.list tier resolution ─────────────────────────────────────────────
# Six tiers, sourced in this fixed order for every loadable module — the
# same order workbench-precursor's loader.sh already enforced, just no
# longer scoped to a single root.
_WB_LOADER_TIERS="env core tools platform distro lazy"

# _wb_loader_should_source_by_name <tier> <basename-without-.sh>
# Filename-as-selector convention for the platform/distro tiers only (every
# other tier sources everything registered for it unconditionally): a
# distro-tier file only loads on a matching WORKBENCH_DISTRO; a
# platform-tier file loads on a matching WORKBENCH_OS (lowercased: Mac ->
# macos) or the literal "wsl" additionally when WORKBENCH_WSL=true.
# Documented in contracts/core-api.md and docs/module-authoring.md — this is
# the one piece of conditional-loading behaviour register.shell[] gets
# without a dedicated manifest field, deliberately kept to a naming
# convention rather than a new schema key.
_wb_loader_should_source_by_name() {
    local tier="$1" base="$2"
    case "${tier}" in
        distro)
            [[ "${base}" == "${WORKBENCH_DISTRO}" ]]
            ;;
        platform)
            local os_name
            case "${WORKBENCH_OS}" in
                Linux) os_name="linux" ;;
                Mac)   os_name="macos" ;;
                *)     os_name="${WORKBENCH_OS}" ;;
            esac
            if [[ "${base}" == "${os_name}" ]]; then
                return 0
            fi
            if [[ "${base}" == "wsl" && "${WORKBENCH_WSL}" == "true" ]]; then
                return 0
            fi
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# _wb_loader_source_tier <tier>
# Sources every registered file declared for <tier>, across every loadable
# module, sorted by module name then by the file's own basename (so a
# module's own numeric-prefix convention, e.g. env/00-core.sh, env/10-x.sh,
# still governs intra-module ordering — exactly as workbench-precursor's
# env/ tier did within its single root).
_wb_loader_source_tier() {
    local tier="$1"
    local name reglist line filepath filetier base

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

# ── WORKBENCH_TRACK_<MODULE> (ARCHITECTURE.md §9.5/D7) ────────────────────────
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
# workbench_register_script_version and workbench_release_version reach
# this shell the same generic way any other core-tier content does
# (lib/core/version.sh via register.list), so neither is available until
# that content has actually been sourced.
command -v workbench_register_script_version &>/dev/null && workbench_register_script_version "lib/loader.sh" "0.1.0" || true
# Gated on WORKBENCH_DEBUG explicitly, before ever calling
# workbench_release_version — not just left to log_debug's own internal
# gate. Bash evaluates a command's arguments (the $(...) substitution)
# before the command (log_debug) itself runs, so `log_debug
# "...$(workbench_release_version)..."` would fork a subshell and exec
# `head` on the VERSION file on *every* shell start regardless of the flag,
# silently contradicting this being debug-gated at all.
if [[ "${WORKBENCH_DEBUG:-false}" == "true" ]] && command -v workbench_release_version &>/dev/null; then
    log_debug "loader: workbench-core release $(workbench_release_version), lib/loader.sh v0.1.0"
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
elif [[ -z "${WORKBENCH_PROMPT_SET:-}" ]]; then
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

# ── Local overrides, second pass (always wins) ────────────────────────────────
# shellcheck disable=SC1090
[[ -f "${WORKBENCH_LOCAL_ENV}" ]] && source "${WORKBENCH_LOCAL_ENV}"

# ── Other local/*.sh files (genuinely open, user-owned content) ───────────────
# Everything in WORKBENCH_LOCAL_DIR except settings.sh itself — functions,
# aliases, whatever — sourced once, together, filename-sorted, immediately
# after settings.sh's final pass. Deliberately flat, not trying to
# reproduce the six loader tiers for local content (ARCHITECTURE.md §12
# D21): this is the right level of complexity for something the loader
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

# ── PATH deduplication ────────────────────────────────────────────────────────
command -v dedupe-path &>/dev/null && dedupe-path 2>/dev/null

# ── Interactive startup ───────────────────────────────────────────────────────
if [[ $- == *i* ]] && [[ "${WORKBENCH_SHOW_FUNCTIONS}" == "true" ]] && command -v get-functions &>/dev/null; then
    get-functions
fi

unset _wb_loader_lib_dir
