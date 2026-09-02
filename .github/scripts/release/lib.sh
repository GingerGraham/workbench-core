#!/usr/bin/env bash
# .github/scripts/release/lib.sh — shared primitives for the release
# pipeline: Conventional Commit parsing, bump arithmetic, the registered-
# file registry, and the CHANGELOG [Unreleased] gate/rewrite.
#
# Dev/release tooling only — never shipped to a user machine, never sourced
# by lib/loader.sh — so unlike everything under lib/, this is free to use
# bash 4+ features and runs only on GitHub-hosted ubuntu-latest runners.
#
# ARCHITECTURE.md §12 D27 / docs/release-process.md.
set -uo pipefail

_REL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# WORKBENCH_RELEASE_TEST_REPO_ROOT lets tests/check-release-bump.sh point
# every _rel_* file operation at an isolated fixture repo instead of this
# real checkout, without needing a second copy of this library.
REPO_ROOT="${WORKBENCH_RELEASE_TEST_REPO_ROOT:-$(cd "${_REL_LIB_DIR}/../../.." && pwd)}"

# shellcheck source=lib/core/semver.sh
source "${REPO_ROOT}/lib/core/semver.sh"

# ── Severity ranking ─────────────────────────────────────────────────────
_rel_sev_rank() {
    case "$1" in
        none) echo 0 ;;
        patch) echo 1 ;;
        minor) echo 2 ;;
        major) echo 3 ;;
        *) echo 0 ;;
    esac
}

# _rel_max_sev <a> <b> — prints whichever of the two severities ranks higher.
_rel_max_sev() {
    local ra rb
    ra="$(_rel_sev_rank "$1")"
    rb="$(_rel_sev_rank "$2")"
    if [[ "${ra}" -ge "${rb}" ]]; then
        echo "$1"
    else
        echo "$2"
    fi
}

# ── Bump arithmetic ──────────────────────────────────────────────────────
# _rel_bump_semver <old X.Y.Z> <severity> — prints the bumped version.
# major: X+1.0.0 · minor: X.Y+1.0 · patch: X.Y.Z+1 · none: prints <old>
# unchanged.
_rel_bump_semver() {
    local old="$1" severity="$2"
    local -a parts
    IFS='.' read -r -a parts <<< "${old}"
    local x="${parts[0]:-0}" y="${parts[1]:-0}" z="${parts[2]:-0}"
    case "${severity}" in
        major) echo "$((x + 1)).0.0" ;;
        minor) echo "${x}.$((y + 1)).0" ;;
        patch) echo "${x}.${y}.$((z + 1))" ;;
        none) echo "${old}" ;;
        *)
            echo "_rel_bump_semver: unknown severity '${severity}'" >&2
            return 1
            ;;
    esac
}

# ── Registered-file registry ─────────────────────────────────────────────
# A file is "registered" iff it contains a
# `_workbench_register_script_version "<path>"` call naming its own
# repo-relative path — true for every operational file under bin/wb,
# lib/**/*.sh, and bootstrap.sh (whose second argument is the
# `_WB_BOOTSTRAP_VERSION` variable rather than a literal — see bootstrap.sh's
# own comment on why). Path-matching via grep is uniform either way; only
# reading/writing the version differs for bootstrap.sh (_rel_current_version/
# _rel_set_version below).
_rel_registered_files() {
    grep -rlE '_workbench_register_script_version[[:space:]]+"[^"]+"' \
        "${REPO_ROOT}/bin" "${REPO_ROOT}/lib" "${REPO_ROOT}/bootstrap.sh" 2>/dev/null \
        | sed "s#^${REPO_ROOT}/##" \
        | sort
}

# _rel_is_registered <path> — true iff <path> is in the registered set.
_rel_is_registered() {
    local path="$1"
    _rel_registered_files | grep -qxF "${path}"
}

# _rel_current_version <path> — prints that file's current script-local
# version, read from disk.
_rel_current_version() {
    local path="$1" file="${REPO_ROOT}/$1"
    case "${path}" in
        bootstrap.sh)
            grep -oE '_WB_BOOTSTRAP_VERSION="[0-9]+\.[0-9]+\.[0-9]+"' "${file}" \
                | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
            ;;
        *)
            grep -F "_workbench_register_script_version \"${path}\"" "${file}" \
                | head -1 | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' | tail -1 | tr -d '"'
            ;;
    esac
}

