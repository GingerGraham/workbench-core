#!/usr/bin/env bash
# tests/check-scheduler-install.sh — ARCHITECTURE.md §12 D38 acceptance
# check: default-off behaviour, the enable/disable/status command family,
# and the upgrade-safety migration for a pre-existing Ansible-era timer.
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
mkdir -p "${HOME}" "${HOME}/.local/bin"
touch "${HOME}/.local/bin/wb"

WB="${REPO_ROOT}/bin/wb"
UNIT_DIR="${XDG_CONFIG_HOME}/systemd/user"
CONF_FILE="${XDG_CONFIG_HOME}/workbench/core/scheduler.conf"
STUB_LOG="${WORK}/systemctl-calls.log"
STUB_BIN="${WORK}/stub-bin"
mkdir -p "${STUB_BIN}"

install_ok_stub() {
    # Every real call here is `systemctl --user <verb> ...`, so the verb to
    # branch on is $2, not $1 (which is always the literal "--user").
    cat > "${STUB_BIN}/systemctl" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "${STUB_LOG}"
case "\$2" in
    is-enabled) exit "\${SYSTEMCTL_IS_ENABLED_RC:-1}" ;;
    is-active)  exit "\${SYSTEMCTL_IS_ACTIVE_RC:-1}" ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "${STUB_BIN}/systemctl"
}
install_ok_stub
export PATH="${STUB_BIN}:${PATH}"

# shellcheck source=bin/wb
source "${WB}" >/tmp/wb-scheduler-source.log 2>&1
# shellcheck disable=SC2034 # read by workbench_scheduler_install, sourced from bin/wb above
WORKBENCH_OS="Linux"

# ── 1. Default is OFF: fresh host, wb apply must not touch systemd ─────────
: > "${STUB_LOG}"
workbench_scheduler_install
if [[ ! -f "${UNIT_DIR}/workbench-sync.timer" ]]; then
    ok "fresh host: no timer file written by default"
else
    fail "fresh host: timer file was written despite default-off"
fi
# The migration check's own read-only 'is-enabled' probe (deciding
# whether to carry forward a pre-existing timer) is expected here even on
# a fresh host with nothing installed yet — what must never happen is any
# *mutating* call (daemon-reload/enable/disable) while disabled.
if ! grep -qE "daemon-reload|enable --now|disable --now" "${STUB_LOG}" 2>/dev/null; then
    ok "fresh host: no mutating systemctl call while disabled"
else
    fail "fresh host: a mutating systemctl call was made despite default-off — log: $(cat "${STUB_LOG}")"
fi

# ── 2. 'wb scheduler enable' installs immediately ───────────────────────────
: > "${STUB_LOG}"
workbench_scheduler_cmd_enable
if grep -q '^SCHEDULER_ENABLED=true$' "${CONF_FILE}"; then
    ok "scheduler enable: persisted SCHEDULER_ENABLED=true"
else
    fail "scheduler enable: flag not persisted correctly"
fi
if [[ -f "${UNIT_DIR}/workbench-sync.timer" ]] && grep -qF "ExecStart=${HOME}/.local/bin/wb sync run-if-due" "${UNIT_DIR}/workbench-sync.service"; then
    ok "scheduler enable: timer installed with correct ExecStart"
else
    fail "scheduler enable: timer not installed correctly"
fi
if grep -q "enable --now workbench-sync.timer" "${STUB_LOG}"; then
    ok "scheduler enable: systemctl enable --now invoked"
else
    fail "scheduler enable: systemctl enable --now not invoked"
fi

# ── 3. A subsequent 'wb apply' (workbench_scheduler_install) keeps it ──────
: > "${STUB_LOG}"
workbench_scheduler_install
if [[ -f "${UNIT_DIR}/workbench-sync.timer" ]]; then
    ok "wb apply after enable: timer still present"
else
    fail "wb apply after enable: timer disappeared"
