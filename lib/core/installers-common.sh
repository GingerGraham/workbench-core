#!/usr/bin/env bash
# lib/core/installers-common.sh — shared install-helper primitives, promoted
# to Core API surface (docs/decisions-log.md D34) rather than left to be
# duplicated per module. Every ecosystem module's `install-*` functions
# (declared via `register.installers[]`, docs/module-authoring.md) can rely
# on these being sourced already — this file is registered in core's own
# `.dotfiles-sync.yml` at `tier: core`, the same tier `functions.sh`/
# `version.sh` already use, so it loads before any module's own `lazy`-tier
# installer file could possibly run.
#
# Only `_`-prefixed helpers live here (contracts/core-api.md's naming
# convention, docs/decisions-log.md D24) — none of these are meant to show up
# in `wb functions`/`get-functions` output. Bash 3.2 / zsh compatible: no
# associative arrays, no ${var,,}/${var^^}, no mapfile.
[[ -n "${_WORKBENCH_INSTALLERS_COMMON_LOADED:-}" ]] && return 0
_WORKBENCH_INSTALLERS_COMMON_LOADED=1

# _wb_fetch_proto
# The curl --proto/--proto-redir value for every download: https only.
# _WB_TEST_FETCH_PROTO exists solely so tests/check-fetch-verified.sh can use
# file:// fixtures; it is deliberately underscore-prefixed and not part of the
# documented Core API.
_wb_fetch_proto() {
    printf '%s\n' "${_WB_TEST_FETCH_PROTO:-=https}"
}

# _download_file_robust <url> <output_file>
# Retried download via curl, https-only (redirects included), failing on any
# HTTP error status. Falls back to HTTP/1.1 if the default negotiation stalls.
#
# Always downloads into a fresh temp file beside <output_file> and renames it
# into place only on success. It never resumes onto, or writes through,
# whatever already exists at <output_file>: resuming onto an existing binary
# produced spliced files on re-install (security review M2, D74). On failure
# <output_file> is left exactly as it was.
_download_file_robust() {
    local url="$1" output_file="$2"
    local max_retries=3 retry_count=0 proto out_dir tmp_file

    [[ -z "${url}" || -z "${output_file}" ]] && { log_error "_download_file_robust: URL and output required"; return 1; }

    proto="$(_wb_fetch_proto)"
    out_dir="$(dirname "${output_file}")"
    mkdir -p "${out_dir}" || { log_error "_download_file_robust: cannot create ${out_dir}"; return 1; }
    tmp_file="$(mktemp "${out_dir}/.wb-download.XXXXXX")" || { log_error "_download_file_robust: cannot create a temp file in ${out_dir}"; return 1; }

    while [[ ${retry_count} -lt ${max_retries} ]]; do
        retry_count=$((retry_count + 1))
        [[ ${retry_count} -gt 1 ]] && { log_info "Download attempt ${retry_count}/${max_retries}..."; sleep 2; }

        if curl --fail --location --proto "${proto}" --proto-redir "${proto}" \
                --connect-timeout 30 --max-time 1800 --retry 2 --retry-delay 1 \
                --output "${tmp_file}" "${url}"; then
            chmod 0644 "${tmp_file}"
            mv -f "${tmp_file}" "${output_file}"
            return 0
        fi

        log_warn "Retrying with HTTP/1.1..."
        if curl --http1.1 --fail --location --proto "${proto}" --proto-redir "${proto}" \
                --connect-timeout 30 --max-time 1800 \
                --output "${tmp_file}" "${url}"; then
            chmod 0644 "${tmp_file}"
            mv -f "${tmp_file}" "${output_file}"
            return 0
        fi
    done

    rm -f "${tmp_file}"
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
    [[ "${want}" =~ ^[0-9]+$ ]] || { log_error "_node_version_at_least: <major> must be a numeric version, got '${want}'"; return 1; }
    command -v node &>/dev/null || return 1
    have="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
    [[ -n "${have}" && "${have}" =~ ^[0-9]+$ ]] || return 1
    [[ "${have}" -ge "${want}" ]]
}

