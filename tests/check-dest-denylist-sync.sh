#!/usr/bin/env bash
# tests/check-dest-denylist-sync.sh — docs/decisions-log.md D75 acceptance
# check. lib/manifest/validate.sh must run standalone (same precedent as
# D30/D46), so it cannot source its denylist from lib/manifest/parse.sh — the
# two copies are kept byte-identical by hand instead. This fails the moment
# they drift.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

PARSE_DIRS="$(grep -E '^_WB_DEST_DENYLIST_DIRS_REL=' "${REPO_ROOT}/lib/manifest/parse.sh")"
VALIDATE_DIRS="$(grep -E '^_WB_DEST_DENYLIST_DIRS_REL=' "${REPO_ROOT}/lib/manifest/validate.sh")"
PARSE_FILES="$(grep -E '^_WB_DEST_DENYLIST_FILES_REL=' "${REPO_ROOT}/lib/manifest/parse.sh")"
VALIDATE_FILES="$(grep -E '^_WB_DEST_DENYLIST_FILES_REL=' "${REPO_ROOT}/lib/manifest/validate.sh")"

if [[ -n "${PARSE_DIRS}" ]]; then
    ok "lib/manifest/parse.sh declares _WB_DEST_DENYLIST_DIRS_REL"
else
    fail "lib/manifest/parse.sh does not declare _WB_DEST_DENYLIST_DIRS_REL"
fi

if [[ -n "${VALIDATE_DIRS}" ]]; then
    ok "lib/manifest/validate.sh declares _WB_DEST_DENYLIST_DIRS_REL"
else
    fail "lib/manifest/validate.sh does not declare _WB_DEST_DENYLIST_DIRS_REL"
fi

if [[ "${PARSE_DIRS}" == "${VALIDATE_DIRS}" ]]; then
    ok "_WB_DEST_DENYLIST_DIRS_REL is byte-identical between parse.sh and validate.sh"
else
    fail "_WB_DEST_DENYLIST_DIRS_REL has drifted between parse.sh and validate.sh"
    echo "  parse.sh:    ${PARSE_DIRS}"
    echo "  validate.sh: ${VALIDATE_DIRS}"
fi

if [[ -n "${PARSE_FILES}" ]]; then
    ok "lib/manifest/parse.sh declares _WB_DEST_DENYLIST_FILES_REL"
else
    fail "lib/manifest/parse.sh does not declare _WB_DEST_DENYLIST_FILES_REL"
fi

if [[ -n "${VALIDATE_FILES}" ]]; then
    ok "lib/manifest/validate.sh declares _WB_DEST_DENYLIST_FILES_REL"
else
    fail "lib/manifest/validate.sh does not declare _WB_DEST_DENYLIST_FILES_REL"
fi

if [[ "${PARSE_FILES}" == "${VALIDATE_FILES}" ]]; then
    ok "_WB_DEST_DENYLIST_FILES_REL is byte-identical between parse.sh and validate.sh"
else
    fail "_WB_DEST_DENYLIST_FILES_REL has drifted between parse.sh and validate.sh"
    echo "  parse.sh:    ${PARSE_FILES}"
    echo "  validate.sh: ${VALIDATE_FILES}"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
