#!/usr/bin/env bash
# .github/scripts/module-pr-check/check-commit-format.sh <base-sha> <head-sha>
#
# Module-repo simplification of core's own
# .github/scripts/release/check-commit-format.sh: module repos carry no
# _workbench_register_script_version per-file convention (ARCHITECTURE.md
# S12 D40), so there is no basis to exempt any commit on content grounds --
# every non-merge commit in the PR's range must parse as a Conventional
# Commit, full stop. Merge commits ARE exempt (see below) since they're not
# something a contributor writes by hand.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/module-release/lib.sh
source "${SCRIPT_DIR}/../module-release/lib.sh"

BASE_SHA="${1:?usage: check-commit-format.sh <base-sha> <head-sha>}"
HEAD_SHA="${2:?usage: check-commit-format.sh <base-sha> <head-sha>}"

FAILED=0

while IFS= read -r sha; do
    [[ -z "${sha}" ]] && continue

    # Merge commits (2+ parents) are exempt: GitHub itself writes their
    # message (e.g. "Merge branch 'main' into <branch>") whenever a
    # contributor clicks the PR's "Update branch" button, or resolves a
    # conflict via GitHub's web merge editor -- it's not text the
    # contributor authored, so holding it to Conventional Commit grammar
    # only punishes keeping a branch current with its base.
    parent_count="$(git log -1 --format=%P "${sha}" | wc -w)"
    if [[ "${parent_count}" -gt 1 ]]; then
        echo "SKIP: ${sha:0:7} is a merge commit (${parent_count} parents) — exempt from Conventional Commit format."
        continue
    fi

    header="$(git log -1 --format=%B "${sha}" | head -1)"
    if ! _rel_parse_header "${header}" >/dev/null; then
        echo "FAIL: ${sha:0:7} does not parse as a Conventional Commit: '${header}'" >&2
        echo "      expected: <feat|fix|perf|refactor|docs|test|chore|ci|build>[(scope)][!]: <subject>" >&2
        FAILED=1
    fi
done < <(git log --format=%H "${BASE_SHA}..${HEAD_SHA}")

if [[ "${FAILED}" -eq 0 ]]; then
    echo "check-commit-format: all commits parse correctly."
fi

exit "${FAILED}"
