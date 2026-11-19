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

for key in CORE_API_VERSION STATE_SCHEMA_VERSION WORKBENCH_CORE_SEMVER; do
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
    # shellcheck disable=SC2030,SC2031
    export XDG_CONFIG_HOME="${TMP_XDG}"
    source "${REPO_ROOT}/lib/core/version.sh"
    _workbench_ensure_version_file
    [[ -f "${TMP_XDG}/workbench/core/version" ]] || exit 1
    [[ "$(_workbench_core_api_version)" == "1.8" ]] || exit 1
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
    # shellcheck disable=SC2030,SC2031
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
    # shellcheck disable=SC2030,SC2031
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
    # shellcheck disable=SC2030,SC2031
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
    # shellcheck disable=SC2030,SC2031
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

# 4. prereq checker enumerates the full required list from docs/architecture.md §7
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
missing_prereqs="$(workbench_missing_shell_prereqs)"
for bin in ${missing_prereqs}; do
    if command -v "${bin}" &>/dev/null; then
        fail "workbench_missing_shell_prereqs reported '${bin}' but it is present"
    fi
done
ok "workbench_missing_shell_prereqs only reports binaries actually absent from PATH"

# 7. sudo-test / get-elevation-command do not crash with "USER: unbound
#    variable" when $USER is unset — confirmed in a bare `docker run -it
#    fedora:latest` root shell, which never exports USER. bin/wb runs
#    under `set -uo pipefail`; before the fix, get-elevation-command's
#    `${USER}` reference inside elevate-cmd's own
#    `elevation_cmd="$(get-elevation-command)"` command substitution
#    killed that subshell with "unbound variable" — swallowed by
#    elevate-cmd's `|| return 1` — so wb install never actually invoked
#    the package manager for missing prereqs, silently. See
#    docs/decisions-log.md D52.
# shellcheck source=lib/core/functions.sh
source "${REPO_ROOT}/lib/core/functions.sh"
OUT="$( { unset USER; set -u; sudo-test; get-elevation-command; } 2>&1 )" || true
if printf '%s\n' "${OUT}" | grep -q "unbound variable"; then
    fail "sudo-test/get-elevation-command raise 'unbound variable' when \$USER is unset"
    echo "${OUT}"
else
    ok "sudo-test and get-elevation-command do not crash when \$USER is unset under set -u"
fi

# 8. Package names (D117): explicit rows for the binaries whose package
#    name differs from the binary, or that apt/pacman can't resolve alone.
_pkg_rows=(
    "apt:awk=mawk" "dnf:awk=gawk" "pacman:awk=gawk" "zypper:awk=gawk"
    "apt:tr=coreutils" "dnf:tr=coreutils" "brew:tr=coreutils"
    "apt:column=bsdextrautils" "dnf:column=util-linux" "pacman:column=util-linux"
    "dnf:git=git-core" "yum:git=git-core" "apt:git=git" "pacman:git=git"
    "apt:ssh-keyscan=openssh-client" "apt:ssh-keygen=openssh-client"
    "dnf:ssh-keyscan=openssh-clients" "zypper:ssh-keygen=openssh-clients"
    "pacman:ssh-keyscan=openssh" "brew:ssh-keygen=openssh"
    "dnf:curl=curl" "apt:sed=sed" "dnf:grep=grep"
)
_pkg_bad=""
for row in "${_pkg_rows[@]}"; do
    pm="${row%%:*}"; rest="${row#*:}"; bin="${rest%%=*}"; want="${rest#*=}"
    got="$(_wb_prereq_package "${pm}" "${bin}")"
    [[ "${got}" == "${want}" ]] || _pkg_bad="${_pkg_bad} ${pm}:${bin}=${got}(want ${want})"
done
if [[ -z "${_pkg_bad}" ]]; then
    ok "_wb_prereq_package names the expected package for every checked row"
else
    fail "_wb_prereq_package rows wrong:${_pkg_bad}"
fi

# 9. bootstrap.sh's copy of the rows (_pkg_for) agrees with
#    _wb_prereq_package for the six binaries bootstrap checks itself.
_pkg_for_src="$(awk '/^_pkg_for\(\) \{/,/^\}/' "${REPO_ROOT}/bootstrap.sh")"
if [[ -z "${_pkg_for_src}" ]]; then
    fail "bootstrap.sh has no _pkg_for function"
