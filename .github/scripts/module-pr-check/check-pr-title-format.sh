#!/usr/bin/env bash
# .github/scripts/module-pr-check/check-pr-title-format.sh <pr-title>
#
# Module-repo simplification of core's own
# .github/scripts/release/check-pr-title-format.sh: module repos carry no
# per-file registered-script convention and compute-bump.sh never resolves
# a scope (docs/decisions-log.md D40), so this checks grammar only -- no
# base/head diff, no scope-vs-registered-file rule (that's D55, core-only).
#
# Module repos squash-merge PRs the same way core does, so the same D47
# hazard applies: an unparseable PR title becomes an unparseable squash
# commit on main, and compute-bump.sh silently drops that merge's
# severity -- a real, merged change ships with zero version bump.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/module-release/lib.sh
source "${SCRIPT_DIR}/../module-release/lib.sh"

PR_TITLE="${1:?usage: check-pr-title-format.sh <pr-title>}"

if _rel_parse_header "${PR_TITLE}" >/dev/null; then
    echo "check-pr-title-format: PR title parses as a Conventional Commit: '${PR_TITLE}'"
    exit 0
fi

echo "FAIL: PR title doesn't parse as a Conventional Commit: '${PR_TITLE}'" >&2
echo "      expected: <feat|fix|perf|refactor|docs|test|chore|ci|build>[(scope)][!]: <subject>" >&2
echo "      this repo squash-merges PRs, and GitHub uses the PR title as the squash" >&2
echo "      commit's subject -- an unparseable title silently drops this merge's" >&2
echo "      release severity even if every individual commit was formatted correctly." >&2
exit 1
