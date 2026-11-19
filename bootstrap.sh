#!/usr/bin/env bash
# bootstrap.sh — production entry point for workbench-core. See
# README.md "Quick start" / docs/guide/getting-started.md "Install".
#
# Self-contained by necessity (bootstrap-fix brief §3.2/§4): this is what
# fetches workbench-core onto a machine that has nothing installed yet, so
# it cannot depend on anything under lib/ — none of that code exists
# locally until this script fetches it. Its fetch logic therefore
# deliberately duplicates a small, accepted slice of
# lib/distribution/resolve.sh, lib/distribution/fetch-tarball.sh,
# lib/core/semver.sh, and lib/distribution/snapshot.sh's _wb_slugify
# (docs/decisions-log.md, "Bootstrap fetch mechanism" — the
# same narrow, documented duplication precedent as the private-repo
# git-as-transport exception in §9.1/D5). Kept intentionally tiny — its
# only job is to get *just enough* on disk to hand off to `bin/wb install`;
# don't let it grow beyond that.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh | bash  # pattern-scan:ignore -- documented install command in a comment, not executed code
#   curl -fsSLO https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh && bash bootstrap.sh
#   curl -fsSL .../bootstrap.sh | bash -s -- --bundle <name>   # args pass through to `wb install`  # pattern-scan:ignore -- documented install command in a comment, not executed code
#
# More cautious than piping straight to bash? Download first, read it, then
# run it: `curl -fsSLO .../bootstrap.sh && less bootstrap.sh && bash bootstrap.sh`
# — same script either way, just inspected first.
#
# Hosted unversioned, at `main` — unlike every tag-tracked module this
# fetches, bootstrap.sh has no persistent state of its own to drift: it
# either succeeds once (then hands off to the real, tag-tracked engine) or
# doesn't run again. That's a deliberate, narrow asymmetry, not an
# oversight.
#
# Bash 3.2-safe throughout: no declare -A, mapfile/readarray,
# ${var,,}/${var^^}, or declare -n — same constraint as everything in lib/.
set -euo pipefail

# This file's own script-local version (bootstrap-fix brief §5.2). Can't
# call lib/core/version.sh's workbench_register_script_version — nothing to
# source yet — so it just declares and logs its own inline constant.
_WB_BOOTSTRAP_VERSION="0.2.0"

# D18 lists bootstrap.sh in the script-local version registry's scope, but
# nothing ever actually called the registration function here — this line
# always no-ops at real bootstrap runtime (the function doesn't exist this
# early), same as any other file sourced standalone. Its only job is to
# give the release pipeline's bump tooling (.github/scripts/release/) a
# registration-shaped line to find via the same `_workbench_register_script_
# version "<path>"` grep every other file uses, while `_WB_BOOTSTRAP_VERSION`
# above stays the single literal value — passed through here rather than
# duplicated as a second "0.1.0" string that could drift from it.
# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "bootstrap.sh" "${_WB_BOOTSTRAP_VERSION}" || true

log() { printf '[bootstrap v%s] %s\n' "${_WB_BOOTSTRAP_VERSION}" "$*" >&2; }

# _slugify <string> — byte-identical to lib/distribution/snapshot.sh's
# _wb_slugify: lowercase, anything outside [a-z0-9._-] collapsed to '-'.
# Must match exactly — a later real sync cycle for core computes the same
# module's snapshot dirname independently, and the two need to agree.
_slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-'
}

# _gh_curl <url> — GitHub's API requires a User-Agent header on every
# request (rejected outright without one, independent of rate limiting).
# Duplicated from lib/distribution/resolve.sh's _wb_gh_curl, including its
# WORKBENCH_GITHUB_TOKEN handling: sent only to https://api.github.com/, on
# curl's stdin as a config line, never as an argument or in a file
# (docs/decisions-log.md D99). https only, redirects included (security
# status N14).
_gh_curl() {
    local url="$1"
    if [[ -n "${WORKBENCH_GITHUB_TOKEN:-}" ]]; then
        case "${url}" in
            https://api.github.com/*)
                case "${WORKBENCH_GITHUB_TOKEN}" in
                    *[!A-Za-z0-9_.-]*)
                        log "WARNING: WORKBENCH_GITHUB_TOKEN holds characters a GitHub token never has — not sending it"
                        ;;
                    *)
                        printf 'header = "Authorization: Bearer %s"\n' "${WORKBENCH_GITHUB_TOKEN}" \
                            | curl -fsSL --proto '=https' --proto-redir '=https' \
                                -H "Accept: application/vnd.github+json" -A "workbench-core-bootstrap" \
                                --config - "${url}" 2>/dev/null
                        return
                        ;;
                esac
                ;;
        esac
    fi
    curl -fsSL --proto '=https' --proto-redir '=https' \
        -H "Accept: application/vnd.github+json" -A "workbench-core-bootstrap" "${url}" 2>/dev/null
}

