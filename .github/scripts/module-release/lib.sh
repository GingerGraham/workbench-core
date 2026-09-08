#!/usr/bin/env bash
# .github/scripts/module-release/lib.sh -- shared primitives for the
# module-repo release pipeline (ARCHITECTURE.md S12 D40). Deliberately a
# separate, smaller copy of core's own .github/scripts/release/lib.sh
# rather than a re-source of it: that file's REPO_ROOT/registered-file
# machinery is wired to core's own bin/lib tree and its per-file
# _workbench_register_script_version convention, neither of which exists
# in a module repo's checkout. Only the genuinely generic pieces --
# Conventional Commit parsing/severity and the CHANGELOG [Unreleased]
# gate/rewrite -- are reused here, copied rather than sourced across repos
# to avoid a fragile path-relative coupling to core's own tree layout.
#
# Dev/release tooling only -- runs on GitHub-hosted ubuntu-latest runners,
# free to use bash 4+ features (unlike everything under a module's own
# shell/, which stays bash-3.2-safe per each module's own conventions).
set -uo pipefail

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

# _rel_max_sev <a> <b> -- prints whichever of the two severities ranks higher.
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
# _rel_bump_semver <old X.Y.Z> <severity> -- prints the bumped version.
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

# ── Conventional Commit parsing ──────────────────────────────────────────
# _rel_parse_header <header line>
# Prints "type|scope|breaking" (breaking is 1/0) and returns 0 iff the
# header matches `type[(scope)][!]: subject` AND type is one of the
# recognised Conventional Commit types.
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

# ── CHANGELOG [Unreleased] gate/rewrite ──────────────────────────────────
# _rel_changelog_has_entries <changelog path> -- true iff the [Unreleased]
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
