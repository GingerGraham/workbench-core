#!/usr/bin/env bash
# tests/check-core-api-gate.sh — docs/decisions-log.md D91 acceptance check.
#
# The core_api gate runs before the snapshot swap. A module release that
# needs a newer Core API than this host's leaves the module on its current
# release — current symlink, RESOLVED_SHA and register.list untouched —
# records HELD_CORE_API, and is adopted once the host's Core API satisfies
# it. The render-time check (wb apply) refuses without truncating the
# existing list.
#
# 'wb update' and 'wb apply' restate CORE_API_VERSION from the running
# release before anything else (D36/D85), which would overwrite a faked
# value. So this suite fakes the running API in the version file and calls
# the engine directly: workbench_sync_module for a sync, and
# _wb_converge_module_registrations — the step 'wb apply' renders the lists
# with — for the apply case.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
export XDG_CACHE_HOME="${WORK}/cache"
mkdir -p "${HOME}"

WB="${REPO_ROOT}/bin/wb"
# shellcheck source=bin/wb
source "${WB}" >"${WORK}/source.log" 2>&1
_wb_require modules/add.sh
_workbench_ensure_version_file

REAL_API="$(_workbench_core_api_version)"

# fake_api <X.Y> — set the running Core API this process reads.
fake_api() {
    _workbench_version_set_var CORE_API_VERSION "$1"
}

SRC="${WORK}/src-gate"
BARE="${WORK}/gate.git"
mkdir -p "${SRC}"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}" 2>/dev/null

# write_release <core_api> <tag> — commit a release declaring <core_api>.
write_release() {
    local core_api="$1" tag="$2"
    (
        cd "${SRC}" || exit 1
        git config user.email t@t.com
        git config user.name Test
        mkdir -p shell
        printf 'gate-fn() { echo %s; }\n' "${tag}" > shell/gate.sh
        cat > .dotfiles-sync.yml <<EOF
version: 1
branch: main
core_api: "${core_api}"
register:
  shell:
    - src: shell/gate.sh
      tier: tools
EOF
        git add -A && git commit -q -m "${tag}"
        git branch -M main
        git push -q origin main
        git tag "${tag}" && git push -q origin "${tag}"
    )
}

MOD_DIR="${XDG_DATA_HOME}/workbench/modules/gate-mod"
REGLIST="${MOD_DIR}/register.list"

# ── Release 1: supported. ───────────────────────────────────────────────────
write_release ">=1.0 <2.0" v1.0.0
workbench_cmd_add gate-mod "${BARE}" --private >"${WORK}/add.log" 2>&1
# 'wb add' stages; the next sync completes the cycle and renders the lists.
workbench_sync_module gate-mod manual >"${WORK}/sync1.log" 2>&1

if [[ -s "${REGLIST}" ]]; then
    ok "release 1 (core_api >=1.0 <2.0) is adopted and register.list is rendered"
else
    fail "release 1 was not adopted"
    cat "${WORK}/add.log" "${WORK}/sync1.log"
fi

current_before="$(readlink "${MOD_DIR}/current")"
sha_before="$(workbench_module_conf_get gate-mod RESOLVED_SHA "")"
reglist_before="$(cat "${REGLIST}")"

# ── Release 2: needs Core API 9. ────────────────────────────────────────────
write_release ">=9.0 <10.0" v2.0.0

workbench_sync_module gate-mod manual >"${WORK}/sync2.log" 2>&1
sync2_rc=$?

if [[ "${sync2_rc}" -ne 0 ]] && grep -q "needs Core API '>=9.0 <10.0', this host has ${REAL_API}" "${WORK}/sync2.log"; then
    ok "sync of release 2 returns non-zero and logs the 'needs Core API' line"
else
    fail "sync of release 2: rc=${sync2_rc}, or no 'needs Core API' line"
    cat "${WORK}/sync2.log"
fi

if [[ "$(readlink "${MOD_DIR}/current")" == "${current_before}" ]]; then
    ok "the current symlink is unchanged"
else
    fail "the current symlink moved to $(readlink "${MOD_DIR}/current")"
fi

if [[ "$(workbench_module_conf_get gate-mod RESOLVED_SHA "")" == "${sha_before}" ]]; then
    ok "RESOLVED_SHA is unchanged"
else
    fail "RESOLVED_SHA advanced past the refused release"
fi

if [[ -s "${REGLIST}" && "$(cat "${REGLIST}")" == "${reglist_before}" ]]; then
    ok "register.list is unchanged and non-empty"
else
    fail "register.list changed or was emptied"
    cat "${REGLIST}"
fi

if [[ "$(workbench_module_conf_get gate-mod HELD_CORE_API "")" == ">=9.0 <10.0" ]]; then
    ok "HELD_CORE_API records '>=9.0 <10.0'"
else
    fail "HELD_CORE_API is '$(workbench_module_conf_get gate-mod HELD_CORE_API "")'"
fi

STATUS_OUT="$(_wb_cmd_status 2>&1)"
if printf '%s\n' "${STATUS_OUT}" | grep -q "gate-mod held: needs Core API >=9.0 <10.0 — run 'wb update core'"; then
    ok "'wb status' shows the held line"
else
    fail "'wb status' does not show the held line"
    printf '%s\n' "${STATUS_OUT}"
fi

# ── Host core now supports it: the next sync adopts and clears the hold. ────
fake_api 9.0
workbench_sync_module gate-mod manual >"${WORK}/sync3.log" 2>&1
sync3_rc=$?

if [[ "${sync3_rc}" -eq 0 && "$(workbench_module_conf_get gate-mod RESOLVED_SHA "")" != "${sha_before}" ]] \
    && grep -q 'v2.0.0' "${MOD_DIR}/current/shell/gate.sh"; then
    ok "with Core API 9.0 the next sync adopts release 2"
else
    fail "release 2 was not adopted with Core API 9.0 (rc=${sync3_rc})"
    cat "${WORK}/sync3.log"
fi

if [[ -z "$(workbench_module_conf_get gate-mod HELD_CORE_API "")" ]]; then
    ok "adoption clears HELD_CORE_API"
else
    fail "HELD_CORE_API was not cleared on adoption"
fi

# ── wb apply's render with the API back below the floor: no truncation. ─────
reglist_adopted="$(cat "${REGLIST}")"
fake_api "${REAL_API}"
_wb_converge_module_registrations >"${WORK}/apply.log" 2>&1

if [[ -s "${REGLIST}" && "$(cat "${REGLIST}")" == "${reglist_adopted}" ]] \
    && grep -q 'refusing to register its shell content' "${WORK}/apply.log"; then
    ok "the render-time check refuses and leaves register.list as it was (no truncation)"
else
    fail "the render-time refusal emptied or changed register.list"
    cat "${WORK}/apply.log"
    cat "${REGLIST}"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
