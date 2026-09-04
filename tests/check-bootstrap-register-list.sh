#!/usr/bin/env bash
# tests/check-bootstrap-register-list.sh — baseline-completion brief §Phase 1
# acceptance check.
#
# Reproduces the confirmed regression exactly: a `bootstrap.sh`-driven
# install registers core (REGISTERED=true, SYNC_ENABLED=true, a real
# `current` snapshot) WITHOUT ever calling `workbench_render_register_list`
# — that only ever happened inside `_wb_bootstrap_core_module`'s
# non-early-return body, which a bootstrap.sh-driven install never reaches,
# because bootstrap.sh already did the registering itself. Before the fix,
# `bin/wb install` reported full success while `register.list` stayed
# entirely absent and none of core's own shell content ever reached a real
# shell, with no warning anywhere. This test builds that exact precondition
# by hand (rather than re-driving the real bootstrap.sh network path, which
# tests/check-bootstrap.sh already covers) and asserts the fix: register.list
# gets rendered unconditionally, core's functions become callable in a real
# new shell, a second no-op `wb apply` still leaves it correctly populated,
# and `wb status` loudly flags a module whose declared register content
# never made it into register.list.
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
source "${WB}" >/tmp/wb-bootstrap-reglist-source.log 2>&1

MODULE_DIR="${XDG_DATA_HOME}/workbench/modules/core"
REGLIST="${MODULE_DIR}/register.list"

# ── Build the exact bootstrap.sh-driven precondition ────────────────────────
# bootstrap.sh fetches real content into snapshots/<ref-slug>-<shortsha>/ and
# swaps `current` to point at it directly — a symlink straight at this real
# checkout reproduces that shape without a network fetch (the fetch mechanics
# themselves are tests/check-bootstrap.sh's job, not this test's).
mkdir -p "${MODULE_DIR}/snapshots"
SNAPSHOT_DIR="${MODULE_DIR}/snapshots/main-0000000"
ln -s "${REPO_ROOT}" "${SNAPSHOT_DIR}"
workbench_snapshot_swap core "${SNAPSHOT_DIR}"

workbench_module_conf_set core REPO_URL "https://github.com/GingerGraham/workbench-core.git"
workbench_module_conf_set core PRIVATE "false"
workbench_module_conf_set core TRACK_MODE "latest"
workbench_module_conf_set core REGISTERED "true"
workbench_module_conf_set core SYNC_ENABLED "true"
workbench_module_conf_set core ALLOW_HOOKS "false"
workbench_module_conf_set core RESOLVED_SHA "0000000000000000000000000000000000000000"

# ── 1. Precondition matches the real regression: register.list absent ──────
if [[ ! -f "${REGLIST}" ]]; then
    ok "precondition: register.list does not exist yet, matching the real bootstrap.sh-driven regression"
else
    fail "precondition setup is wrong: register.list already exists before 'wb install' ran"
fi

# ── 2. 'wb install' against this precondition renders register.list ────────
INSTALL_OUT="$(_wb_cmd_install 2>&1)"

if [[ -s "${REGLIST}" ]]; then
    ok "'wb install' against a bootstrap.sh-shaped precondition renders a non-empty register.list"
else
    fail "register.list is still missing/empty after 'wb install'"
    echo "${INSTALL_OUT}"
fi

if grep -q "lib/core/functions.sh|core" "${REGLIST}" 2>/dev/null && grep -q "lib/core/version.sh|core" "${REGLIST}" 2>/dev/null; then
    ok "register.list lists core's own register.shell[] entries under the correct tier"
else
    fail "register.list does not list core's declared shell entries as expected"
    cat "${REGLIST}" 2>/dev/null
fi

# ── 3. Core's shell content is actually callable in a brand-new shell ──────
# shellcheck disable=SC2016
FUNCS_OUT="$(env HOME="${HOME}" XDG_DATA_HOME="${XDG_DATA_HOME}" XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
    bash -c '
        source "${XDG_DATA_HOME}/workbench/modules/core/current/lib/loader.sh"
        for f in get-functions sudo-test get-elevation-command dedupe-path; do
            if command -v "${f}" &>/dev/null; then
                echo "DEFINED:${f}"
            else
                echo "MISSING:${f}"
            fi
        done
    ' 2>&1)"

if echo "${FUNCS_OUT}" | grep -q "MISSING:"; then
    fail "one or more of core's registered functions are not callable in a fresh shell after 'wb install'"
    echo "${FUNCS_OUT}"
else
    ok "get-functions, sudo-test, get-elevation-command, and dedupe-path are all callable in a brand-new shell"
fi

# ── 4. A second, no-op 'wb apply' still leaves register.list correctly
#    populated — proving this is no longer tied to "a fetch happened".
#    Deleting register.list by hand between runs (with RESOLVED_SHA
#    unchanged, so the sync engine's own fetch-triggered render path is
#    never reached) isolates the unconditional install/apply convergence
#    step as the only thing that could have regenerated it. ────────────────
rm -f "${REGLIST}"
SHA_BEFORE="$(workbench_module_conf_get core RESOLVED_SHA "")"
_wb_cmd_apply >/tmp/wb-bootstrap-reglist-apply2.log 2>&1
SHA_AFTER="$(workbench_module_conf_get core RESOLVED_SHA "")"

if [[ "${SHA_BEFORE}" == "${SHA_AFTER}" ]]; then
    ok "second 'wb apply' run: no upstream change occurred (RESOLVED_SHA unchanged) — isolates the install/apply convergence path"
else
    fail "test setup issue: RESOLVED_SHA changed on the second apply run unexpectedly"
fi

if [[ -s "${REGLIST}" ]]; then
    ok "register.list is regenerated by a second 'wb apply' even with no upstream change — no longer tied to 'a fetch happened'"
else
    fail "register.list was not regenerated by a no-op 'wb apply'"
    cat /tmp/wb-bootstrap-reglist-apply2.log
fi

# ── 5. 'wb status' loudly flags a module whose declared register content
#    never made it into register.list. ─────────────────────────────────────
SRC="${WORK}/src"
BARE="${WORK}/bare.git"
mkdir -p "${SRC}"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}" 2>/dev/null
(
    cd "${SRC}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    echo 'widget-fn() { :; }' > shell/widget.sh
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/widget.sh
      tier: tools
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)

workbench_cmd_add widget "${BARE}" --private >/tmp/wb-bootstrap-reglist-add.log 2>&1
WIDGET_REGLIST="${XDG_DATA_HOME}/workbench/modules/widget/register.list"

# Simulate the same class of gap for a synthetic module: content is
# registered and synced, but register.list has since gone missing/empty
# through some other path than the ones covered above.
: > "${WIDGET_REGLIST}"

STATUS_OUT="$(_wb_cmd_status 2>&1)"
if echo "${STATUS_OUT}" | grep -q "'widget' declares register.shell\[\]/register.installers\[\] entries but register.list is missing or empty"; then
    ok "'wb status' loudly warns about a registered module whose register.list is missing/empty despite declared register content"
else
    fail "'wb status' did not warn about widget's missing register.list"
    echo "${STATUS_OUT}"
fi

# Re-converging clears the warning.
_wb_cmd_apply >/tmp/wb-bootstrap-reglist-apply3.log 2>&1
STATUS_OUT2="$(_wb_cmd_status 2>&1)"
if echo "${STATUS_OUT2}" | grep -q "'widget' declares register.shell"; then
    fail "'wb status' still warns about widget after 'wb apply' re-converged register.list"
else
    ok "'wb apply' re-converging register.list clears 'wb status'' warning"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
