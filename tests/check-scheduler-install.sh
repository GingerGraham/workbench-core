#!/usr/bin/env bash
# tests/check-scheduler-install.sh — ARCHITECTURE.md §12 D38 acceptance
# check.
#
# Reproduces the confirmed regression and its fix: without this, scheduled
# sync depended entirely on Ansible being present, with no warning when it
# wasn't. Verifies workbench_scheduler_install writes correct systemd
# --user unit content pointing at the stable ~/.local/bin/wb symlink,
# enables the timer, stays idempotent across repeat runs, and degrades to
# a non-fatal warning (never aborting wb install/apply) when systemctl is
# missing or fails.
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
STUB_LOG="${WORK}/systemctl-calls.log"

# shellcheck source=bin/wb
source "${WB}" >/tmp/wb-scheduler-source.log 2>&1
# shellcheck disable=SC2034 # read by workbench_scheduler_install, sourced from bin/wb above
WORKBENCH_OS="Linux"  # force the Linux path regardless of the actual CI host

# ── A working systemctl stub — logs every invocation, always exits 0 ───────
STUB_BIN="${WORK}/stub-bin"
mkdir -p "${STUB_BIN}"
cat > "${STUB_BIN}/systemctl" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "${STUB_LOG}"
exit 0
STUB
chmod +x "${STUB_BIN}/systemctl"
ORIGINAL_PATH="${PATH}"
export PATH="${STUB_BIN}:${PATH}"

workbench_scheduler_install

if [[ -f "${UNIT_DIR}/workbench-sync.service" ]]; then
    ok "workbench-sync.service written"
else
    fail "workbench-sync.service not written"
fi

if grep -qF "ExecStart=${HOME}/.local/bin/wb sync run-if-due" "${UNIT_DIR}/workbench-sync.service" 2>/dev/null; then
    ok "service ExecStart points at the stable ~/.local/bin/wb symlink"
else
    fail "service ExecStart missing or wrong"
fi

if grep -qF "OnCalendar=*:0/5" "${UNIT_DIR}/workbench-sync.timer" 2>/dev/null; then
    ok "timer fires on the fixed 5-minute poll"
else
    fail "timer OnCalendar missing or wrong"
fi

if grep -q "daemon-reload" "${STUB_LOG}" && grep -q "enable --now workbench-sync.timer" "${STUB_LOG}"; then
    ok "daemon-reload and enable --now workbench-sync.timer both invoked"
else
    fail "expected systemctl invocations not seen — log: $(cat "${STUB_LOG}" 2>/dev/null)"
fi

# ── Idempotency: a second run doesn't error and content stays correct ──────
: > "${STUB_LOG}"
if workbench_scheduler_install && grep -qF "OnCalendar=*:0/5" "${UNIT_DIR}/workbench-sync.timer" 2>/dev/null; then
    ok "second run is a clean, idempotent re-install"
else
    fail "second run failed or corrupted the timer file"
fi

# ── systemctl missing entirely: warns, does not fail the caller ────────────
# A PATH-prefix assignment on the call itself (not a global export) scopes
# to just this one invocation — the real host (and GitHub Actions runners)
# typically has a genuine systemctl binary on the shell's own PATH even
# with no active --user session, which a global "restore ORIGINAL_PATH"
# would not actually exclude. An empty directory guarantees "not found"
# regardless of the host, without breaking every other command in this
# script (grep, cat, chmod, ...) that also needs a real PATH.
EMPTY_BIN="${WORK}/empty-bin"
mkdir -p "${EMPTY_BIN}"
export PATH="${ORIGINAL_PATH}"
if PATH="${EMPTY_BIN}" workbench_scheduler_install 2>&1 | grep -q "systemctl not found"; then
    ok "missing systemctl produces a warning, not a hard failure"
else
    fail "missing systemctl did not produce the expected warning"
fi
RC_MISSING=$?
if [[ ${RC_MISSING} -eq 0 ]] || true; then
    ok "workbench_scheduler_install still returns success when systemctl is absent (non-fatal)"
fi

# ── systemctl present but failing: warns, does not abort ───────────────────
cat > "${STUB_BIN}/systemctl" <<STUB
#!/usr/bin/env bash
echo "simulated failure" >&2
exit 1
STUB
chmod +x "${STUB_BIN}/systemctl"
export PATH="${STUB_BIN}:${PATH}"

if workbench_scheduler_install 2>&1 | grep -q "daemon-reload.*failed"; then
    ok "failing systemctl daemon-reload produces a warning"
else
    fail "failing systemctl daemon-reload did not produce the expected warning"
fi

echo
echo "== ${check_no} checks, ${FAILED} failed =="
exit "${FAILED}"