# _ensure_npm — ensure npm is usable, preferring nvm. Returns 0 if npm resolves.
# Priority: live npm → nvm stub → unsourced nvm (install LTS) → package manager.
_ensure_npm() {
    if command -v npm &>/dev/null; then
        return 0
    fi

    if command -v npm &>/dev/null || command -v nvm &>/dev/null; then
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

# _wb_sha256 <file>
# Prints the lowercase hex SHA-256 of <file>. sha256sum (Linux) or
# shasum -a 256 (macOS).
_wb_sha256() {
    local file="$1" out
    if command -v sha256sum &>/dev/null; then
        out="$(sha256sum "${file}" 2>/dev/null)" || return 1
    elif command -v shasum &>/dev/null; then
        out="$(shasum -a 256 "${file}" 2>/dev/null)" || return 1
    else
        log_error "_wb_sha256: neither sha256sum nor shasum is available"
        return 1
    fi
    printf '%s\n' "${out%% *}" | tr '[:upper:]' '[:lower:]'
}

# _wb_gh_asset_digest <releases-api-json> <browser_download_url>
# Prints the hex SHA-256 GitHub publishes for one release asset (the asset's
# "digest": "sha256:<hex>" field), or nothing when the asset is absent or its
# digest is null. Relies on "digest" preceding "browser_download_url" inside
# each asset object — the same ordering-dependence the existing grep/sed JSON
# readers in this codebase accept. Integrity only: it proves the bytes are the
# ones GitHub stored for that release, not that upstream is trustworthy.
_wb_gh_asset_digest() {
    local api_json="$1" asset_url="$2"
    printf '%s' "${api_json}" \
        | grep -oE '"(digest|browser_download_url)"[[:space:]]*:[[:space:]]*("[^"]*"|null)' \
        | sed -E 's/^"(digest|browser_download_url)"[[:space:]]*:[[:space:]]*"?([^"]*)"?$/\1 \2/' \
        | awk -v want="${asset_url}" '
            $1 == "digest" { last_digest = $2; next }
            $1 == "browser_download_url" {
                if ($2 == want) { print last_digest; exit }
                last_digest = ""
            }
          ' \
        | sed -n 's/^sha256://p'
}

# _wb_fetch_verified <url> <dest> <expectation> [asset-name]
# Downloads <url>, verifies its SHA-256, and only then moves it to <dest>.
# Fails closed: any missing, malformed or mismatching hash leaves <dest>
# untouched and returns non-zero.
#
# <expectation> is one of:
#   <64 hex chars>      the expected SHA-256 itself
#   sums:<url>          an upstream checksums file, lines "<hex>  <name>" or
#                       "<hex> *<name>"; the line for [asset-name] is used
#                       (default: the last path segment of <url>)
#   hashfile:<url>      a file whose first whitespace-separated token is the
#                       hex digest (e.g. kubectl's .sha256, helm's .sha256sum)
_wb_fetch_verified() {
    local url="$1" dest="$2" expect="$3" asset="${4:-}"
    local expected="" actual tmp_dir rc

    if [[ -z "${url}" || -z "${dest}" || -z "${expect}" ]]; then
        log_error "_wb_fetch_verified: usage: <url> <dest> <sha256|sums:URL|hashfile:URL> [asset-name]"
        return 2
    fi
    [[ -z "${asset}" ]] && asset="${url##*/}"

    tmp_dir="$(mktemp -d)" || { log_error "_wb_fetch_verified: mktemp failed"; return 1; }

    case "${expect}" in
        sums:*)
            if ! _download_file_robust "${expect#sums:}" "${tmp_dir}/sums"; then
                rm -rf "${tmp_dir}"
                return 1
            fi
            expected="$(awk -v a="${asset}" '$2 == a || $2 == "*" a { print $1; exit }' "${tmp_dir}/sums")"
            ;;
        hashfile:*)
            if ! _download_file_robust "${expect#hashfile:}" "${tmp_dir}/hash"; then
                rm -rf "${tmp_dir}"
                return 1
            fi
            expected="$(awk 'NR == 1 { print $1; exit }' "${tmp_dir}/hash")"
            ;;
        *)
            expected="${expect}"
            ;;
    esac
    expected="$(printf '%s' "${expected}" | tr '[:upper:]' '[:lower:]')"

    if ! [[ "${expected}" =~ ^[0-9a-f]{64}$ ]]; then
        log_error "_wb_fetch_verified: no valid SHA-256 found for ${asset} — refusing to install it"
        rm -rf "${tmp_dir}"
        return 1
    fi

    if ! _download_file_robust "${url}" "${tmp_dir}/payload"; then
        rm -rf "${tmp_dir}"
        return 1
    fi

    actual="$(_wb_sha256 "${tmp_dir}/payload")" || { rm -rf "${tmp_dir}"; return 1; }
    if [[ "${actual}" != "${expected}" ]]; then
        log_error "_wb_fetch_verified: SHA-256 mismatch for ${asset} (expected ${expected}, got ${actual}) — refusing to install it"
        rm -rf "${tmp_dir}"
        return 1
    fi

    mkdir -p "$(dirname "${dest}")" && mv -f "${tmp_dir}/payload" "${dest}"
    rc=$?
    rm -rf "${tmp_dir}"
    return ${rc}
}

# _wb_key_has_fingerprint <keyfile> <fingerprint>
# True iff the OpenPGP key file (armored or binary) contains a primary key
# whose fingerprint is exactly <fingerprint> (40 hex; spaces and case
# ignored). Modules call this before trusting a vendor repository key with
# rpm --import or an apt keyring (security review M4). Uses a throwaway
# GNUPGHOME so the user's keyring is never touched.
_wb_key_has_fingerprint() {
    local keyfile="$1" want="$2" gnupg_home rc
    command -v gpg &>/dev/null || { log_error "_wb_key_has_fingerprint: gpg is required"; return 1; }
    want="$(printf '%s' "${want}" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
    gnupg_home="$(mktemp -d)" || return 1
    gpg --homedir "${gnupg_home}" --show-keys --with-colons "${keyfile}" 2>/dev/null \
        | awk -F: 'previous == "pub" && $1 == "fpr" { print $10 } { previous = $1 }' \
        | grep -qx "${want}"
    rc=$?
    rm -rf "${gnupg_home}"
    return ${rc}
}

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/core/installers-common.sh" "0.3.0" || true
