#!/usr/bin/env bash
# tests/check-core-handoff.sh — docs/decisions-log.md D85.
#
# When a sync updates core, the rest of that sync runs on the new release:
# the old process execs the new snapshot's 'wb __sync-continue' for the
# modules after core, and core's convergence pass runs the new wb as a
# child, never the old process's own functions. A new release that predates
# '__sync-continue' (a pin back) gets the old in-process behaviour. Every
# sync also restates CORE_API_VERSION (D36) before rendering anything.
#
# Core's fixture snapshot carries a stub bin/wb that records how it was
# called — the real convergence machinery is tests/check-core-auto-apply.sh's.
#
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# shellcheck disable=SC2015
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
CALLS="${WORK}/stub-calls"
export CALLS

set --
# shellcheck source=bin/wb
source "${WB}" >"${WORK}/source.log" 2>&1
_wb_require sync/scheduler.sh
_workbench_scheduler_conf_set SCHEDULER_ENABLED true
_workbench_scheduler_conf_set RELEASE_COOLDOWN_DAYS 0
_workbench_ensure_version_file >/dev/null 2>&1

# In-process convergence, recorded — reached only when there's no new wb
# to hand to.
declare -a APPLY_CALLS=()
_wb_cmd_apply() { APPLY_CALLS+=("$*"); return 0; }

# stub_wb <knows-sync-continue:true|false> — core's bin/wb in the fixture.
stub_wb() {
    mkdir -p bin
    if [[ "$1" == "true" ]]; then
        cat > bin/wb <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${CALLS}"
case "${1:-}" in
    __sync-continue) exit 0 ;;
esac
EOF
    else
        cat > bin/wb <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${CALLS}"
EOF
    fi
    chmod +x bin/wb
}

make_repo() {
    local src="$1" bare="$2" with_wb="$3"
    git init -q --bare "${bare}"
    git clone -q "${bare}" "${src}" 2>/dev/null
    (
        cd "${src}" || exit 1
        git config user.email t@t.com
        git config user.name Test
        echo "v1" > file.sh
        [[ "${with_wb}" == "true" ]] && stub_wb true
        cat > .dotfiles-sync.yml <<EOF
version: 1
branch: main
deploy:
  - src: file.sh
    dest: ~/.local/share/wb-handoff-test/$(basename "${src}").sh
    mode: link
EOF
        git add -A && git commit -q -m v1
        git branch -M main
        git push -q origin main
        git tag v1.0.0 && git push -q origin v1.0.0
    )
}
new_tag() {
    local src="$1" tag="$2" knows="${3:-}"
    (
        cd "${src}" || exit 1
        echo "${tag}" >> file.sh
        [[ -n "${knows}" ]] && stub_wb "${knows}"
        git add -A && git commit -q -m "${tag}"
        git tag "${tag}" && git push -q origin main "${tag}"
    )
}
setup_module() {
    mkdir -p "$(workbench_module_dir "$1")"
    cat > "$(workbench_module_conf_path "$1")" <<EOF
REPO_URL=$2
PRIVATE=true
TRACK_MODE=latest
REGISTERED=true
SYNC_ENABLED=true
ALLOW_HOOKS=false
EOF
}

CORE_SRC="${WORK}/core-src"; WIDGET_SRC="${WORK}/widget-src"
make_repo "${CORE_SRC}" "${WORK}/core.git" true
make_repo "${WIDGET_SRC}" "${WORK}/widget.git" false
setup_module core "${WORK}/core.git"
setup_module widgetco "${WORK}/widget.git"
workbench_sync_module core setup >"${WORK}/setup.log" 2>&1
workbench_sync_module widgetco setup >>"${WORK}/setup.log" 2>&1
sha() { workbench_module_conf_get "$1" RESOLVED_SHA ""; }

# ── 1. Nothing changed in core: no handoff, widgetco synced here. ──────────
: > "${CALLS}"
new_tag "${WIDGET_SRC}" v1.1.0
before_w="$(sha widgetco)"
( _wb_cmd_update "" ) >"${WORK}/1.log" 2>&1
[[ ! -s "${CALLS}" && "$(sha widgetco)" != "${before_w}" ]] \
    && ok "core unchanged: no handoff, the other modules sync in this process" \
    || { fail "core unchanged: calls '$(cat "${CALLS}")'"; cat "${WORK}/1.log"; }

