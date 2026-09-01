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

# 2. _workbench_ensure_version_file + _workbench_read_version_var round-trip,
#    in an isolated XDG_CONFIG_HOME so this never touches the real machine.
TMP_XDG="$(mktemp -d)"
trap 'rm -rf "${TMP_XDG}"' EXIT

rc=0
(
    export XDG_CONFIG_HOME="${TMP_XDG}"
    source "${REPO_ROOT}/lib/core/version.sh"
    _workbench_ensure_version_file
    [[ -f "${TMP_XDG}/workbench/core/version" ]] || exit 1
    [[ "$(_workbench_core_api_version)" == "1" ]] || exit 1
    [[ "$(_workbench_core_semver)" == "0.1.0" ]] || exit 1
) || rc=$?
if [[ "${rc}" -eq 0 ]]; then
    ok "version file installs and reads back correctly under isolated XDG_CONFIG_HOME"
else
    fail "version file install/read round-trip failed"
fi

# 3. _workbench_ensure_version_file never overwrites an existing file
rc=0
(
    export XDG_CONFIG_HOME="${TMP_XDG}"
    source "${REPO_ROOT}/lib/core/version.sh"
    echo "CORE_API_VERSION=99" > "${TMP_XDG}/workbench/core/version"
    _workbench_ensure_version_file
    [[ "$(_workbench_core_api_version)" == "99" ]] || exit 1
) || rc=$?
if [[ "${rc}" -eq 0 ]]; then
    ok "_workbench_ensure_version_file does not clobber an existing version file"
else
    fail "_workbench_ensure_version_file overwrote an existing version file"
fi

# 3a. _workbench_migrate_state_schema bumps an existing STATE_SCHEMA_VERSION=1
#     up to the current value in place.
rc=0
(
    export XDG_CONFIG_HOME="${TMP_XDG}/migrate1"
    source "${REPO_ROOT}/lib/core/version.sh"
    _workbench_ensure_version_file
    _workbench_version_set_var STATE_SCHEMA_VERSION 1
    _workbench_migrate_state_schema
    [[ "$(_workbench_state_schema_version)" == "2" ]] || exit 1
) || rc=$?
if [[ "${rc}" -eq 0 ]]; then
    ok "_workbench_migrate_state_schema bumps an existing STATE_SCHEMA_VERSION=1 to the current version"
else
    fail "_workbench_migrate_state_schema did not bump an existing STATE_SCHEMA_VERSION as expected"
fi

# 3b. _workbench_version_set_var appends a key that's missing entirely
#     (rather than silently no-op'ing) — otherwise _workbench_migrate_state_schema
#     could never actually converge a version file with a dropped/corrupted
#     STATE_SCHEMA_VERSION line, re-"migrating" forever without it taking.
rc=0
(
    export XDG_CONFIG_HOME="${TMP_XDG}/migrate2"
    source "${REPO_ROOT}/lib/core/version.sh"
    _workbench_ensure_version_file
    VFILE="$(_workbench_version_file_path)"
    grep -v '^STATE_SCHEMA_VERSION=' "${VFILE}" > "${VFILE}.tmp" && mv "${VFILE}.tmp" "${VFILE}"
    [[ -z "$(_workbench_state_schema_version)" ]] || exit 1
    _workbench_migrate_state_schema
    [[ "$(_workbench_state_schema_version)" == "2" ]] || exit 1
) || rc=$?
if [[ "${rc}" -eq 0 ]]; then
    ok "_workbench_migrate_state_schema adds STATE_SCHEMA_VERSION when the key is missing entirely from the version file"
else
    fail "_workbench_migrate_state_schema failed to add a missing STATE_SCHEMA_VERSION key"
fi

# 3c. Running the migration again once already current is a no-op (no
#     duplicate STATE_SCHEMA_VERSION lines).
rc=0
(
    export XDG_CONFIG_HOME="${TMP_XDG}/migrate1"
    source "${REPO_ROOT}/lib/core/version.sh"
    _workbench_migrate_state_schema
    VFILE="$(_workbench_version_file_path)"
    [[ "$(grep -c '^STATE_SCHEMA_VERSION=' "${VFILE}")" -eq 1 ]] || exit 1
) || rc=$?
if [[ "${rc}" -eq 0 ]]; then
    ok "re-running _workbench_migrate_state_schema once already current does not duplicate the version line"
else
    fail "re-running _workbench_migrate_state_schema produced a duplicate STATE_SCHEMA_VERSION line"
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

# 5a. unzip and zip are optional prereqs (future Wave C module needs),
#     not required — mirrors gpg's existing treatment.
for bin in unzip zip; do
    if printf '%s\n' "${_WB_SHELL_PREREQS_OPTIONAL[@]}" | grep -qx "${bin}"; then
        ok "${bin} is in the optional prereq list"
    else
        fail "${bin} is missing from the optional prereq list"
    fi
    if printf '%s\n' "${_WB_SHELL_PREREQS_REQUIRED[@]}" | grep -qx "${bin}"; then
        fail "${bin} must not be in the required prereq list"
    else
        ok "${bin} is not in the required prereq list"
    fi
done

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
