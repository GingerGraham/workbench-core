#!/usr/bin/env bash
# tests/check-wb-dev-flow.sh — Phase 7 acceptance check.
#
# `wb dev` (no argument) walks every registered module, prompting
# keep-or-switch, and only changes the one(s) actually selected — the rest
# are left exactly as they were. `wb dev <name>` jumps straight to one
# module without touching any other.
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
mkdir -p "${HOME}"

# shellcheck source=lib/sync/engine.sh
source "${REPO_ROOT}/lib/sync/engine.sh"
# shellcheck source=lib/modules/track.sh
source "${REPO_ROOT}/lib/modules/track.sh"
# shellcheck source=lib/modules/dev.sh
source "${REPO_ROOT}/lib/modules/dev.sh"

# workbench_sync_module is called by workbench_cmd_track when a module's
# tracking changes — stub it out here so this test exercises wb dev's own
# prompting/selection logic in isolation, without needing real repos for
# three synthetic modules.
workbench_sync_module() { return 0; }

setup_module() {
    local name="$1" mode="$2"
    mkdir -p "$(workbench_module_dir "${name}")"
    cat > "$(workbench_module_conf_path "${name}")" <<EOF
TRACK_MODE=${mode}
REGISTERED=true
SYNC_ENABLED=true
EOF
}
setup_module core latest
setup_module widget-a latest
setup_module widget-b "tag:v1.0.0"

# ── 1. `wb dev` (no argument) walks all three, switching only the one
#    answered with 'b'ranch — a 3-line stdin script: keep core, switch
#    widget-a to a branch, keep widget-b. ──────────────────────────────────
printf 'k\nb\nmy-feature\nk\n' | workbench_cmd_dev >/tmp/wb-dev-1.log 2>&1

mode_core="$(workbench_module_conf_get core TRACK_MODE latest)"
mode_a="$(workbench_module_conf_get widget-a TRACK_MODE latest)"
mode_b="$(workbench_module_conf_get widget-b TRACK_MODE latest)"

[[ "${mode_core}" == "latest" ]] && ok "core: left unchanged (answered keep)" || fail "core: unexpectedly changed to ${mode_core}"
[[ "${mode_a}" == "branch:my-feature" ]] && ok "widget-a: switched to branch:my-feature as selected" || fail "widget-a: expected branch:my-feature, got ${mode_a}"
[[ "${mode_b}" == "tag:v1.0.0" ]] && ok "widget-b: left unchanged (answered keep)" || fail "widget-b: unexpectedly changed to ${mode_b}"

sync_enabled_a="$(workbench_module_conf_get widget-a SYNC_ENABLED true)"
[[ "${sync_enabled_a}" == "true" ]] && ok "widget-a: sync.enabled ensured true after switching into branch: tracking" || fail "widget-a: sync.enabled not ensured true"

# ── 2. `wb dev <name>` targets exactly one module, others untouched even
#    if a walk-all was never run this time. ────────────────────────────────
setup_module widget-c latest
printf 't\nv2.0.0\n' | workbench_cmd_dev widget-c >/tmp/wb-dev-2.log 2>&1
mode_c="$(workbench_module_conf_get widget-c TRACK_MODE latest)"
[[ "${mode_c}" == "tag:v2.0.0" ]] && ok "wb dev <name>: targeted module switched to tag:v2.0.0" || fail "wb dev <name> did not switch widget-c correctly: ${mode_c}"

mode_a_after="$(workbench_module_conf_get widget-a TRACK_MODE latest)"
[[ "${mode_a_after}" == "branch:my-feature" ]] && ok "wb dev <name>: an unrelated module (widget-a) was left untouched" || fail "wb dev <name> touched an unrelated module"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