# _rel_set_version <path> <new_version> — rewrites that file's version line
# in place, exact string match/replace on the existing line only. Asserts
# the new version compares greater than the old one via _wb_semver_cmp
# (lib/core/semver.sh) first — fail loudly if not (§3.2's sanity check).
_rel_set_version() {
    local path="$1" new="$2" file="${REPO_ROOT}/$1" old cmp
    old="$(_rel_current_version "${path}")"
    if [[ -z "${old}" ]]; then
        echo "_rel_set_version: could not read current version for '${path}'" >&2
        return 1
    fi
    cmp="$(_wb_semver_cmp "${new}" "${old}")"
    if [[ "${cmp}" != "1" ]]; then
        echo "_rel_set_version: refusing to write '${path}' version ${old} -> ${new} (not greater)" >&2
        return 1
    fi
    case "${path}" in
        bootstrap.sh)
            sed -i.bak -E "s#_WB_BOOTSTRAP_VERSION=\"${old}\"#_WB_BOOTSTRAP_VERSION=\"${new}\"#" "${file}"
            ;;
        *)
            sed -i.bak -E "s#(_workbench_register_script_version \"${path}\" )\"${old}\"#\\1\"${new}\"#" "${file}"
            ;;
    esac
    rm -f "${file}.bak"
}

# ── Conventional Commit parsing ──────────────────────────────────────────
# _rel_parse_header <header line>
# Prints "type|scope|breaking" (breaking is 1/0) and returns 0 iff the
# header matches `type[(scope)][!]: subject` AND type is one of the
# recognised Conventional Commit types. Prints nothing and returns 1
# otherwise (grammar mismatch, or a type outside the recognised set) — both
# collapse to "unparseable" per §3.1, since neither yields a determinable
# bump severity.
_rel_parse_header() {
    local header="$1"
    local type scope="" breaking=0
    local pattern='^([a-zA-Z]+)(\(([^)]+)\))?(!)?:[[:space:]]+.+$'
    if [[ "${header}" =~ ${pattern} ]]; then
        type="${BASH_REMATCH[1]}"
        scope="${BASH_REMATCH[3]:-}"
        [[ -n "${BASH_REMATCH[4]:-}" ]] && breaking=1
    else
        return 1
    fi
    case "${type}" in
        feat|fix|perf|refactor|docs|test|chore|ci|build) : ;;
        *) return 1 ;;
    esac
    printf '%s|%s|%s\n' "${type}" "${scope}" "${breaking}"
}

# _rel_commit_severity <full commit message>
# Prints one of major/minor/patch/none/unparseable. A `BREAKING CHANGE:` (or
# `BREAKING-CHANGE:`) footer anywhere in the body forces major regardless of
# type, same as a trailing `!`.
_rel_commit_severity() {
    local message="$1" header parsed type breaking
    header="$(head -1 <<< "${message}")"
    if ! parsed="$(_rel_parse_header "${header}")"; then
        echo "unparseable"
        return 0
    fi
    type="${parsed%%|*}"
    breaking="${parsed##*|}"
    if [[ "${breaking}" == "1" ]] || grep -qE '^BREAKING[ -]CHANGE:' <<< "${message}"; then
        echo "major"
        return 0
    fi
    case "${type}" in
        feat) echo "minor" ;;
        fix|perf) echo "patch" ;;
        *) echo "none" ;;
    esac
}

# _rel_commit_scope <header line> — prints the explicit scope (empty if
# none was given). Assumes the header already parsed successfully.
_rel_commit_scope() {
    local parsed
    parsed="$(_rel_parse_header "$1")" || return 0
    parsed="${parsed#*|}"
    echo "${parsed%%|*}"
}

# ── CHANGELOG [Unreleased] gate/rewrite ──────────────────────────────────
# _rel_changelog_has_entries <changelog path> — true iff the [Unreleased]
# section contains at least one non-blank line before the next heading.
_rel_changelog_has_entries() {
    local file="$1"
    awk '
        /^## \[Unreleased\]/ { infile=1; next }
        infile && /^## \[/ { exit }
        infile && NF { found=1 }
        END { exit !found }
    ' "${file}"
}

# _rel_changelog_release <changelog path> <new version> <YYYY-MM-DD>
# Renames "## [Unreleased]" to "## [<version>] - <date>" and inserts a
# fresh empty "## [Unreleased]" heading above it.
_rel_changelog_release() {
    local file="$1" version="$2" date="$3" tmp
    tmp="$(mktemp)"
    awk -v version="${version}" -v date="${date}" '
        /^## \[Unreleased\]/ {
            print "## [Unreleased]"
            print ""
            print "## [" version "] - " date
            next
        }
        { print }
    ' "${file}" > "${tmp}"
    mv "${tmp}" "${file}"
}
