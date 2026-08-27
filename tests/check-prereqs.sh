#!/usr/bin/env bash
# tests/check-prereqs.sh — Phase 1 acceptance check.
# Plain bash, numbered checks, FAIL:/OK: summary — matches the donor
# codebase's tests/*.sh conventions (build brief §3, "Test conventions").
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/core/prereqs.sh
source "${REPO_ROOT}/lib/core/prereqs.sh"

FAILED=0
check_no=0

ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

# 1. version file template exists and has all four keys
if [[ -f "${REPO_ROOT}/lib/core/version-defaults.conf" ]]; then
    ok "version-defaults.conf exists"
else
    fail "version-defaults.conf missing"
fi

for key in CORE_API_VERSION MANIFEST_SCHEMA_VERSION STATE_SCHEMA_VERSION WORKBENCH_CORE_SEMVER; do
    if grep -q "^${key}=" "${REPO_ROOT}/lib/core/version-defaults.conf" 2>/dev/null; then
        ok "version-defaults.conf declares ${key}"
    else
        fail "version-defaults.conf missing ${key}"
    fi
done

# 2. workbench_ensure_version_file + workbench_read_version_var round-trip,
#    in an isolated XDG_CONFIG_HOME so this never touches the real machine.
TMP_XDG="$(mktemp -d)"
trap 'rm -rf "${TMP_XDG}"' EXIT

rc=0
(
    export XDG_CONFIG_HOME="${TMP_XDG}"
    source "${REPO_ROOT}/lib/core/version.sh"
    workbench_ensure_version_file
    [[ -f "${TMP_XDG}/workbench/core/version" ]] || exit 1
    [[ "$(workbench_core_api_version)" == "1" ]] || exit 1
    [[ "$(workbench_core_semver)" == "0.1.0" ]] || exit 1
) || rc=$?
if [[ "${rc}" -eq 0 ]]; then
    ok "version file installs and reads back correctly under isolated XDG_CONFIG_HOME"
else
    fail "version file install/read round-trip failed"
fi

# 3. workbench_ensure_version_file never overwrites an existing file
rc=0
(
    export XDG_CONFIG_HOME="${TMP_XDG}"
    source "${REPO_ROOT}/lib/core/version.sh"
    echo "CORE_API_VERSION=99" > "${TMP_XDG}/workbench/core/version"
    workbench_ensure_version_file
    [[ "$(workbench_core_api_version)" == "99" ]] || exit 1
) || rc=$?
if [[ "${rc}" -eq 0 ]]; then
    ok "workbench_ensure_version_file does not clobber an existing version file"
else
    fail "workbench_ensure_version_file overwrote an existing version file"
fi

# 4. prereq checker enumerates the full required list from ARCHITECTURE.md §7
for bin in awk sed tr grep column git curl ssh-keyscan; do
    if printf '%s\n' "${_WB_SHELL_PREREQS_REQUIRED[@]}" | grep -qx "${bin}"; then
        ok "prereq list includes ${bin}"
    else
        fail "prereq list is missing ${bin}"
    fi
done

# 5. curl is a hard (required) prereq, not optional — build brief Phase 1
if printf '%s\n' "${_WB_SHELL_PREREQS_OPTIONAL[@]}" | grep -qx "curl"; then
    fail "curl must not be in the optional prereq list"
else
    ok "curl is not in the optional prereq list"
fi

# 6. workbench_missing_shell_prereqs only reports genuinely-absent binaries
missing="$(workbench_missing_shell_prereqs)"
for bin in ${missing}; do
    if command -v "${bin}" &>/dev/null; then
        fail "workbench_missing_shell_prereqs reported '${bin}' but it is present"
    fi
done
ok "workbench_missing_shell_prereqs only reports binaries actually absent from PATH"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
