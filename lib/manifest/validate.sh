#!/usr/bin/env bash
# lib/manifest/validate.sh
# ─────────────────────────────────────────────────────────────────────────────
# Developer-time validator for .dotfiles-sync.yml against
# contracts/manifest-spec.md — the authoritative contract. Ported from
# workbench-precursor's scripts/validate-sync-manifest.sh and extended for
# the new, additive `core_api`/`sync`/`register`/keys (ARCHITECTURE.md §5,
# build brief Phase 3) — its path-safety discipline (the src/dest denylist
# checks) is kept exactly as it was.
#
# This is the one place in workbench-core where yq is an acceptable
# dependency: it's a developer-time tool, run by hand or in a module repo's
# own CI before pushing a manifest, never on the hot/timer path — see
# lib/manifest/parse.sh for the pure bash/awk reader that path actually uses.
# Requires mikefarah/yq v4.
#
# Usage: validate.sh [path]   (default: ./.dotfiles-sync.yml)
# Exit status: 0 if the manifest is valid, non-zero otherwise.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
ERRORS=0
WARNINGS=0

# The manifest schema version(s) this copy of the validator understands.
# Bump when contracts/manifest-spec.md's `version: 2` escape hatch (§5.4)
# is actually built. Deliberately independent of the hot-path's own
# _WB_MANIFEST_SCHEMA_VERSIONS_SUPPORTED in lib/manifest/parse.sh — this
# script must run standalone, without workbench-core installed alongside
# it (a module repo's own CI, say), so it cannot read the live
# ~/.config/workbench/core/version file. Two constants, same reason
# bootstrap.sh duplicates fetch logic instead of sourcing
# lib/distribution/fetch-tarball.sh — structurally unavoidable. See
# ARCHITECTURE.md §12 D30.
_WB_MANIFEST_SCHEMA_VERSIONS_SUPPORTED="1"

err()  { echo "[ERROR] $*" >&2; ERRORS=$((ERRORS + 1)); }
warn() { echo "[WARN]  $*" >&2; WARNINGS=$((WARNINGS + 1)); }
info() { echo "[INFO]  $*"; }

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/manifest/validate.sh" "0.2.0" || true

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [path]

Validates a .dotfiles-sync.yml manifest against contracts/manifest-spec.md.

  path   Path to the manifest to validate (default: ./.dotfiles-sync.yml)

Checks (fail the manifest) — unchanged from schema version 1:
  - the file parses as YAML
  - version is present and equal to 1
  - every deploy[] entry has src and dest
  - src is a safe relative path (no leading /, no .. segment)
  - dest (and dest_macos) starts with ~/, contains no .. segment, and does
    not target the dest denylist
  - mode, when given, is copy, link, or link_tree
  - mode: link_tree requires src: '.'
  - platforms, when given, only contains linux/macos
  - hooks.post_deploy.command, when declared, is a non-empty list whose [0]
    is a safe relative path that exists in the repo
  - hooks.post_deploy.run_on, when given, is changed/always/initial
  - hooks.post_deploy.timeout, when given, is a positive integer

New checks (register:, additive per ARCHITECTURE.md §5):
  - core_api, when given, is a non-empty string (a semver range consumed by
    the Core API gate — not deeply validated here, just checked non-empty)
  - sync.enabled, when given, is true or false
  - register.shell[].src is required and a safe relative path; register.
    shell[].dest is REJECTED if present — destinations for registered shell
    content are always engine-computed, never author-specified
  - register.shell[].tier, when given, is one of env/core/tools/platform/
    distro/lazy
  - register.installers[].src is required and a safe relative path
  - register.getters[].name and .function are required and non-empty
  - unknown keys under register: (and its sub-blocks) are ignored, not
    fatal — same forward-compatibility posture as the rest of the spec

Requires mikefarah/yq v4: https://github.com/mikefarah/yq#install
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

MANIFEST="${1:-./.dotfiles-sync.yml}"

require_yq() {
    if ! command -v yq &>/dev/null; then
        err "yq is required for manifest validation."
        err "Install: https://github.com/mikefarah/yq#install"
        exit 1
    fi
    if ! yq --version 2>&1 | grep -qE 'mikefarah|version v4|yq \(https://github.com/mikefarah'; then
        err "Wrong yq detected — mikefarah/yq v4 is required."
        err "Found: $(yq --version 2>&1)"
        err "Install: https://github.com/mikefarah/yq#install"
        err "On Ubuntu/Debian, python3-yq may be shadowing the correct binary — check 'which -a yq'."
        exit 1
    fi
}

require_yq

if [[ ! -f "${MANIFEST}" ]]; then
    err "Manifest not found: ${MANIFEST}"
    exit 1
fi

