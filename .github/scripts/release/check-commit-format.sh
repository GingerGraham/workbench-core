#!/usr/bin/env bash
# .github/scripts/release/check-commit-format.sh <base-sha> <head-sha>
#
# §3.4's PR-time gate: for every commit in (<base-sha>, <head-sha>], if it
# touches a registered file and its message's Conventional Commit type
# doesn't parse, fail. This is where "fail loud" actually bites — at PR
# time, while the message is still fixable — rather than after merge, when
# compute-bumps.sh only warns and moves on (§3.1). ARCHITECTURE.md §12 D27.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/release/lib.sh
source "${SCRIPT_DIR}/lib.sh"

BASE_SHA="${1:?usage: check-commit-format.sh <base-sha> <head-sha>}"
HEAD_SHA="${2:?usage: check-commit-format.sh <base-sha> <head-sha>}"

cd "${REPO_ROOT}" || exit 1

FAILED=0

while IFS= read -r sha; do
    [[ -z "${sha}" ]] && continue
    message="$(git log -1 --format=%B "${sha}")"
    header="$(head -1 <<< "${message}")"

    touches_registered="false"
    while IFS= read -r f; do
        [[ -z "${f}" ]] && continue
        _rel_is_registered "${f}" && touches_registered="true"
    done < <(git diff-tree --no-commit-id --name-only -r "${sha}")

    [[ "${touches_registered}" == "true" ]] || continue

    if ! _rel_parse_header "${header}" >/dev/null; then
        echo "FAIL: ${sha:0:7} touches a registered file but its message doesn't parse as a Conventional Commit: '${header}'" >&2
        echo "      expected: <feat|fix|perf|refactor|docs|test|chore|ci|build>[(scope)][!]: <subject>" >&2
        FAILED=1
    fi
done < <(git log --format=%H "${BASE_SHA}..${HEAD_SHA}")

if [[ "${FAILED}" -eq 0 ]]; then
    echo "check-commit-format: all commits touching registered files parse correctly."
fi

exit "${FAILED}"