else
    eval "${_pkg_for_src}"
    _pkg_bad=""
    for pm in apt dnf yum zypper pacman brew; do
        for bin in curl tar awk sed tr grep; do
            a="$(_pkg_for "${pm}" "${bin}")"
            b="$(_wb_prereq_package "${pm}" "${bin}")"
            [[ "${a}" == "${b}" ]] || _pkg_bad="${_pkg_bad} ${pm}:${bin}(bootstrap=${a} core=${b})"
        done
    done
    if [[ -z "${_pkg_bad}" ]]; then
        ok "bootstrap.sh's _pkg_for matches _wb_prereq_package for curl/tar/awk/sed/tr/grep"
    else
        fail "bootstrap.sh's _pkg_for and _wb_prereq_package disagree:${_pkg_bad}"
    fi
fi

# 10-14. workbench_ensure_shell_prereqs: detect, report, ask, install,
#    check again. Each case runs in a subshell with the package manager,
#    the terminal and the question stubbed; RAN records whether the
#    package manager was called and with what.
# _ensure_case <yes> <tty:true|false> <answer:y|n> <installs:true|false>
_ensure_case() {
    (
        set +e
        _c_yes="$1" _c_tty="$2" _c_answer="$3" _c_installs="$4"
        RAN="${TMP_XDG}/ran"
        _installed="${TMP_XDG}/installed"
        rm -f "${RAN}" "${_installed}"
        workbench_missing_shell_prereqs() { [[ -e "${_installed}" ]] || echo "column"; }
        detect-package-manager() { PACKAGE_MANAGER="dnf"; }
        _wb_prereq_elevation() { echo "sudo"; }
        _wb_have_tty() { [[ "${_c_tty}" == "true" ]]; }
        _wb_prereq_ask() { [[ "${_c_answer}" == "y" ]]; }
        _wb_prereq_run() {
            echo "$*" > "${RAN}"
            if [[ "${_c_installs}" == "true" ]]; then : > "${_installed}"; fi
            return 0
        }
        workbench_ensure_shell_prereqs "test" "${_c_yes}" >"${TMP_XDG}/ensure.log" 2>&1
        rc=$?
        if [[ -e "${RAN}" ]]; then echo "rc=${rc} ran=$(cat "${RAN}")"; else echo "rc=${rc} ran=no"; fi
    )
}

r="$(_ensure_case false false n true)"
if [[ "${r}" == "rc=1 ran=no" ]] && grep -q "re-run with --yes" "${TMP_XDG}/ensure.log" \
    && grep -q "sudo dnf install -y util-linux" "${TMP_XDG}/ensure.log"; then
    ok "no terminal, no --yes: reports the command, installs nothing, returns 1"
else
    fail "no terminal, no --yes: got '${r}'"; cat "${TMP_XDG}/ensure.log"
fi

r="$(_ensure_case false true n true)"
if [[ "${r}" == "rc=2 ran=no" ]]; then
    ok "answered no: installs nothing, returns 2"
else
    fail "answered no: got '${r}'"; cat "${TMP_XDG}/ensure.log"
fi

r="$(_ensure_case false true y true)"
if [[ "${r}" == "rc=0 ran=dnf util-linux" ]] && grep -q "installed util-linux (for column)" "${TMP_XDG}/ensure.log"; then
    ok "answered yes: installs util-linux via dnf, reports it, returns 0"
else
    fail "answered yes: got '${r}'"; cat "${TMP_XDG}/ensure.log"
fi

r="$(_ensure_case true false n true)"
if [[ "${r}" == "rc=0 ran=dnf util-linux" ]]; then
    ok "--yes without a terminal: installs without asking, returns 0"
else
    fail "--yes without a terminal: got '${r}'"; cat "${TMP_XDG}/ensure.log"
fi

r="$(_ensure_case true false n false)"
if [[ "${r}" == "rc=1 ran=dnf util-linux" ]] && grep -q "still missing after installing" "${TMP_XDG}/ensure.log"; then
    ok "package installed but binary still missing: returns 1 and says so"
else
    fail "binary still missing after install: got '${r}'"; cat "${TMP_XDG}/ensure.log"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
