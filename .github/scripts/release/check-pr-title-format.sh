#!/usr/bin/env bash
# .github/scripts/release/check-pr-title-format.sh <pr-title>
#
# This repo merges PRs via squash-merge, and GitHub's default squash commit
# message uses the PR's *title* as the resulting commit's subject line —
# not any of the PR's individual commit messages. check-commit-format.sh
# (§3.4) validates every individual commit in a PR, but a PR whose commits
# are each correctly Conventional-Commit-formatted can still land on `main`
# as a single unparseable commit if the PR *title* itself wasn't given a
# `type[(scope)][!]: subject` prefix — compute-bumps.sh then silently drops
# that merge's severity (§3.1's documented, intentional behaviour for an
# unparseable commit), exactly as an untitled PR did for #46. See
# ARCHITECTURE.md §12 D47.
#
# This check closes that gap at PR time, the same "fail loud while it's
# still fixable" principle check-commit-format.sh already applies to
# individual commits.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/release/lib.sh
source "${SCRIPT_DIR}/lib.sh"

PR_TITLE="${1:?usage: check-pr-title-format.sh <pr-title>}"

if _rel_parse_header "${PR_TITLE}" >/dev/null; then
    echo "check-pr-title-format: PR title parses as a Conventional Commit: '${PR_TITLE}'"
    exit 0
fi

echo "FAIL: PR title doesn't parse as a Conventional Commit: '${PR_TITLE}'" >&2
echo "      expected: <feat|fix|perf|refactor|docs|test|chore|ci|build>[(scope)][!]: <subject>" >&2
echo "      this repo squash-merges PRs, and GitHub uses the PR title as the squash" >&2
echo "      commit's subject — an unparseable title silently drops this merge's" >&2
echo "      release severity even if every individual commit was formatted correctly." >&2
exit 1