# ── 2. Core changed on 'wb update': the rest goes to the new wb. ───────────
: > "${CALLS}"
before_c="$(sha core)"
before_w="$(sha widgetco)"
new_tag "${CORE_SRC}" v1.1.0
new_tag "${WIDGET_SRC}" v1.2.0
( _wb_cmd_update "" ) >"${WORK}/2.log" 2>&1
[[ "$(cat "${CALLS}")" == "__sync-continue manual ${before_c} widgetco" ]] \
    && ok "core changed: 'wb update' hands the remaining modules to the new release's wb" \
    || { fail "handoff call: '$(cat "${CALLS}")'"; cat "${WORK}/2.log"; }
[[ "$(sha widgetco)" == "${before_w}" ]] \
    && ok "the old process doesn't sync the modules it handed off" \
    || fail "widgetco was synced by the old process"
grep -q "continuing with its new release" "${WORK}/2.log" \
    && ok "the handoff is logged" || fail "no handoff log line"

# ── 3. Same from the timer, with reason scheduled. ─────────────────────────
: > "${CALLS}"
before_c="$(sha core)"
new_tag "${CORE_SRC}" v1.2.0
rm -f "$(_wb_cadence_state_file)"
( _wb_cmd_sync run-if-due ) >"${WORK}/3.log" 2>&1
[[ "$(cat "${CALLS}")" == "__sync-continue scheduled ${before_c} widgetco" ]] \
    && ok "'wb sync run-if-due' hands off with reason scheduled" \
    || { fail "scheduled handoff: '$(cat "${CALLS}")'"; cat "${WORK}/3.log"; }

# ── 4. 'wb update core': convergence runs the new wb, not this process. ───
: > "${CALLS}"; APPLY_CALLS=()
new_tag "${CORE_SRC}" v1.3.0
_wb_cmd_update core >"${WORK}/4.log" 2>&1
[[ "$(cat "${CALLS}")" == "apply" ]] \
    && ok "core's convergence pass runs the new release's 'wb apply'" \
    || { fail "convergence call: '$(cat "${CALLS}")'"; cat "${WORK}/4.log"; }
[[ "${#APPLY_CALLS[@]}" -eq 0 ]] \
    && ok "...and not this process's own apply" || fail "in-process apply ran: ${APPLY_CALLS[*]}"

# ── 5. A new release without '__sync-continue': old behaviour. ─────────────
: > "${CALLS}"; APPLY_CALLS=()
before_w="$(sha widgetco)"
new_tag "${CORE_SRC}" v1.4.0 false
new_tag "${WIDGET_SRC}" v1.3.0
_wb_cmd_update "" >"${WORK}/5.log" 2>&1
[[ ! -s "${CALLS}" && "$(sha widgetco)" != "${before_w}" && "${#APPLY_CALLS[@]}" -eq 1 ]] \
    && ok "a release without '__sync-continue': no handoff, everything synced and converged here" \
    || { fail "pin-back: calls '$(cat "${CALLS}")', apply ${#APPLY_CALLS[@]}"; cat "${WORK}/5.log"; }

# ── 6. __sync-continue itself: syncs what it's given, then converges. ──────
APPLY_CALLS=()
before_w="$(sha widgetco)"
new_tag "${WIDGET_SRC}" v1.4.0
_wb_cmd_sync_continue manual "0000000" widgetco >"${WORK}/6.log" 2>&1
[[ "$(sha widgetco)" != "${before_w}" && "${#APPLY_CALLS[@]}" -eq 1 && "${APPLY_CALLS[0]}" != *"--skip-ansible"* ]] \
    && ok "'wb __sync-continue manual': syncs the given modules, then runs core's convergence" \
    || { fail "__sync-continue: apply ${#APPLY_CALLS[@]} '${APPLY_CALLS[*]-}'"; cat "${WORK}/6.log"; }
APPLY_CALLS=()
_wb_cmd_sync_continue scheduled "0000000" widgetco >"${WORK}/6b.log" 2>&1
[[ "${#APPLY_CALLS[@]}" -eq 1 && "${APPLY_CALLS[0]}" == *"--skip-ansible"* ]] \
    && ok "'wb __sync-continue scheduled' converges unattended (--skip-ansible)" \
    || fail "__sync-continue scheduled: '${APPLY_CALLS[*]-}'"

# ── 7. A sync restates CORE_API_VERSION before rendering anything. ────────
_workbench_version_set_var CORE_API_VERSION 1.0
_wb_cmd_update "" >"${WORK}/7.log" 2>&1
[[ "$(_workbench_core_api_version)" == "${_WB_CORE_API_VERSION_CURRENT}" ]] \
    && ok "'wb update' sets CORE_API_VERSION to what the running code provides" \
    || fail "CORE_API_VERSION is $(_workbench_core_api_version)"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