# _is_commit_sha <value> — duplicated from lib/distribution/resolve.sh's
# _wb_is_commit_sha: a full, lowercase 40-hex sha. The resolved sha becomes
# part of a URL and of the snapshot directory name (security status N14).
_is_commit_sha() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

# _is_clean_tag / _cmp — duplicated (minimal) from lib/core/semver.sh's
# _wb_semver_is_clean_tag / _wb_semver_cmp: only clean, three-segment tags,
# optionally v-prefixed, participate in `latest` resolution
# (docs/architecture.md §9.2).
_is_clean_tag() {
    local tag="$1"
    local rest="${tag#v}"
    local -a parts
    IFS='.' read -r -a parts <<< "${rest}"
    [[ "${#parts[@]}" -eq 3 ]] || return 1
    local p
    for p in "${parts[@]}"; do
        [[ -n "${p}" ]] || return 1
        case "${p}" in *[!0-9]*) return 1 ;; esac
    done
    return 0
}

_cmp() {
    local a="${1#v}" b="${2#v}"
    local -a A B
    IFS='.' read -r -a A <<< "${a}"
    IFS='.' read -r -a B <<< "${b}"
    local i=0 ai bi
    while [[ "${i}" -lt 3 ]]; do
        ai="${A[${i}]:-0}"; bi="${B[${i}]:-0}"
        ai=$((10#${ai})); bi=$((10#${bi}))
        if [[ "${ai}" -lt "${bi}" ]]; then echo -1; return 0; fi
        if [[ "${ai}" -gt "${bi}" ]]; then echo 1; return 0; fi
        i=$((i + 1))
    done
    echo 0
}

# ── Missing prerequisites (docs/decisions-log.md D117) ─────────────────────
# Detect, report, ask, install — the same flow as lib/core/prereqs.sh's
# workbench_ensure_shell_prereqs, for the six binaries this file needs
# itself. Duplicated because none of lib/ is on disk yet. _pkg_for's rows
# must match lib/core/prereqs.sh's _wb_prereq_package for these six
# (tests/check-prereqs.sh compares them).
_pkg_for() {
    case "$1:$2" in
        apt:awk) echo "mawk" ;;
        *:awk)   echo "gawk" ;;
        *:tr)    echo "coreutils" ;;
        *)       echo "$2" ;;
    esac
}

_pm_detect() {
    local pm
    for pm in apt dnf yum zypper pacman brew; do
        if command -v "${pm}" >/dev/null 2>&1; then echo "${pm}"; return 0; fi
    done
    return 1
}

# Display only, like _wb_prereq_elevation: nothing for brew or root.
_elevation() {
    [[ "$1" == "brew" ]] && return 0
    [[ "$(id -u)" -eq 0 ]] && return 0
    if command -v sudo >/dev/null 2>&1; then echo "sudo"; return 0; fi
    if command -v run0 >/dev/null 2>&1; then echo "run0"; return 0; fi
    return 1
}

# _describe / _install — the command shown, and the same command run.
# Keep the two in step.
_describe() {
    local pm="$1" elev="$2"
    shift 2
    local p=""
    [[ -n "${elev}" ]] && p="${elev} "
    case "${pm}" in
        apt)    echo "${p}apt-get update -qq && ${p}apt-get install -y $*" ;;
        dnf)    echo "${p}dnf install -y $*" ;;
        yum)    echo "${p}yum install -y $*" ;;
        zypper) echo "${p}zypper install -y $*" ;;
        pacman) echo "${p}pacman -Sy --noconfirm $*" ;;
        brew)   echo "brew install $*" ;;
    esac
}

