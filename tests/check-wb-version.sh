#!/usr/bin/env bash
# tests/check-wb-version.sh — bootstrap-fix brief §6 item 9 acceptance check.
#
# Covers the script-versioning half of the brief (§5): `wb version` lists
# every file registered in §5.2's scope with no gaps (catches a forgotten
# registration line) and no duplicate/colliding entries after a full bin/wb
# source pass, and workbench_release_version reads the repo-root VERSION
# file correctly from both a dev checkout and a fetched snapshot (a plain
# copy of the tree elsewhere — no distribution engine involved, since the
# only thing under test is the "wherever this lib is running from" relative
# path in lib/core/version.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WB="${REPO_ROOT}/bin/wb"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
mkdir -p "${HOME}"

# ── 1. `wb version` runs cleanly and prints a release line ─────────────────
OUT="$(bash "${WB}" version 2>&1)"
if echo "${OUT}" | grep -q "^\[INFO\]  workbench-core release:"; then
    ok "wb version prints a release version line"
else
    fail "wb version did not print a release version line"
    echo "${OUT}"
fi

# ── 2a. Every file bin/wb's own dispatch pass actually sources shows up in
#    `wb version`'s output. lib/loader.sh and lib/manifest/validate.sh are
#    NOT expected here — bin/wb never sources either (loader.sh is a
#    separate entry point sourced only by the ~/.bashrc/~/.zshrc stub;
#    validate.sh is a standalone developer-time script run directly, not
#    sourced by anything) — that's architecture, not a gap; §2b below
#    checks those two have their own registration line a different way. ────
{
    echo "bin/wb"
    sed -n '/^for _wb_f in \\/,/^    ; do/p' "${WB}" \
        | grep -v '^for \|^    ; do' \
        | tr -s ' \t' '\n' \
        | grep -vE '^\\?$' \
        | sed 's|^|lib/|'
} > "${WORK}/expected-dispatch-files.txt"

MISSING=""
while IFS= read -r relpath; do
    [[ -z "${relpath}" ]] && continue
    if ! echo "${OUT}" | grep -qF "  ${relpath}  v"; then
        MISSING="${MISSING}${relpath}\n"
    fi
done < "${WORK}/expected-dispatch-files.txt"

if [[ -z "${MISSING}" ]]; then
    ok "wb version lists every file bin/wb's own dispatch pass sources — no forgotten registration line"
else
    fail "wb version is missing entries for:"
    printf "${MISSING}" >&2
fi

# ── 2b. Every file in the full §5.2 scope — bin/wb, lib/loader.sh, and
#    every file under lib/ — has its own registration line present in
#    source, whether or not bin/wb's dispatch pass reaches it. ─────────────
: > "${WORK}/missing-registration-line.txt"
check_has_line() {
    local abspath="$1" relpath="$2"
    grep -q "workbench_register_script_version \"${relpath}\"" "${abspath}" \
        || echo "${relpath}" >> "${WORK}/missing-registration-line.txt"
}
check_has_line "${REPO_ROOT}/bin/wb" "bin/wb"
check_has_line "${REPO_ROOT}/lib/loader.sh" "lib/loader.sh"
while IFS= read -r abspath; do
    relpath="lib/${abspath#"${REPO_ROOT}"/lib/}"
    check_has_line "${abspath}" "${relpath}"
done < <(find "${REPO_ROOT}/lib" -type f -name '*.sh')

if [[ ! -s "${WORK}/missing-registration-line.txt" ]]; then
    ok "every file in §5.2's full scope (bin/wb, lib/loader.sh, all of lib/*.sh) has its own registration line"
else
    fail "missing a workbench_register_script_version line for:"
    cat "${WORK}/missing-registration-line.txt" >&2
fi

# ── 3. No duplicate/colliding entries after a full bin/wb source pass ──────
LISTED_PATHS="$(echo "${OUT}" | grep -E '^  (bin/wb|lib/)' | awk '{print $1}')"
DUP_COUNT="$(printf '%s\n' "${LISTED_PATHS}" | sort | uniq -d | wc -l | tr -d ' ')"
TOTAL_COUNT="$(printf '%s\n' "${LISTED_PATHS}" | grep -c .)"
UNIQUE_COUNT="$(printf '%s\n' "${LISTED_PATHS}" | sort -u | grep -c .)"

if [[ "${DUP_COUNT}" -eq 0 && "${TOTAL_COUNT}" -eq "${UNIQUE_COUNT}" ]]; then
    ok "no duplicate/colliding entries in the listed script versions (${TOTAL_COUNT} unique entries)"
else
    fail "duplicate entries found in wb version output: ${DUP_COUNT} duplicated path(s)"
    printf '%s\n' "${LISTED_PATHS}" | sort | uniq -c | sort -rn | head -5
fi

# ── 4. workbench_release_version reads VERSION from a dev checkout ─────────
rc=0
(
    source "${REPO_ROOT}/lib/core/log.sh"
    source "${REPO_ROOT}/lib/core/version.sh"
    [[ "$(workbench_release_version)" == "$(head -n1 "${REPO_ROOT}/VERSION")" ]] || exit 1
) || rc=$?
if [[ "${rc}" -eq 0 ]]; then
    ok "workbench_release_version reads VERSION correctly from a dev checkout"
else
    fail "workbench_release_version did not read the dev checkout's VERSION correctly"
fi

# ── 5. workbench_release_version reads VERSION from a fetched snapshot ─────
# A "fetched snapshot" is just the repo tree living at some other path on
# disk (that's the whole point of the relative-path design — see
# lib/core/version.sh's own comment) — a plain copy stands in for one here
# without invoking the distribution engine, which isn't what this test is
# checking.
SNAP="${WORK}/fake-snapshot"
mkdir -p "${SNAP}/lib/core"
echo "v7.7.7-snapshot-test" > "${SNAP}/VERSION"
cp "${REPO_ROOT}/lib/core/version.sh" "${SNAP}/lib/core/version.sh"
cp "${REPO_ROOT}/lib/core/log.sh" "${SNAP}/lib/core/log.sh"

rc=0
(
    source "${SNAP}/lib/core/log.sh"
    source "${SNAP}/lib/core/version.sh"
    [[ "$(workbench_release_version)" == "v7.7.7-snapshot-test" ]] || exit 1
) || rc=$?
if [[ "${rc}" -eq 0 ]]; then
    ok "workbench_release_version reads VERSION correctly from a fetched-snapshot-shaped tree"
else
    fail "workbench_release_version did not read the snapshot tree's VERSION correctly"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
