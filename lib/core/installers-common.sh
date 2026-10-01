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
# ignored). Uses a throwaway GNUPGHOME so the user's keyring is never
# touched.
#
# Presence check only — never use it as a trust decision. A file that also
# carries other keys passes this check, and rpm --import / apt signed-by
# would trust those too (security review follow-up R1). To trust a vendor
# key, use _wb_key_extract_pinned, _wb_rpm_import_pinned_key,
# _wb_apt_keyring_pinned or _wb_dnf_vendor_repo (D79).
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

# _wb_vendor_id_is_valid <id>
# Lowercase letters, digits and '-'; must not start with '-'. Used for repo
# ids and key file names that become paths under /etc.
_wb_vendor_id_is_valid() {
    local id="$1"
    local LC_ALL=C
    [[ -n "${id}" && ${#id} -le 64 ]] || return 1
    case "${id}" in
        -*|*[!a-z0-9-]*) return 1 ;;
    esac
    return 0
}

# _wb_key_extract_pinned <keyfile> <out_file> <armor|binary> <fingerprint> [<fingerprint> ...]
# Writes to <out_file> an export containing only the primary keys from
# <keyfile> whose fingerprints are pinned (40 hex; spaces and case ignored).
# Any other primary key in <keyfile> is dropped with a warning. Fails if none
# of the pinned keys is present. Always trust the output, never the
# downloaded file (security review follow-up R1, D79).
_wb_key_extract_pinned() {
    local keyfile="$1" out_file="$2" format="$3"
    local gnupg_home fpr want pinned="" dropped=""
    local -a found=()
    local -a export_args=()

    if [[ $# -lt 4 ]]; then
        log_error "_wb_key_extract_pinned: usage: <keyfile> <out_file> <armor|binary> <fingerprint> [<fingerprint> ...]"
        return 2
    fi
    shift 3
    case "${format}" in
        armor|binary) ;;
        *) log_error "_wb_key_extract_pinned: format must be 'armor' or 'binary', got '${format}'"; return 2 ;;
    esac
    command -v gpg &>/dev/null || { log_error "_wb_key_extract_pinned: gpg is required"; return 1; }

    for want in "$@"; do
        pinned="${pinned} $(printf '%s' "${want}" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
    done

    gnupg_home="$(mktemp -d)" || return 1
    if ! gpg --homedir "${gnupg_home}" --batch --quiet --no-autostart --import "${keyfile}" 2>/dev/null; then
        log_error "_wb_key_extract_pinned: ${keyfile} is not a readable OpenPGP key file"
        rm -rf "${gnupg_home}"
        return 1
    fi

    while IFS= read -r fpr; do
        [[ -z "${fpr}" ]] && continue
        case "${pinned} " in
            *" ${fpr} "*) found+=("${fpr}") ;;
            *)            dropped="${dropped} ${fpr}" ;;
        esac
    done < <(gpg --homedir "${gnupg_home}" --batch --no-autostart --with-colons --list-keys 2>/dev/null \
                | awk -F: 'previous == "pub" && $1 == "fpr" { print $10 } { previous = $1 }')

    if [[ ${#found[@]} -eq 0 ]]; then
        log_error "_wb_key_extract_pinned: ${keyfile} contains none of the pinned keys — refusing to trust it"
        rm -rf "${gnupg_home}"
        return 1
    fi
    if [[ -n "${dropped}" ]]; then
        log_warn "_wb_key_extract_pinned: ignoring unpinned key(s) in ${keyfile}:${dropped}"
    fi

    export_args=(--homedir "${gnupg_home}" --batch --no-autostart --export)
    [[ "${format}" == "armor" ]] && export_args+=(--armor)
    if ! gpg "${export_args[@]}" "${found[@]}" > "${out_file}" 2>/dev/null || [[ ! -s "${out_file}" ]]; then
        log_error "_wb_key_extract_pinned: exporting the pinned key(s) failed"
        rm -f "${out_file}"
        rm -rf "${gnupg_home}"
        return 1
    fi
    chmod 0644 "${out_file}"
    rm -rf "${gnupg_home}"
    return 0
}

# _wb_rpm_import_pinned_key <key_url> <local_name> <fingerprint> [<fingerprint> ...]
# Downloads <key_url>, keeps only the pinned key(s), installs them as
# /etc/pki/rpm-gpg/RPM-GPG-KEY-workbench-<local_name>, and rpm --imports that
# local file. Prints the installed path on stdout (logs go to stderr).
_wb_rpm_import_pinned_key() {
    local key_url="$1" local_name="$2"
    local elevation_cmd tmp_dir key_path rc

    if [[ $# -lt 3 ]]; then
        log_error "_wb_rpm_import_pinned_key: usage: <key_url> <local_name> <fingerprint> [<fingerprint> ...]"
        return 2
    fi
    shift 2
    _wb_vendor_id_is_valid "${local_name}" || { log_error "_wb_rpm_import_pinned_key: invalid name '${local_name}'"; return 2; }
    case "${key_url}" in
        https://?*) ;;
        *) log_error "_wb_rpm_import_pinned_key: key URL must be https://"; return 2 ;;
    esac

    key_path="${_WB_TEST_SYSROOT:-}/etc/pki/rpm-gpg/RPM-GPG-KEY-workbench-${local_name}"
    elevation_cmd="$(get-elevation-command)" || return 1
    tmp_dir="$(mktemp -d)" || return 1

    if ! _download_file_robust "${key_url}" "${tmp_dir}/downloaded" \
        || ! _wb_key_extract_pinned "${tmp_dir}/downloaded" "${tmp_dir}/pinned.asc" armor "$@"; then
        rm -rf "${tmp_dir}"
        return 1
    fi

    ${elevation_cmd} install -D -m 0644 "${tmp_dir}/pinned.asc" "${key_path}" \
        && ${elevation_cmd} rpm --import "${key_path}"
    rc=$?
    rm -rf "${tmp_dir}"
    if [[ ${rc} -ne 0 ]]; then
        log_error "_wb_rpm_import_pinned_key: installing or importing ${key_path} failed"
        return ${rc}
    fi
    printf '%s\n' "${key_path#"${_WB_TEST_SYSROOT:-}"}"
}

# _wb_apt_keyring_pinned <key_url> <keyring_path> <fingerprint> [<fingerprint> ...]
# Downloads <key_url>, keeps only the pinned key(s), and installs them as a
# binary keyring at <keyring_path> for use with apt's signed-by=. The path
# must be under /etc/apt/keyrings/ or /usr/share/keyrings/ and end in .gpg.
_wb_apt_keyring_pinned() {
    local key_url="$1" keyring="$2"
    local elevation_cmd tmp_dir rc

    if [[ $# -lt 3 ]]; then
        log_error "_wb_apt_keyring_pinned: usage: <key_url> <keyring_path> <fingerprint> [<fingerprint> ...]"
        return 2
    fi
    shift 2
    case "${keyring}" in
        */../*|*/./*) log_error "_wb_apt_keyring_pinned: invalid keyring path '${keyring}'"; return 2 ;;
        /etc/apt/keyrings/?*.gpg|/usr/share/keyrings/?*.gpg) ;;
        *) log_error "_wb_apt_keyring_pinned: keyring must be /etc/apt/keyrings/*.gpg or /usr/share/keyrings/*.gpg"; return 2 ;;
    esac
    case "${key_url}" in
        https://?*) ;;
        *) log_error "_wb_apt_keyring_pinned: key URL must be https://"; return 2 ;;
    esac

    elevation_cmd="$(get-elevation-command)" || return 1
    tmp_dir="$(mktemp -d)" || return 1
    if ! _download_file_robust "${key_url}" "${tmp_dir}/downloaded" \
        || ! _wb_key_extract_pinned "${tmp_dir}/downloaded" "${tmp_dir}/pinned.gpg" binary "$@"; then
        rm -rf "${tmp_dir}"
        return 1
    fi
    ${elevation_cmd} install -D -m 0644 "${tmp_dir}/pinned.gpg" "${_WB_TEST_SYSROOT:-}${keyring}"
    rc=$?
    rm -rf "${tmp_dir}"
    return ${rc}
}

# _wb_dnf_vendor_repo --id <id> --name <name> --baseurl <https-url>
#                     --key-url <https-url> --fingerprint <fpr> [--fingerprint <fpr> ...]
#                     --include <pkg> [--include <pkg> ...] [--repo-gpgcheck]
# Writes /etc/yum.repos.d/<id>.repo for a third-party dnf/yum repository:
#   - its signing key is pinned and stored locally (gpgkey=file://…), so dnf
#     can never import a different key from the vendor later (R2);
#   - includepkgs limits the repository to the named packages (M4).
# The file is rewritten on every call so existing hosts converge.
_wb_dnf_vendor_repo() {
    local id="" name="" baseurl="" key_url="" repo_gpgcheck=0
    local key_path elevation_cmd repo_file pkg
    local -a fprs=()
    local -a pkgs=()

    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--repo-gpgcheck" ]]; then
            repo_gpgcheck=1
            shift
            continue
        fi
        if [[ $# -lt 2 ]]; then
            log_error "_wb_dnf_vendor_repo: $1 needs a value"
            return 2
        fi
        case "$1" in
            --id)          id="$2" ;;
            --name)        name="$2" ;;
            --baseurl)     baseurl="$2" ;;
            --key-url)     key_url="$2" ;;
            --fingerprint) fprs+=("$2") ;;
            --include)     pkgs+=("$2") ;;
            *) log_error "_wb_dnf_vendor_repo: unknown option '$1'"; return 2 ;;
        esac
        shift 2
    done

    _wb_vendor_id_is_valid "${id}" || { log_error "_wb_dnf_vendor_repo: invalid --id '${id}'"; return 2; }
    case "${name}" in
        ''|*[[:cntrl:]]*) log_error "_wb_dnf_vendor_repo: --name is required and must be a single line"; return 2 ;;
    esac
    case "${baseurl}" in
        https://?*) ;;
        *) log_error "_wb_dnf_vendor_repo: --baseurl must be https://"; return 2 ;;
    esac
    case "${baseurl}" in
        *[[:space:]]*|*[[:cntrl:]]*) log_error "_wb_dnf_vendor_repo: --baseurl contains whitespace"; return 2 ;;
    esac
    [[ ${#fprs[@]} -gt 0 ]] || { log_error "_wb_dnf_vendor_repo: at least one --fingerprint is required"; return 2; }
    [[ ${#pkgs[@]} -gt 0 ]] || { log_error "_wb_dnf_vendor_repo: at least one --include is required"; return 2; }
    for pkg in "${pkgs[@]}"; do
        local LC_ALL=C
        case "${pkg}" in
            ''|*[!A-Za-z0-9._+*-]*) log_error "_wb_dnf_vendor_repo: invalid --include '${pkg}'"; return 2 ;;
        esac
    done

    case "${key_url}" in
        https://?*) ;;
        *) log_error "_wb_dnf_vendor_repo: --key-url must be https://"; return 2 ;;
    esac

    key_path="$(_wb_rpm_import_pinned_key "${key_url}" "${id}" "${fprs[@]}")" || return 1
    elevation_cmd="$(get-elevation-command)" || return 1
    repo_file="${_WB_TEST_SYSROOT:-}/etc/yum.repos.d/${id}.repo"

    ${elevation_cmd} install -d -m 0755 "$(dirname "${repo_file}")" || return 1

    printf '%s\n' \
        "# Managed by workbench (D79): pinned local signing key, package allowlist." \
        "[${id}]" \
        "name=${name}" \
        "baseurl=${baseurl}" \
        "enabled=1" \
        "gpgcheck=1" \
        "repo_gpgcheck=${repo_gpgcheck}" \
        "gpgkey=file://${key_path}" \
        "includepkgs=${pkgs[*]}" \
        | ${elevation_cmd} tee "${repo_file}" >/dev/null
}

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/core/installers-common.sh" "0.3.0" || true
