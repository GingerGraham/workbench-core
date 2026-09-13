#!/usr/bin/env bash
# .github/scripts/release/check-pr-title-format.sh <pr-title> [<base-sha> <head-sha>]
#
# This repo merges PRs via squash-merge, and GitHub's default squash commit
# message uses the PR's *title* as the resulting commit's subject — not any
# of the PR's individual commit messages. check-commit-format.sh (§3.4)
# validates every individual commit in a PR, but a PR whose commits are each
# correctly Conventional-Commit-formatted can still land on `main` as a
# single unparseable commit if the PR *title* itself wasn't given a
# `type[(scope)][!]: subject` prefix — compute-bumps.sh then silently drops
# that merge's severity (§3.1's documented, intentional behaviour for an
# unparseable commit), exactly as an untitled PR did for #46. See
# ARCHITECTURE.md §12 D47.
#
# <base-sha>/<head-sha> are optional as a *pair*: when both are given, this
# also applies the 'core'-scope-vs-registered-file rule check-commit-format.sh
# applies per commit, but against the PR's *overall* diff — since the squash
# commit that actually reaches compute-bumps.sh only ever carries this
# title's scope, not any individual commit's (D47). Real incident this
# closes: PR #58/#59. ARCHITECTURE.md §12 D55. Omitting both skips that
# second check (grammar only) — existing callers without a diff range still
# work. Passing only one is treated as a caller error (fails loudly) rather
# than silently downgrading to grammar-only, since that shape almost always
# means a misconfigured caller rather than a deliberate choice.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/release/lib.sh
source "${SCRIPT_DIR}/lib.sh"

PR_TITLE="${1:?usage: check-pr-title-format.sh <pr-title> [<base-sha> <head-sha>]}"
BASE_SHA="${2:-}"
HEAD_SHA="${3:-}"

# <base-sha>/<head-sha> must be given together or not at all -- exactly one
# set almost certainly means a caller misconfiguration (e.g. a workflow
# passing an unresolved/empty SHA), and silently downgrading to grammar-only
# in that case would hide it rather than fail loudly.
if [[ -n "${BASE_SHA}" && -z "${HEAD_SHA}" ]] || [[ -z "${BASE_SHA}" && -n "${HEAD_SHA}" ]]; then
    echo "FAIL: check-pr-title-format.sh requires both <base-sha> and <head-sha>, or neither -- got base-sha='${BASE_SHA}' head-sha='${HEAD_SHA}'" >&2
    exit 1
fi

if ! _rel_parse_header "${PR_TITLE}" >/dev/null; then
    echo "FAIL: PR title doesn't parse as a Conventional Commit: '${PR_TITLE}'" >&2
    echo "      expected: <feat|fix|perf|refactor|docs|test|chore|ci|build>[(scope)][!]: <subject>" >&2
    echo "      this repo squash-merges PRs, and GitHub uses the PR title as the squash" >&2
    echo "      commit's subject — an unparseable title silently drops this merge's" >&2
    echo "      release severity even if every individual commit was formatted correctly." >&2
    exit 1
fi

echo "check-pr-title-format: PR title parses as a Conventional Commit: '${PR_TITLE}'"

if [[ -n "${BASE_SHA}" && -n "${HEAD_SHA}" ]] && [[ "$(_rel_commit_scope "${PR_TITLE}")" == "core" ]]; then
    cd "${REPO_ROOT}" || exit 1

    # Captured (not streamed via process substitution) so a failed `git diff`
    # (unreachable SHAs, a too-shallow checkout) is caught explicitly --
    # otherwise its non-zero exit is invisible to the while loop below, which
    # would just see empty output and let an unverifiable PR through as if it
    # touched no registered files.
    diff_output=""
    if ! diff_output="$(git diff --name-only "${BASE_SHA}..${HEAD_SHA}")"; then
        echo "FAIL: could not diff ${BASE_SHA}..${HEAD_SHA} -- are both SHAs reachable (fetch-depth: 0)?" >&2
        exit 1
    fi

    touches_registered="false"
    while IFS= read -r f; do
        [[ -z "${f}" ]] && continue
        _rel_is_registered "${f}" && touches_registered="true"
    done <<< "${diff_output}"

    if [[ "${touches_registered}" == "true" ]]; then
        echo "FAIL: PR title is scoped 'core' but this PR also touches a registered file: '${PR_TITLE}'" >&2
        echo "      'core' is an explicit override — compute-bumps.sh trusts it completely and" >&2
        echo "      never walks the commit's touched files, so this squash commit would leave" >&2
        echo "      every registered file the PR touches on its old script-local version. Drop" >&2
        echo "      the scope (let auto-detection bump each touched file) or scope explicitly to" >&2
        echo "      the touched file's own repo-relative path instead." >&2
        exit 1
    fi
    echo "check-pr-title-format: 'core' scope confirmed — no registered file touched by this PR."
fi

exit 0
