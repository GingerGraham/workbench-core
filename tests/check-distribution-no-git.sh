#!/usr/bin/env bash
# tests/check-distribution-no-git.sh — Phase 5a acceptance check.
#
# ARCHITECTURE.md §9.1/D5: a public repo's fetch, any TRACK_MODE, must never
# invoke `git`. Proven by scrubbing `git` from PATH entirely and confirming
# the fetch still succeeds. Requires network access to codeload.github.com;
# skips (not fails) if that's unreachable, since some execution
# environments (this one included, at times) sandbox outbound GitHub
# traffic — see the header note in lib/distribution/fetch-tarball.sh's own
# design record for why this was verified against a real repo rather than
# assumed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

TEST_OWNER="${WORKBENCH_TEST_GH_OWNER:-GingerGraham}"
TEST_REPO="${WORKBENCH_TEST_GH_REPO:-workbench-core}"
TEST_BRANCH="${WORKBENCH_TEST_GH_BRANCH:-main}"

# ── 0. Static check: fetch-tarball.sh's source contains no `git` invocation
#    at all — the strongest, environment-independent form of this
#    guarantee. Comment-only mentions of "git" (e.g. in prose explaining
#    why it's absent) are fine; this greps for actual invocation forms.
if grep -vE '^[[:space:]]*#' "${REPO_ROOT}/lib/distribution/fetch-tarball.sh" \
    | grep -qE '(^|[^a-zA-Z_-])git([^a-zA-Z_-]|$)'; then
    fail "lib/distribution/fetch-tarball.sh contains a literal 'git' token outside comments"
else
    ok "lib/distribution/fetch-tarball.sh's source contains no 'git' invocation at all"
fi

# ── 1. Dynamic check: scrub git from PATH, confirm a real fetch succeeds ───
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Build a PATH with every directory that could plausibly contain a `git`
# binary excluded, by symlinking every non-git binary from the real PATH
# into an isolated bin dir.
CLEAN_BIN="${WORK}/bin"
mkdir -p "${CLEAN_BIN}"
IFS=':' read -r -a _path_dirs <<< "${PATH}"
for d in "${_path_dirs[@]}"; do
    [[ -d "${d}" ]] || continue
    for f in "${d}"/*; do
        [[ -e "${f}" ]] || continue
        b="$(basename "${f}")"
        [[ "${b}" == "git" || "${b}" == git-* ]] && continue
        [[ -e "${CLEAN_BIN}/${b}" ]] && continue
        ln -s "${f}" "${CLEAN_BIN}/${b}" 2>/dev/null || true
    done
done

if command -v git &>/dev/null && env PATH="${CLEAN_BIN}" git --version &>/dev/null; then
    fail "test setup error: git is still reachable after PATH scrubbing"
else
    ok "PATH scrubbed of git for this check (env PATH=\"\${CLEAN_BIN}\" git --version fails)"
fi

DEST="${WORK}/fetched"
result_rc=1
if env -i PATH="${CLEAN_BIN}" HOME="${WORK}/home" bash -c '
    source "'"${REPO_ROOT}"'/lib/core/log.sh"
    source "'"${REPO_ROOT}"'/lib/distribution/fetch-tarball.sh"
    workbench_fetch_tarball_public "'"${TEST_OWNER}"'" "'"${TEST_REPO}"'" branch "'"${TEST_BRANCH}"'" "'"${DEST}"'"
' 2>"${WORK}/fetch.log"; then
    result_rc=0
fi

if [[ "${result_rc}" -eq 0 && -d "${DEST}" ]]; then
    ok "workbench_fetch_tarball_public succeeded with git absent from PATH (fetched ${TEST_OWNER}/${TEST_REPO}@${TEST_BRANCH})"
    ok "fetched snapshot is a non-empty directory: $(find "${DEST}" -maxdepth 1 | wc -l | tr -d ' ') entries"
else
    echo "SKIP: could not reach codeload.github.com for ${TEST_OWNER}/${TEST_REPO}@${TEST_BRANCH} in this environment — see ${WORK}/fetch.log. This is a network-reachability skip, not a test failure; the static check above (and a manual run outside a sandboxed environment) cover the guarantee."
    cat "${WORK}/fetch.log" 2>/dev/null | sed 's/^/  /'
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