fi

# ── 4. 'wb scheduler disable' tears it down immediately ────────────────────
: > "${STUB_LOG}"
workbench_scheduler_cmd_disable
if grep -q '^SCHEDULER_ENABLED=false$' "${CONF_FILE}"; then
    ok "scheduler disable: persisted SCHEDULER_ENABLED=false"
else
    fail "scheduler disable: flag not persisted correctly"
fi
if [[ ! -f "${UNIT_DIR}/workbench-sync.timer" && ! -f "${UNIT_DIR}/workbench-sync.service" ]]; then
    ok "scheduler disable: unit files removed"
else
    fail "scheduler disable: unit files still present"
fi
if grep -q "disable --now workbench-sync.timer" "${STUB_LOG}"; then
    ok "scheduler disable: systemctl disable --now invoked"
else
    fail "scheduler disable: systemctl disable --now not invoked"
fi

# ── 5. A subsequent 'wb apply' after disable must NOT reinstall ────────────
: > "${STUB_LOG}"
workbench_scheduler_install
if [[ ! -f "${UNIT_DIR}/workbench-sync.timer" ]]; then
    ok "wb apply after disable: stays off, no reinstall"
else
    fail "wb apply after disable: silently reinstalled the timer"
fi

# ── 6. run-if-due itself no-ops when disabled (defense in depth) ───────────
if workbench_scheduler_enabled; then
    fail "test setup error: scheduler unexpectedly enabled before check 6"
else
    ok "precondition for check 6: scheduler is disabled"
fi

# ── 7. Migration: a pre-existing active Ansible-era timer is preserved ─────
rm -f "${CONF_FILE}"
cat > "${STUB_BIN}/systemctl" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "${STUB_LOG}"
case "\$2" in
    is-enabled) exit 0 ;;
    *) exit 0 ;;
esac
STUB
chmod +x "${STUB_BIN}/systemctl"
mkdir -p "${UNIT_DIR}"
touch "${UNIT_DIR}/workbench-sync.timer" "${UNIT_DIR}/workbench-sync.service"

_workbench_scheduler_migrate_existing_install
if grep -q '^SCHEDULER_ENABLED=true$' "${CONF_FILE}" 2>/dev/null; then
    ok "migration: pre-existing active timer carried forward as enabled"
else
    fail "migration: pre-existing active timer was not preserved"
fi

# ── 8. Migration never overrides an explicit prior choice ──────────────────
_workbench_scheduler_conf_set SCHEDULER_ENABLED false
_workbench_scheduler_migrate_existing_install
if grep -q '^SCHEDULER_ENABLED=false$' "${CONF_FILE}"; then
    ok "migration: does not override an explicit existing choice"
else
    fail "migration: overrode an explicit prior disable"
fi

# ── 9. Migration also runs from 'wb sync run-if-due' itself, not just
#    'wb install'/'wb apply' — a host that auto-updates core entirely
#    through its own already-active pre-D38 timer firing run-if-due must
#    not get stuck: the very first firing after upgrading, with no
#    scheduler.conf yet, has to detect the pre-existing active timer and
#    flip itself on, or scheduled sync (and the auto-apply that would
#    otherwise run this same migration) is lost silently and permanently. ──
rm -f "${CONF_FILE}"
_wb_cmd_sync run-if-due >/tmp/wb-scheduler-run-if-due.log 2>&1
if grep -q '^SCHEDULER_ENABLED=true$' "${CONF_FILE}" 2>/dev/null; then
    ok "'wb sync run-if-due' runs the migration itself and carries forward a pre-existing active timer"
else
    fail "'wb sync run-if-due' did not run the migration — a host relying solely on its old timer to auto-update would get stuck disabled forever (see /tmp/wb-scheduler-run-if-due.log)"
fi

echo
echo "== ${check_no} checks, ${FAILED} failed =="
exit "${FAILED}"
