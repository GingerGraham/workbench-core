#!/usr/bin/env bash
# .github/scripts/module-release/compute-bump.sh
#
# Module-repo simplification of core's own compute-bumps.sh: repo-level
# version/tag only (ARCHITECTURE.md S12 D40) -- module repos carry no
# per-file _workbench_register_script_version convention to bump, so
# there's a single overall severity, not a per-file plan. Walks every
# commit since the last vX.Y.Z tag reachable from HEAD, takes the highest
# severity of any commit (unparseable commits are skipped with a warning,
# not fatal -- module-pr-check.yml is the point where a bad header should
# already have been caught), and prints one line:
#
#   OVERALL|<old-version>|<new-version>|<severity>|<reason>
#
# Always exits 0, including "nothing to release" (severity none) -- the
# caller decides whether to proceed by reading this line.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/module-release/lib.sh
source "${SCRIPT_DIR}/lib.sh"

PREV_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)"
if [[ -z "${PREV_TAG}" ]]; then
    echo "compute-bump: no previous vX.Y.Z tag reachable from HEAD -- treating this as the first release." >&2
    OLD_VERSION="0.0.0"
else
    OLD_VERSION="${PREV_TAG#v}"
fi

OVERALL_SEV="none"

commit_list() {
    if [[ -n "${PREV_TAG}" ]]; then
        git log --format=%H "${PREV_TAG}..HEAD"
    else
        git log --format=%H
    fi
}

while IFS= read -r sha; do
    [[ -z "${sha}" ]] && continue
    message="$(git log -1 --format=%B "${sha}")"
    header="$(head -1 <<< "${message}")"
    severity="$(_rel_commit_severity "${message}")"
    if [[ "${severity}" == "unparseable" ]]; then
        echo "WARNING: commit ${sha:0:7} ('${header}') doesn't parse as a Conventional Commit -- not contributing to any bump. module-pr-check.yml should have caught this at PR time." >&2
        continue
    fi
    OVERALL_SEV="$(_rel_max_sev "${OVERALL_SEV}" "${severity}")"
done < <(commit_list)

if [[ "${OVERALL_SEV}" == "none" ]]; then
    echo "OVERALL|${OLD_VERSION}|${OLD_VERSION}|none|no qualifying commit this cycle"
else
    NEW_VERSION="$(_rel_bump_semver "${OLD_VERSION}" "${OVERALL_SEV}")"
    echo "OVERALL|${OLD_VERSION}|${NEW_VERSION}|${OVERALL_SEV}|highest-severity qualifying commit"
fi