_install() {
    local pm="$1" elev="$2"
    shift 2
    local -a e=()
    [[ -n "${elev}" ]] && e=("${elev}")
    # "${e[@]}" on an empty array is "unbound" under set -u before bash
    # 4.4, hence the two branches.
    if [[ "${#e[@]}" -eq 0 ]]; then
        case "${pm}" in
            apt)    apt-get update -qq && apt-get install -y "$@" ;;
            dnf)    dnf install -y "$@" ;;
            yum)    yum install -y "$@" ;;
            zypper) zypper install -y "$@" ;;
            pacman) pacman -Sy --noconfirm "$@" ;;
            brew)   brew install "$@" ;;
        esac
    else
        case "${pm}" in
            apt)    "${elev}" apt-get update -qq && "${elev}" apt-get install -y "$@" ;;
            dnf)    "${elev}" dnf install -y "$@" ;;
            yum)    "${elev}" yum install -y "$@" ;;
            zypper) "${elev}" zypper install -y "$@" ;;
            pacman) "${elev}" pacman -Sy --noconfirm "$@" ;;
        esac
    fi
}

# True when /dev/tty opens: works under `curl … | bash`, where stdin is
# the script itself. Same test as lib/core/functions.sh's _wb_have_tty.
_have_tty() {
    { : </dev/tty; } 2>/dev/null
}

_ask() {
    local answer=""
    printf 'Install them now? [y/N]: ' >/dev/tty
    if ! IFS= read -r answer </dev/tty; then
        echo >/dev/tty
        return 1
    fi
    case "${answer}" in
        y|Y|yes|YES) return 0 ;;
    esac
    return 1
}

# _ensure_prereqs <yes:true|false> <binary>... — exits on anything but
# "all present".
_ensure_prereqs() {
    local yes="$1"
    shift
    local -a missing=() pkgs=()
    local bin pkg pm elev="" seen=" "
    for bin in "$@"; do
        command -v "${bin}" >/dev/null 2>&1 || missing+=("${bin}")
    done
    [[ "${#missing[@]}" -eq 0 ]] && return 0

    if ! pm="$(_pm_detect)"; then
        log "ERROR: required tools are missing: ${missing[*]} — no supported package manager found. Install them, then re-run. Nothing was changed."
        exit 1
    fi
    {
        echo
        echo "These tools are required to install workbench and are missing:"
        for bin in "${missing[@]}"; do
            pkg="$(_pkg_for "${pm}" "${bin}")"
            printf '  %-12s from package %s\n' "${bin}" "${pkg}"
            case "${seen}" in
                *" ${pkg} "*) ;;
                *) pkgs+=("${pkg}"); seen="${seen}${pkg} " ;;
            esac
        done
        echo
    } >&2
    if ! elev="$(_elevation "${pm}")"; then
        log "ERROR: installing packages needs root, sudo or run0, and none is available. As root, run: $(_describe "${pm}" "" "${pkgs[@]}") — then re-run. Nothing was changed."
        exit 1
    fi
    echo "bootstrap can install them with:" >&2
    echo "  $(_describe "${pm}" "${elev}" "${pkgs[@]}")" >&2
    echo >&2

    if [[ "${yes}" != "true" ]]; then
        if ! _have_tty; then
            log "ERROR: no terminal to ask before installing them — run the command above yourself, or re-run with --yes ('bash -s -- --yes') to let bootstrap run it. Nothing was changed."
            exit 1
        fi
        if ! _ask; then
            log "not installing them — install them yourself, then re-run the same command. Nothing was changed."
            exit 1
        fi
    fi

    log "installing ${pkgs[*]} via ${pm}"
    if ! _install "${pm}" "${elev}" "${pkgs[@]}"; then
        log "ERROR: ${pm} could not install ${pkgs[*]} — install ${missing[*]} yourself, then re-run."
        exit 1
    fi
    hash -r
    for bin in "${missing[@]}"; do
        if ! command -v "${bin}" >/dev/null 2>&1; then
            log "ERROR: '${bin}' is still missing after installing ${pkgs[*]} — install it yourself, then re-run."
            exit 1
        fi
    done
    log "installed ${pkgs[*]} (for ${missing[*]})"
}