if ! yq eval '.' "${MANIFEST}" > /dev/null 2>&1; then
    err "Manifest does not parse as YAML: ${MANIFEST}"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${MANIFEST}")" && pwd)"

# ── Path-safety helpers (unchanged from the donor script) ───────────────────

_split_path_segments() {
    _PATH_SEGMENTS=()
    IFS='/' read -r -a _PATH_SEGMENTS <<< "$1"
}

_is_safe_relative_path() {
    local p="$1"
    [[ -z "${p}" || "${p}" == "null" ]] && return 1
    [[ "${p}" == /* ]] && return 1

    _split_path_segments "${p}"
    local seg
    if [[ "${#_PATH_SEGMENTS[@]}" -gt 0 ]]; then
        for seg in "${_PATH_SEGMENTS[@]}"; do
            [[ "${seg}" == ".." ]] && return 1
        done
    fi
    return 0
}

_DEST_DENYLIST_DIRS_REL=(
    ".ssh/" ".gnupg/" ".config/shell/" ".config/git/" ".config/dotfiles/"
    ".config/workbench/" ".config/external-sync/" ".config/systemd/user/"
    "Library/LaunchAgents/"
)
_DEST_DENYLIST_FILES_REL=(
    ".bashrc" ".zshrc" ".profile" ".gitconfig"
)

_is_safe_dest() {
    local d="$1"
    [[ -z "${d}" || "${d}" == "null" ]] && return 1
    # shellcheck disable=SC2088
    [[ "${d}" != "~/"* ]] && return 1

    local rel="${d#\~/}"
    [[ -z "${rel}" ]] && return 1

    _split_path_segments "${rel}"
    local seg
    if [[ "${#_PATH_SEGMENTS[@]}" -gt 0 ]]; then
        for seg in "${_PATH_SEGMENTS[@]}"; do
            [[ "${seg}" == ".." ]] && return 1
        done
    fi

    local entry
    for entry in "${_DEST_DENYLIST_DIRS_REL[@]}"; do
        [[ "${rel}" == "${entry}"* ]] && return 1
    done
    for entry in "${_DEST_DENYLIST_FILES_REL[@]}"; do
        [[ "${rel}" == "${entry}" ]] && return 1
    done
    return 0
}

# ── version ──────────────────────────────────────────────────────────────────

_version=$(yq eval '.version' "${MANIFEST}")
if [[ -z "${_version}" || "${_version}" == "null" ]]; then
    err "version is required (contracts/manifest-spec.md §Field reference)."
elif [[ " ${_WB_MANIFEST_SCHEMA_VERSIONS_SUPPORTED} " != *" ${_version} "* ]]; then
    err "version must be one of: ${_WB_MANIFEST_SCHEMA_VERSIONS_SUPPORTED} — found '${_version}' (contracts/manifest-spec.md §Schema version 1)."
fi

# ── deploy[] ─────────────────────────────────────────────────────────────────

_has_deploy=$(yq eval '.deploy != null' "${MANIFEST}")
_deploy_count=0
if [[ "${_has_deploy}" == "true" ]]; then
    _deploy_count=$(yq eval '.deploy | length' "${MANIFEST}")
fi

if [[ "${_deploy_count}" -gt 0 ]]; then
    _i=0
    while [[ "${_i}" -lt "${_deploy_count}" ]]; do
        _src=$(yq eval ".deploy[${_i}].src" "${MANIFEST}")
        _dest=$(yq eval ".deploy[${_i}].dest" "${MANIFEST}")
        _dest_macos=$(yq eval ".deploy[${_i}].dest_macos" "${MANIFEST}")
        _mode=$(yq eval ".deploy[${_i}].mode" "${MANIFEST}")
        _label="deploy[${_i}] (src: ${_src})"

        if [[ -z "${_src}" || "${_src}" == "null" ]]; then
            err "${_label}: src is required (contracts/manifest-spec.md §Field reference)."
        elif ! _is_safe_relative_path "${_src}"; then
            err "${_label}: src '${_src}' must be a path relative to the repo root, without '..' segments or a leading '/' (contracts/manifest-spec.md §Deploy semantics)."
        elif [[ ! -e "${REPO_ROOT}/${_src}" ]]; then
            warn "${_label}: src '${_src}' does not exist in the repo (checked ${REPO_ROOT}/${_src})."
        fi

        if [[ -z "${_dest}" || "${_dest}" == "null" ]]; then
            err "${_label}: dest is required (contracts/manifest-spec.md §Field reference)."
        elif ! _is_safe_dest "${_dest}"; then
            err "${_label}: dest '${_dest}' must start with ~/, contain no '..' segments, and must not target the dest denylist (contracts/manifest-spec.md §dest validation)."
        fi

        if [[ -n "${_dest_macos}" && "${_dest_macos}" != "null" ]] && ! _is_safe_dest "${_dest_macos}"; then
            err "${_label}: dest_macos '${_dest_macos}' must start with ~/, contain no '..' segments, and must not target the dest denylist (contracts/manifest-spec.md §dest validation)."
        fi

        if [[ -n "${_mode}" && "${_mode}" != "null" && "${_mode}" != "copy" && "${_mode}" != "link" && "${_mode}" != "link_tree" ]]; then
            err "${_label}: mode must be 'copy', 'link', or 'link_tree' — found '${_mode}'."
        fi

        if [[ "${_mode}" == "link_tree" && "${_src}" != "." ]]; then
            err "${_label}: mode: link_tree requires src: '.' — link_tree symlinks the whole repo as a single unit, it cannot target a subpath (contracts/manifest-spec.md)."
        fi

        _platforms_count=$(yq eval ".deploy[${_i}].platforms // [] | length" "${MANIFEST}")
        if [[ "${_platforms_count}" -gt 0 ]]; then
            _p=0
            while [[ "${_p}" -lt "${_platforms_count}" ]]; do
                _platform=$(yq eval ".deploy[${_i}].platforms[${_p}]" "${MANIFEST}")
                if [[ "${_platform}" != "linux" && "${_platform}" != "macos" ]]; then
                    err "${_label}: platforms[${_p}] must be 'linux' or 'macos' — found '${_platform}'."
                fi
                _p=$((_p + 1))
            done
        fi

        _i=$((_i + 1))
    done
fi

# ── core_api / sync.enabled (new, additive) ─────────────────────────────────

_core_api=$(yq eval '.core_api' "${MANIFEST}")
if [[ -n "${_core_api}" && "${_core_api}" != "null" ]]; then
    if [[ -z "${_core_api// /}" ]]; then
        err "core_api, when given, must be a non-empty version range string (e.g. '>=1.0 <2.0') (contracts/manifest-spec.md §core_api)."
    else
        info "core_api: ${_core_api}"
    fi
else
    info "core_api not declared — register: entries (if any) will be ignored by workbench-core (deploy/sync-only, legacy-compatible manifest)."
fi

_sync_enabled=$(yq eval '.sync.enabled' "${MANIFEST}")
if [[ -n "${_sync_enabled}" && "${_sync_enabled}" != "null" ]]; then
    if [[ "${_sync_enabled}" != "true" && "${_sync_enabled}" != "false" ]]; then
        err "sync.enabled, when given, must be true or false — found '${_sync_enabled}'."
    fi
fi

# ── register: (new, additive) ────────────────────────────────────────────────

_has_register=$(yq eval '.register != null' "${MANIFEST}")
if [[ "${_has_register}" == "true" && ( -z "${_core_api}" || "${_core_api}" == "null" ) ]]; then
    warn "manifest declares register: but no core_api — register: is ignored without core_api (contracts/manifest-spec.md §core_api)."
fi

_VALID_TIERS=(env core tools platform distro lazy)
_is_valid_tier() {
    local t="$1" v
    for v in "${_VALID_TIERS[@]}"; do [[ "${t}" == "${v}" ]] && return 0; done
    return 1
}

_shell_count=$(yq eval '.register.shell // [] | length' "${MANIFEST}")
_si=0
while [[ "${_si}" -lt "${_shell_count}" ]]; do
    _rsrc=$(yq eval ".register.shell[${_si}].src" "${MANIFEST}")
    _rtier=$(yq eval ".register.shell[${_si}].tier" "${MANIFEST}")
    _rdest=$(yq eval ".register.shell[${_si}].dest" "${MANIFEST}")
    _rlabel="register.shell[${_si}] (src: ${_rsrc})"

    if [[ -z "${_rsrc}" || "${_rsrc}" == "null" ]]; then
        err "${_rlabel}: src is required (contracts/manifest-spec.md §register.shell)."
    elif ! _is_safe_relative_path "${_rsrc}"; then
        err "${_rlabel}: src '${_rsrc}' must be a path relative to the repo root, without '..' segments or a leading '/'."
    elif [[ ! -e "${REPO_ROOT}/${_rsrc}" ]]; then
        warn "${_rlabel}: src '${_rsrc}' does not exist in the repo (checked ${REPO_ROOT}/${_rsrc})."
    fi

    if [[ -n "${_rdest}" && "${_rdest}" != "null" ]]; then
        err "${_rlabel}: dest is not permitted on register.shell[] entries — the destination is always engine-computed (contracts/manifest-spec.md §register.shell, ARCHITECTURE.md principle 1)."
    fi

    if [[ -n "${_rtier}" && "${_rtier}" != "null" ]] && ! _is_valid_tier "${_rtier}"; then
        err "${_rlabel}: tier must be one of ${_VALID_TIERS[*]} — found '${_rtier}'."
    fi

    _si=$((_si + 1))
done

_installers_count=$(yq eval '.register.installers // [] | length' "${MANIFEST}")
_ii=0
while [[ "${_ii}" -lt "${_installers_count}" ]]; do
    _isrc=$(yq eval ".register.installers[${_ii}].src" "${MANIFEST}")
    _ilabel="register.installers[${_ii}] (src: ${_isrc})"

    if [[ -z "${_isrc}" || "${_isrc}" == "null" ]]; then
        err "${_ilabel}: src is required."
    elif ! _is_safe_relative_path "${_isrc}"; then
        err "${_ilabel}: src '${_isrc}' must be a path relative to the repo root, without '..' segments or a leading '/'."
    elif [[ ! -e "${REPO_ROOT}/${_isrc}" ]]; then
        warn "${_ilabel}: src '${_isrc}' does not exist in the repo (checked ${REPO_ROOT}/${_isrc})."
    fi

    _ii=$((_ii + 1))
done

_getters_count=$(yq eval '.register.getters // [] | length' "${MANIFEST}")
_gi=0
while [[ "${_gi}" -lt "${_getters_count}" ]]; do
    _gname=$(yq eval ".register.getters[${_gi}].name" "${MANIFEST}")
    _gfunc=$(yq eval ".register.getters[${_gi}].function" "${MANIFEST}")
    _glabel="register.getters[${_gi}] (name: ${_gname})"

    if [[ -z "${_gname}" || "${_gname}" == "null" ]]; then
        err "${_glabel}: name is required."
    fi
    if [[ -z "${_gfunc}" || "${_gfunc}" == "null" ]]; then
        err "${_glabel}: function is required."
    fi

    _gi=$((_gi + 1))
done

# ── hooks.post_deploy (unchanged) ────────────────────────────────────────────

_hook_declared=$(yq eval '.hooks.post_deploy != null' "${MANIFEST}")

if [[ "${_hook_declared}" == "true" ]]; then
    warn "manifest declares a post_deploy hook — remember allow_hooks: true is required per machine, in host_vars (docs/module-authoring.md#hooks)."

    _command_type=$(yq eval '.hooks.post_deploy.command | type' "${MANIFEST}")
    if [[ "${_command_type}" == "!!str" ]]; then
        err "hooks.post_deploy.command must be a list (argv form), not a string — found a string. A string would be silently word-split."
    elif [[ "${_command_type}" != "!!seq" ]]; then
        err "hooks.post_deploy.command is required and must be a non-empty list."
    else
        _command_len=$(yq eval '.hooks.post_deploy.command | length' "${MANIFEST}")
        if [[ "${_command_len}" -eq 0 ]]; then
            err "hooks.post_deploy.command must be a non-empty list."
        else
            _command0=$(yq eval '.hooks.post_deploy.command[0]' "${MANIFEST}")
            if ! _is_safe_relative_path "${_command0}"; then
                err "hooks.post_deploy.command[0] '${_command0}' must be a path relative to the repo root, without '..' segments or a leading '/'."
            elif [[ ! -e "${REPO_ROOT}/${_command0}" ]]; then
                err "hooks.post_deploy.command[0] '${_command0}' does not exist in the repo (checked ${REPO_ROOT}/${_command0})."
            fi
        fi
    fi

    _run_on=$(yq eval '.hooks.post_deploy.run_on' "${MANIFEST}")
    if [[ -n "${_run_on}" && "${_run_on}" != "null" ]]; then
        case "${_run_on}" in
            changed|always|initial) ;;
            *) err "hooks.post_deploy.run_on must be changed, always, or initial — found '${_run_on}'." ;;
        esac
    fi

    _timeout=$(yq eval '.hooks.post_deploy.timeout' "${MANIFEST}")
    if [[ -n "${_timeout}" && "${_timeout}" != "null" ]]; then
        if ! [[ "${_timeout}" =~ ^[0-9]+$ ]] || [[ "${_timeout}" -eq 0 ]]; then
            err "hooks.post_deploy.timeout must be a positive integer — found '${_timeout}'."
        fi
    fi
fi

if [[ "${_deploy_count}" -eq 0 && "${_hook_declared}" != "true" && "${_shell_count}" -eq 0 ]]; then
    warn "manifest has no deploy entries, no register.shell entries, and no hooks — this is a valid clone-only manifest, but confirm that was deliberate."
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo
if [[ "${ERRORS}" -eq 0 ]]; then
    info "${MANIFEST}: valid (${WARNINGS} warning(s))."
    exit 0
else
    err "${MANIFEST}: ${ERRORS} error(s), ${WARNINGS} warning(s)."
    exit 1
fi
