#!/usr/bin/env bash
# .github/scripts/module-release/apply-bump.sh <overall-line>
#
# Module-repo simplification of core's own apply-bumps.sh: CHANGELOG
# rewrite only -- no per-file version bump, no VERSION file (the release
# branch name release/v<version> carries the version; module-release-
# finalize.yml reads it back from there rather than from a repo-local
# VERSION file, ARCHITECTURE.md S12 D40). Gated on a non-empty CHANGELOG
# [Unreleased] section.
#
# <overall-line> is compute-bump.sh's own `OVERALL|<old>|<new>|<sev>|<reason>`
# output line. A no-op (exit 0) when severity is "none".
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/module-release/lib.sh
source "${SCRIPT_DIR}/lib.sh"

OVERALL_LINE="${1:?usage: apply-bump.sh '<OVERALL|old|new|sev|reason line>'}"
IFS='|' read -r _ OVERALL_OLD OVERALL_NEW OVERALL_SEV OVERALL_REASON <<< "${OVERALL_LINE}"

if [[ "${OVERALL_SEV}" == "none" ]]; then
    echo "apply-bump: severity is none -- nothing to apply." >&2
    exit 0
fi

CHANGELOG="CHANGELOG.md"
[[ -f "${CHANGELOG}" ]] || { echo "apply-bump: no CHANGELOG.md in this repo." >&2; exit 1; }

if ! _rel_changelog_has_entries "${CHANGELOG}"; then
    echo "apply-bump: refusing to release ${OVERALL_NEW} -- CHANGELOG.md's [Unreleased] section is empty. Add an entry before this can ship." >&2
    exit 1
fi

TODAY="$(date -u +%Y-%m-%d)"
_rel_changelog_release "${CHANGELOG}" "${OVERALL_NEW}" "${TODAY}"
echo "apply-bump: CHANGELOG.md [Unreleased] -> [${OVERALL_NEW}] - ${TODAY} (${OVERALL_OLD} -> ${OVERALL_NEW}, ${OVERALL_SEV}, ${OVERALL_REASON})" >&2