# Everything below runs only once the whole file has been received. Under
# `curl | bash`, a connection dropped mid-transfer leaves bash with a file  # pattern-scan:ignore -- prose describing the install pattern in a comment, not executed code
# that ends before this call, so nothing executes (security review L2).
main() {
    OWNER="GingerGraham"
    REPO="workbench-core"
    XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
    MODULE_DIR="${XDG_DATA_HOME}/workbench/modules/core"

    # ── 1. Idempotency check first ───────────────────────────────────────────
    # If core is already bootstrapped, skip straight to re-running convergence
    # rather than re-fetching — re-running this script must always be safe.
    if [[ -e "${MODULE_DIR}/current" ]]; then
        log "core already bootstrapped at ${MODULE_DIR}/current — re-running convergence"
        exec "${MODULE_DIR}/current/bin/wb" install "$@"
    fi

    # ── 2. Bare-minimum prereq check ─────────────────────────────────────────
    # curl, tar, and the specific handful of standard text-processing tools this
    # file's own ref-resolution/tag-parsing logic below actually calls (awk,
    # sed, tr, grep) — checked explicitly because this same codebase already
    # has a confirmed case of one of them (awk) being absent from a real
    # minimal image (Fedora WSL, lib/core/prereqs.sh's own header note), so
    # assuming they're always there would be exactly the kind of thing that
    # looks fine in a quick manual test and fails confusingly on a real
    # minimal machine. Full prereq coverage otherwise (column/git/ssh-keyscan/
    # ssh-keygen) is `bin/wb install`'s job (lib/core/prereqs.sh) — that code
    # doesn't exist locally yet at this point, and none of it is a hard
    # dependency of this file itself the way awk/sed/tr/grep are.
    # Missing ones are listed with their packages and installed only on a
    # yes: the question at /dev/tty, or --yes among the arguments (which
    # also reach `wb install`, where --yes means the same) (D117).
    _wb_yes="false"
    for _wb_arg in "$@"; do
        case "${_wb_arg}" in
            --yes|-y) _wb_yes="true" ;;
        esac
    done
    _ensure_prereqs "${_wb_yes}" curl tar awk sed tr grep
    unset _wb_yes _wb_arg

    # ── 3. Resolve a ref ──────────────────────────────────────────────────────
    # Latest vX.Y.Z tag via GitHub's unauthenticated API, same tag-format
    # contract as docs/architecture.md §9.2/contracts/tracking-spec.md. Trap: if no
    # conforming tag exists yet — true at bootstrap.sh's own introduction,
    # before any release has been cut — fall back to `main` with a clear
    # warning. This isn't just a bring-up convenience: without it, bootstrap is
    # unconditionally broken until the first tag exists. Keep this fallback
    # permanently, don't strip it once a tag exists.
    log "resolving latest release for ${OWNER}/${REPO}..."
    # A failed API call (network error, or GitHub's 60 requests/hour
    # unauthenticated limit — shared by everyone behind the same NAT) is not the
    # same as "no release exists yet". Only the latter may fall back to main
    # (security review L2).
    if ! _tags_json="$(_gh_curl "https://api.github.com/repos/${OWNER}/${REPO}/tags?per_page=100")"; then
        log "ERROR: could not query ${OWNER}/${REPO} tags from the GitHub API (network failure or rate limit). Not falling back to 'main' — retry later."
        exit 1
    fi

    _best_tag=""
    _best_sha=""
    if [[ -n "${_tags_json}" ]]; then
        while IFS='|' read -r _tag _sha; do
            [[ -z "${_tag}" ]] && continue
            _is_clean_tag "${_tag}" || continue
            if [[ -z "${_best_tag}" ]]; then
                _best_tag="${_tag}"; _best_sha="${_sha}"
            else
                _c="$(_cmp "${_tag}" "${_best_tag}")"
                [[ "${_c}" == "1" ]] && { _best_tag="${_tag}"; _best_sha="${_sha}"; }
            fi
        done < <(printf '%s' "${_tags_json}" \
            | grep -oE '"(name|sha)"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | sed -E 's/^"(name|sha)"[[:space:]]*:[[:space:]]*"([^"]*)"$/\2/' \
            | awk 'NR % 2 == 1 { name = $0; next } { print name "|" $0 }')
    fi

    if [[ -n "${_best_tag}" ]]; then
        REF_PATH="${_best_sha}"
        REF_SLUG="$(_slugify "${_best_tag}")"
        SHA="${_best_sha}"
        TRACK_MODE="latest"
        TRACK_REF="${_best_tag}"
        log "resolved release: ${_best_tag} (${SHA:0:7})"
    else
        log "WARNING: no clean release tag found yet for ${OWNER}/${REPO} — falling back to 'main'"
        SHA="$(_gh_curl "https://api.github.com/repos/${OWNER}/${REPO}/commits/main" \
            | grep -o '"sha":[^,]*' | head -1 | grep -oE '[0-9a-f]{40}' || true)"
        if [[ -z "${SHA}" ]]; then
            log "ERROR: could not resolve 'main' to a commit via the GitHub API"
            exit 1
        fi
        REF_PATH="${SHA}"
        REF_SLUG="$(_slugify "main")"
        TRACK_MODE="latest"
        TRACK_REF="main"
        log "resolved fallback: main (${SHA:0:7})"
    fi
    if ! _is_commit_sha "${SHA}"; then
        log "ERROR: the GitHub API returned '${SHA}' for ${OWNER}/${REPO}, not a commit sha — refusing it"
        exit 1
    fi
    SHORT_SHA="${SHA:0:7}"

    # ── 4. Fetch + extract directly into the real, permanent snapshot path ────
    # Never a scratch/temp directory with `current` symlinked to it — a
    # tmp-cleaner sweep or reboot can silently delete a temp directory later,
    # breaking the loader with no obvious cause, days after a quick manual test
    # looked fine (fix-brief §3.4). Writing straight into
    # snapshots/<ref-slug>-<shortsha>/ means core's very first snapshot is
    # indistinguishable from one an ordinary sync cycle would have produced —
    # the exact same shape docs/architecture.md §9.3 defines.
    DEST="${MODULE_DIR}/snapshots/${REF_SLUG}-${SHORT_SHA}"

    if [[ ! -e "${DEST}" ]]; then
        log "fetching ${OWNER}/${REPO}@${SHORT_SHA}..."
        _tmp_tar="$(mktemp "${TMPDIR:-/tmp}/workbench-bootstrap.XXXXXX")"
        _tmp_extract="$(mktemp -d "${TMPDIR:-/tmp}/workbench-bootstrap.XXXXXX")"
        trap 'rm -f "${_tmp_tar}"; rm -rf "${_tmp_extract}"' EXIT

        # REF_PATH is always the resolved commit sha — content-addressed, matches RESOLVED_SHA (L1).
        curl -fsSL --proto '=https' --proto-redir '=https' \
            "https://codeload.github.com/${OWNER}/${REPO}/tar.gz/${REF_PATH}" -o "${_tmp_tar}"
        # -m: entries carry the commit time; GNU tar warns per file when
        # that is ahead of this clock. Files get the fetch time instead.
        tar -xmzf "${_tmp_tar}" -C "${_tmp_extract}"
        rm -f "${_tmp_tar}"

        _extracted="$(find "${_tmp_extract}" -mindepth 1 -maxdepth 1 -type d | head -1)"
        if [[ -z "${_extracted}" ]]; then
            log "ERROR: tarball extraction produced no directory"
            exit 1
        fi

        mkdir -p "$(dirname "${DEST}")"
        mv "${_extracted}" "${DEST}"
        rm -rf "${_tmp_extract}"
        trap - EXIT
    else
        log "snapshot ${DEST} already present on disk — reusing, not re-fetching"
    fi

    # ── 5. Write core's sync.conf directly ─────────────────────────────────────
    # Matching contracts/state-schema.md and the same fields
    # _wb_bootstrap_core_module (bin/wb) already writes for the developer-clone
    # path. Flip `current` to the new snapshot via the same atomic-swap
    # primitive lib/distribution/snapshot.sh's workbench_snapshot_swap uses
    # (ln -sfn, falling back to -sfh for BSD/macOS).
    mkdir -p "${MODULE_DIR}"
    cat > "${MODULE_DIR}/sync.conf" <<EOF
REPO_URL=https://github.com/${OWNER}/${REPO}.git
PRIVATE=false
TRACK_MODE=${TRACK_MODE}
TRACK_REF=${TRACK_REF}
REGISTERED=true
SYNC_ENABLED=true
ALLOW_HOOKS=false
RESOLVED_SHA=${SHA}
EOF

    if ! ln -sfn "${DEST}" "${MODULE_DIR}/current" 2>/dev/null; then
        ln -sfh "${DEST}" "${MODULE_DIR}/current"
    fi
    log "core bootstrapped: ${DEST}"

    # ── 6. Hand off ─────────────────────────────────────────────────────────────
    # bin/wb install's own bootstrap step (_wb_bootstrap_core_module) sees core
    # already registered with a real current/ directory and returns immediately
    # — its `.git`-presence branch is the developer-clone case only and is
    # never reached from here. See that function's header comment in bin/wb.
    exec "${DEST}/bin/wb" install "$@"
}

main "$@"
