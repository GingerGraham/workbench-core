#!/usr/bin/env bash
# tests/check-cadence-dynamic.sh — Phase 5d acceptance check.
#
# ARCHITECTURE.md §9.4/D8: one shared timer, dynamic interval — weekly by
# default, 5 minutes for as long as any registered module (core included) is
# branch:-tracked, reverting once none are. Verifies the interval flips
# without any OS-timer re-registration: workbench_cadence_seconds()
# re-derives the interval fresh on every call from current sync.conf state,
# so a running fixed-interval poller (the actual OS-level timer — see
# ansible/roles/module_sync's timer templates) never itself needs to change.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
export HOME="${WORK}/home"

# shellcheck source=lib/sync/engine.sh
source "${REPO_ROOT}/lib/sync/engine.sh"

setup_module() {
    local name="$1" mode="$2"
    mkdir -p "$(workbench_module_dir "${name}")"
    cat > "$(workbench_module_conf_path "${name}")" <<EOF
TRACK_MODE=${mode}
REGISTERED=true
SYNC_ENABLED=true
EOF
}

# 1. No modules registered at all -> weekly default.
if [[ "$(workbench_cadence_seconds)" -eq "${WORKBENCH_CADENCE_DEFAULT_SECONDS}" ]]; then
    ok "with zero registered modules, cadence defaults to weekly (${WORKBENCH_CADENCE_DEFAULT_SECONDS}s)"
else
    fail "cadence with zero modules should be weekly, got $(workbench_cadence_seconds)"
fi

# 2. core + one other module, both on latest/tag pins -> still weekly.
setup_module core latest
setup_module widgetco "tag:v1.0.0"
if [[ "$(workbench_cadence_seconds)" -eq "${WORKBENCH_CADENCE_DEFAULT_SECONDS}" ]]; then
    ok "with no module on branch: tracking, cadence stays weekly"
else
    fail "cadence should still be weekly with no branch:-tracked module"
fi

# 3. Switch one module to branch: tracking -> interval flips to fast (5 min)
#    IMMEDIATELY, on the very next call — no restart of anything, since the
#    interval is recomputed fresh every time, not cached.
workbench_module_conf_set widgetco TRACK_MODE "branch:dev"
if [[ "$(workbench_cadence_seconds)" -eq "${WORKBENCH_CADENCE_FAST_SECONDS}" ]]; then
    ok "switching widgetco to branch:dev flips cadence to fast (${WORKBENCH_CADENCE_FAST_SECONDS}s) on the next check — no restart needed"
else
    fail "cadence did not flip to fast after a module switched to branch: tracking"
fi

# 4. core itself on branch: tracking also triggers fast cadence — module
#    zero is not special-cased here either.
workbench_module_conf_set widgetco TRACK_MODE "latest"
workbench_module_conf_set core TRACK_MODE "branch:main"
if [[ "$(workbench_cadence_seconds)" -eq "${WORKBENCH_CADENCE_FAST_SECONDS}" ]]; then
    ok "core itself on branch: tracking triggers fast cadence too — no special-casing of module zero"
else
    fail "core on branch: tracking did not trigger fast cadence"
fi

# 5. Reverting the last branch:-tracked module back to latest reverts
#    cadence to weekly.
workbench_module_conf_set core TRACK_MODE "latest"
if [[ "$(workbench_cadence_seconds)" -eq "${WORKBENCH_CADENCE_DEFAULT_SECONDS}" ]]; then
    ok "reverting the last branch:-tracked module back to latest reverts cadence to weekly"
else
    fail "cadence did not revert to weekly after no modules remained branch:-tracked"
fi

# 6. workbench_sync_due()/workbench_cadence_mark_ran(): due immediately on
#    first-ever check (no prior run recorded), not due immediately after a
#    run is marked, due again once the (fast) interval has elapsed.
rm -f "${XDG_DATA_HOME}/workbench/last-cadence-run"
if workbench_sync_due; then
    ok "sync is due when no prior run has ever been recorded"
else
    fail "sync should be due with no prior run recorded"
fi

workbench_cadence_mark_ran
if ! workbench_sync_due; then
    ok "sync is not due immediately after being marked as just run"
else
    fail "sync should not be due immediately after workbench_cadence_mark_ran"
fi

workbench_module_conf_set core TRACK_MODE "branch:main"
# Force the recorded last-run to appear far enough in the past that even
# the FAST interval has elapsed, without an actual sleep.
echo $(( $(date +%s) - WORKBENCH_CADENCE_FAST_SECONDS - 1 )) > "${XDG_DATA_HOME}/workbench/last-cadence-run"
if workbench_sync_due; then
    ok "sync becomes due again once the current (fast) interval has elapsed"
else
    fail "sync should be due once the fast interval elapsed"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
