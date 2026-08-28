#!/usr/bin/env bash
# bootstrap.sh — production entry point for workbench-core. See
# README.md "Quick start" / docs/getting-started.md "Install".
#
# Self-contained by necessity (bootstrap-fix brief §3.2/§4): this is what
# fetches workbench-core onto a machine that has nothing installed yet, so
# it cannot depend on anything under lib/ — none of that code exists
# locally until this script fetches it. Its fetch logic therefore
# deliberately duplicates a small, accepted slice of
# lib/distribution/resolve.sh, lib/distribution/fetch-tarball.sh,
# lib/core/semver.sh, and lib/distribution/snapshot.sh's _wb_slugify
# (ARCHITECTURE.md §12 decisions log, "Bootstrap fetch mechanism" — the
# same narrow, documented duplication precedent as the private-repo
# git-as-transport exception in §9.1/D5). Kept intentionally tiny — its
# only job is to get *just enough* on disk to hand off to `bin/wb install`;
# don't let it grow beyond that.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh | bash
#   curl -fsSLO https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh && bash bootstrap.sh
#   curl -fsSL .../bootstrap.sh | bash -s -- --bundle <name>   # args pass through to `wb install`
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
_WB_BOOTSTRAP_VERSION="0.1.0"

OWNER="GingerGraham"
REPO="workbench-core"
XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
MODULE_DIR="${XDG_DATA_HOME}/workbench/modules/core"

log() { printf '[bootstrap v%s] %s\n' "${_WB_BOOTSTRAP_VERSION}" "$*" >&2; }

# ── 1. Idempotency check first ───────────────────────────────────────────────
# If core is already bootstrapped, skip straight to re-running convergence
# rather than re-fetching — re-running this script must always be safe.
if [[ -e "${MODULE_DIR}/current" ]]; then
    log "core already bootstrapped at ${MODULE_DIR}/current — re-running convergence"
    exec "${MODULE_DIR}/current/bin/wb" install "$@"
fi

# ── 2. Bare-minimum prereq check ─────────────────────────────────────────────
# curl and tar only. Full prereq coverage (awk/sed/tr/grep/column/git/
# ssh-keyscan/ssh-keygen) is `bin/wb install`'s job (lib/core/prereqs.sh) —
# that code doesn't exist locally yet at this point.
for _wb_bin in curl tar; do
    command -v "${_wb_bin}" >/dev/null 2>&1 || { log "ERROR: '${_wb_bin}' is required but not found"; exit 1; }
done
unset _wb_bin

# _slugify <string> — byte-identical to lib/distribution/snapshot.sh's
# _wb_slugify: lowercase, anything outside [a-z0-9._-] collapsed to '-'.
# Must match exactly — a later real sync cycle for core computes the same
# module's snapshot dirname independently, and the two need to agree.
_slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-'
}

# _gh_curl <url> — GitHub's API requires a User-Agent header on every
# request (rejected outright without one, independent of rate limiting).
# Duplicated from lib/distribution/resolve.sh's _wb_gh_curl.
_gh_curl() {
    curl -fsSL -H "Accept: application/vnd.github+json" -A "workbench-core-bootstrap" "$1" 2>/dev/null
}

# _is_clean_tag / _cmp — duplicated (minimal) from lib/core/semver.sh's
# _wb_semver_is_clean_tag / _wb_semver_cmp: only clean, three-segment,
# v-prefixed tags participate in `latest` resolution (ARCHITECTURE.md §9.2).
_is_clean_tag() {
    local tag="$1"
    case "${tag}" in v*) : ;; *) return 1 ;; esac
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

# ── 3. Resolve a ref ──────────────────────────────────────────────────────────
# Latest vX.Y.Z tag via GitHub's unauthenticated API, same tag-format
# contract as ARCHITECTURE.md §9.2/contracts/tracking-spec.md. Trap: if no
# conforming tag exists yet — true at bootstrap.sh's own introduction,
# before any release has been cut — fall back to `main` with a clear
# warning. This isn't just a bring-up convenience: without it, bootstrap is
# unconditionally broken until the first tag exists. Keep this fallback
# permanently, don't strip it once a tag exists.
log "resolving latest release for ${OWNER}/${REPO}..."
_tags_json="$(_gh_curl "https://api.github.com/repos/${OWNER}/${REPO}/tags?per_page=100" || true)"

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
    REF_PATH="refs/tags/${_best_tag}"
    REF_SLUG="$(_slugify "${_best_tag}")"
    SHA="${_best_sha}"
    TRACK_MODE="latest"
    TRACK_REF="${_best_tag}"
    log "resolved release: ${_best_tag} (${SHA:0:7})"
else
    log "WARNING: no vX.Y.Z release tag found yet for ${OWNER}/${REPO} — falling back to 'main'"
    SHA="$(_gh_curl "https://api.github.com/repos/${OWNER}/${REPO}/commits/main" \
        | grep -o '"sha":[^,]*' | head -1 | grep -oE '[0-9a-f]{40}' || true)"
    if [[ -z "${SHA}" ]]; then
        log "ERROR: could not resolve 'main' to a commit via the GitHub API"
        exit 1
    fi
    REF_PATH="refs/heads/main"
    REF_SLUG="$(_slugify "main")"
    TRACK_MODE="latest"
    TRACK_REF="main"
    log "resolved fallback: main (${SHA:0:7})"
fi
SHORT_SHA="${SHA:0:7}"

# ── 4. Fetch + extract directly into the real, permanent snapshot path ──────
# Never a scratch/temp directory with `current` symlinked to it — a
# tmp-cleaner sweep or reboot can silently delete a temp directory later,
# breaking the loader with no obvious cause, days after a quick manual test
# looked fine (fix-brief §3.4). Writing straight into
# snapshots/<ref-slug>-<shortsha>/ means core's very first snapshot is
# indistinguishable from one an ordinary sync cycle would have produced —
# the exact same shape ARCHITECTURE.md §9.3 defines.
DEST="${MODULE_DIR}/snapshots/${REF_SLUG}-${SHORT_SHA}"

if [[ ! -e "${DEST}" ]]; then
    log "fetching ${OWNER}/${REPO}@${SHORT_SHA}..."
    _tmp_tar="$(mktemp "${TMPDIR:-/tmp}/workbench-bootstrap.XXXXXX")"
    _tmp_extract="$(mktemp -d "${TMPDIR:-/tmp}/workbench-bootstrap.XXXXXX")"
    trap 'rm -f "${_tmp_tar}"; rm -rf "${_tmp_extract}"' EXIT

    curl -fsSL "https://codeload.github.com/${OWNER}/${REPO}/tar.gz/${REF_PATH}" -o "${_tmp_tar}"
    tar -xzf "${_tmp_tar}" -C "${_tmp_extract}"
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

# ── 5. Write core's sync.conf directly ───────────────────────────────────────
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

# ── 6. Hand off ───────────────────────────────────────────────────────────────
# bin/wb install's own bootstrap step (_wb_bootstrap_core_module) sees core
# already registered with a real current/ directory and returns immediately
# — its `.git`-presence branch is the developer-clone case only and is
# never reached from here. See that function's header comment in bin/wb.
exec "${DEST}/bin/wb" install "$@"
