#!/usr/bin/env bash
# lib/core/installers-common.sh — shared install-helper primitives, promoted
# to Core API surface (ARCHITECTURE.md §12 D34) rather than left to be
# duplicated per module. Every ecosystem module's `install-*` functions
# (declared via `register.installers[]`, docs/module-authoring.md) can rely
# on these being sourced already — this file is registered in core's own
# `.dotfiles-sync.yml` at `tier: core`, the same tier `functions.sh`/
# `version.sh` already use, so it loads before any module's own `lazy`-tier
# installer file could possibly run.
#
# Only `_`-prefixed helpers live here (contracts/core-api.md's naming
# convention, ARCHITECTURE.md §12 D24) — none of these are meant to show up
# in `wb functions`/`get-functions` output. Bash 3.2 / zsh compatible: no
# associative arrays, no ${var,,}/${var^^}, no mapfile.
[[ -n "${_WORKBENCH_INSTALLERS_COMMON_LOADED:-}" ]] && return 0
_WORKBENCH_INSTALLERS_COMMON_LOADED=1

# _download_file_robust <url> <output_file>
# Retried, resumable download via curl — falls back to HTTP/1.1 if the
# default negotiation stalls, and discards a truncated partial file rather
# than leaving a corrupt artifact behind.
_download_file_robust() {
    local url="$1" output_file="$2"
    local max_retries=3 retry_count=0

    [[ -z "${url}" || -z "${output_file}" ]] && { log_error "_download_file_robust: URL and output required"; return 1; }

    while [[ ${retry_count} -lt ${max_retries} ]]; do
        retry_count=$((retry_count + 1))
        [[ ${retry_count} -gt 1 ]] && { log_info "Download attempt ${retry_count}/${max_retries}..."; sleep 2; }

        if curl -L -C - --connect-timeout 30 --max-time 1800 --retry 2 --retry-delay 1 -o "${output_file}" "${url}"; then
            return 0
        fi

        log_warn "Retrying with HTTP/1.1..."
        if curl --http1.1 -L -C - --connect-timeout 30 --max-time 1800 -o "${output_file}" "${url}"; then
            return 0
        fi

        if [[ -f "${output_file}" ]]; then
            local sz
            sz="$(stat -c%s "${output_file}" 2>/dev/null || stat -f%z "${output_file}" 2>/dev/null || echo 0)"
            [[ "${sz}" -lt 1024 ]] && rm -f "${output_file}"
        fi
    done

    log_error "All download attempts failed after ${max_retries} tries"
    return 1
}

# ── Shared npm helpers ───────────────────────────────────────────────────────
# Used by any module installing an npm-distributed CLI (e.g. workbench-ai's
# `install-copilot-cli`).

# _node_version_at_least <major>
# True if the active node's major version is >= <major>.
_node_version_at_least() {
    local want="$1" have
    command -v node &>/dev/null || return 1
    have="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
    [[ -n "${have}" && "${have}" =~ ^[0-9]+$ && "${have}" -ge "${want}" ]]
}

# _ensure_npm — ensure npm is usable, preferring nvm. Returns 0 if npm resolves.
# Priority: live npm → nvm stub → unsourced nvm (install LTS) → package manager.
_ensure_npm() {
    if command -v npm &>/dev/null; then
        return 0
    fi

    if declare -f npm &>/dev/null || declare -f nvm &>/dev/null; then
        log_info "Activating nvm to access npm..."
        nvm --version &>/dev/null || true
        command -v npm &>/dev/null && return 0
    fi

    local nvm_dir="${NVM_DIR:-${HOME}/.nvm}"
    if [[ -s "${nvm_dir}/nvm.sh" ]]; then
        log_info "Sourcing nvm..."
        # shellcheck disable=SC1091
        source "${nvm_dir}/nvm.sh"
        command -v npm &>/dev/null && return 0
        log_info "nvm active but no node version installed — installing LTS..."
        nvm install --lts
        nvm use --lts
        command -v npm &>/dev/null && return 0
    fi

    log_info "nvm not found — attempting to install Node.js via package manager..."
    [[ -z "${PACKAGE_MANAGER:-}" ]] && { detect-package-manager || return 1; }
    local elevation_cmd
    elevation_cmd="$(get-elevation-command)" || return 1
    case "${PACKAGE_MANAGER}" in
        dnf)    ${elevation_cmd} dnf install -y nodejs npm ;;
        yum)    ${elevation_cmd} yum install -y nodejs npm ;;
        apt)    ${elevation_cmd} apt-get install -y nodejs npm ;;
        zypper) ${elevation_cmd} zypper install -y nodejs npm ;;
        pacman) ${elevation_cmd} pacman -S --noconfirm nodejs npm ;;
        brew)   brew install node ;;
        *) log_error "Cannot install Node.js: no supported package manager"; return 1 ;;
    esac
    command -v npm &>/dev/null && return 0
    return 1
}

# _npm_global_install <package>
# Installs/updates a global npm package. If npm's prefix is system-owned
# (/usr, /opt) the install is redirected to ~/.local so no root is required.
_npm_global_install() {
    local pkg="$1"
    [[ -z "${pkg}" ]] && { log_error "_npm_global_install: package name required"; return 1; }

    local npm_prefix install_prefix=""
    npm_prefix="$(npm config get prefix 2>/dev/null)"
    case "${npm_prefix}" in
        /usr/*|/opt/*|/usr|/opt)
            install_prefix="${HOME}/.local"
            log_info "System npm prefix (${npm_prefix}) — installing to ${install_prefix}"
            ;;
        *)
            log_info "npm prefix is user-writable (${npm_prefix})"
            ;;
    esac

    mkdir -p "${HOME}/.local/bin"
    if [[ -n "${install_prefix}" ]]; then
        npm install -g --prefix "${install_prefix}" "${pkg}" || return 1
        if [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
            log_warn "${HOME}/.local/bin is not on PATH — add it in ~/.config/workbench/local/settings.sh"
        fi
    else
        npm install -g "${pkg}" || return 1
    fi
}

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/core/installers-common.sh" "0.1.0" || true
