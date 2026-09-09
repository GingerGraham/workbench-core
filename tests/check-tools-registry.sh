#!/usr/bin/env bash
# tests/check-tools-registry.sh — baseline-completion brief §Phase 3 +
# ARCHITECTURE.md §12 D43 acceptance check.
#
# Verifies discovery/grouping, that 'wb tools install <name>' always
# requires an explicit target, that 'install all' lists+confirms before
# running anything, that 'wb tools upgrade' only ever touches tools an
# installed-<name> predicate reports as installed (skipping
# not-installed silently and unresponsive with a report), the
# first-by-module-name-order-wins collision rule, and the reserved-word
# guard.
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

WB="${REPO_ROOT}/bin/wb"
# shellcheck source=bin/wb
source "${WB}" >/tmp/wb-tools-registry-source.log 2>&1

MARKER_ALPHA_TF="${WORK}/alpha-terraform-ran"
MARKER_ALPHA_WIDGET="${WORK}/alpha-widget-ran"
MARKER_ALPHA_GIZMO="${WORK}/alpha-gizmo-ran"
MARKER_ALPHA_SPROCKET="${WORK}/alpha-sprocket-ran"
MARKER_BETA_TF="${WORK}/beta-terraform-ran"

# ── "alpha-tools": install-* functions, with/without installed-* predicates. ─
# terraform/widget: no predicate at all -> always "unresponsive".
# gizmo: installed-gizmo returns 0     -> "installed".
# sprocket: installed-sprocket returns 1 -> "not-installed".
SRC_A="${WORK}/src-alpha"
BARE_A="${WORK}/alpha.git"
mkdir -p "${SRC_A}"
git init -q --bare "${BARE_A}"
git clone -q "${BARE_A}" "${SRC_A}" 2>/dev/null
(
    cd "${SRC_A}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    cat > shell/installers.sh <<EOF
install-terraform() { echo "\${1:-}" >> "${MARKER_ALPHA_TF}"; }
install-widget()    { echo "\${1:-}" >> "${MARKER_ALPHA_WIDGET}"; }
_install-hidden()   { :; }
install-gizmo()     { echo "\${1:-}" >> "${MARKER_ALPHA_GIZMO}"; }
installed-gizmo()   { return 0; }
install-sprocket()  { echo "\${1:-}" >> "${MARKER_ALPHA_SPROCKET}"; }
installed-sprocket() { return 1; }
EOF
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  installers:
    - src: shell/installers.sh
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)

workbench_cmd_add alpha-tools "${BARE_A}" --private >/tmp/wb-tools-registry-add-alpha.log 2>&1

# ── 1. installers.list was actually rendered for alpha-tools. ──────────────
ALPHA_INSTLIST="${XDG_DATA_HOME}/workbench/modules/alpha-tools/installers.list"
if [[ -s "${ALPHA_INSTLIST}" ]]; then
    ok "installers.list is rendered (non-empty) for a module declaring register.installers[]"
else
    fail "installers.list was not rendered for alpha-tools"
    cat /tmp/wb-tools-registry-add-alpha.log
fi

if grep -q '_install-hidden' "${ALPHA_INSTLIST}" 2>/dev/null; then
    fail "an underscore-prefixed helper function was incorrectly discovered as an installer"
else
    ok "an underscore-prefixed helper function is correctly excluded from discovery"
fi

# ── 2. wb tools list groups discovered installers by owning module. ────────
LIST_OUT="$(_wb_cmd_tools_list 2>&1)"
if echo "${LIST_OUT}" | grep -q "alpha-tools:" \
    && echo "${LIST_OUT}" | grep -q "terraform" \
    && echo "${LIST_OUT}" | grep -q "gizmo"; then
    ok "'wb tools list' groups discovered install-* tools under the declaring module's name"
else
    fail "'wb tools list' did not list alpha-tools' installers as expected"
    echo "${LIST_OUT}"
fi

# ── 3. wb tools install with NO target is a usage error — nothing runs. ────
rm -f "${MARKER_ALPHA_TF}" "${MARKER_ALPHA_WIDGET}" "${MARKER_ALPHA_GIZMO}" "${MARKER_ALPHA_SPROCKET}"
if _wb_cmd_tools install >/tmp/wb-tools-registry-bare-install.log 2>&1; then
    fail "'wb tools install' with no target unexpectedly succeeded"
else
    ok "'wb tools install' with no target is a usage error (non-zero exit)"
fi
if [[ -f "${MARKER_ALPHA_TF}" || -f "${MARKER_ALPHA_WIDGET}" || -f "${MARKER_ALPHA_GIZMO}" || -f "${MARKER_ALPHA_SPROCKET}" ]]; then
    fail "'wb tools install' with no target ran something anyway"
else
    ok "'wb tools install' with no target ran nothing"
fi

# ── 4. wb tools install <name> sources+calls the right function exactly
#    once, without it already being loaded in the calling shell. ──────────
if command -v install-terraform &>/dev/null; then
    fail "install-terraform is unexpectedly already defined before 'wb tools install' ran"
else
    ok "install-terraform is NOT already loaded in this shell before 'wb tools install terraform' runs"
fi

rm -f "${MARKER_ALPHA_TF}"
_wb_cmd_tools install terraform >/tmp/wb-tools-registry-install1.log 2>&1
if [[ -f "${MARKER_ALPHA_TF}" ]] && [[ "$(wc -l < "${MARKER_ALPHA_TF}")" -eq 1 ]]; then
    ok "'wb tools install terraform' sourced the installer file and called install-terraform exactly once"
else
    fail "'wb tools install terraform' did not call install-terraform exactly once"
    cat /tmp/wb-tools-registry-install1.log
fi

if grep -q "wb tools install:" /tmp/wb-tools-registry-install1.log; then
    ok "'wb tools install' log lines say 'wb tools install:'"
else
    fail "'wb tools install' log lines did not echo the 'install' verb"
    cat /tmp/wb-tools-registry-install1.log
fi

# ── 5. wb tools install all: declines with 'n' runs nothing; confirms with
#    'y' runs every discovered installer. ──────────────────────────────────
rm -f "${MARKER_ALPHA_TF}" "${MARKER_ALPHA_WIDGET}" "${MARKER_ALPHA_GIZMO}" "${MARKER_ALPHA_SPROCKET}"
_wb_cmd_tools install all <<< "n" >/tmp/wb-tools-registry-install-all-no.log 2>&1
if [[ ! -f "${MARKER_ALPHA_TF}" && ! -f "${MARKER_ALPHA_WIDGET}" && ! -f "${MARKER_ALPHA_GIZMO}" && ! -f "${MARKER_ALPHA_SPROCKET}" ]]; then
    ok "'wb tools install all' answered 'n' ran nothing"
else
    fail "'wb tools install all' answered 'n' ran something anyway"
    cat /tmp/wb-tools-registry-install-all-no.log
fi

_wb_cmd_tools install all </dev/null >/tmp/wb-tools-registry-install-all-eof.log 2>&1
if [[ ! -f "${MARKER_ALPHA_TF}" && ! -f "${MARKER_ALPHA_WIDGET}" ]]; then
    ok "'wb tools install all' with no input (EOF) aborts and runs nothing"
else
    fail "'wb tools install all' with no input ran something anyway"
fi

_wb_cmd_tools install all <<< "y" >/tmp/wb-tools-registry-install-all-yes.log 2>&1
if [[ -f "${MARKER_ALPHA_TF}" && -f "${MARKER_ALPHA_WIDGET}" && -f "${MARKER_ALPHA_GIZMO}" && -f "${MARKER_ALPHA_SPROCKET}" ]]; then
    ok "'wb tools install all' answered 'y' ran every discovered installer"
else
    fail "'wb tools install all' answered 'y' did not run every discovered installer"
    cat /tmp/wb-tools-registry-install-all-yes.log
fi

# ── 6. wb tools upgrade: only touches tools an installed-<name> predicate
#    reports as installed. not-installed is silent; unresponsive is
#    reported and never run. ────────────────────────────────────────────
rm -f "${MARKER_ALPHA_TF}" "${MARKER_ALPHA_WIDGET}" "${MARKER_ALPHA_GIZMO}" "${MARKER_ALPHA_SPROCKET}"
UPGRADE_OUT="$(_wb_cmd_tools upgrade 2>&1)"

if [[ -f "${MARKER_ALPHA_GIZMO}" ]]; then
    ok "'wb tools upgrade' (bare) ran install-gizmo (installed-gizmo reports installed)"
else
    fail "'wb tools upgrade' (bare) did not run install-gizmo"
    echo "${UPGRADE_OUT}"
fi

if [[ -f "${MARKER_ALPHA_SPROCKET}" ]]; then
    fail "'wb tools upgrade' (bare) ran install-sprocket even though installed-sprocket reports not-installed"
else
    ok "'wb tools upgrade' (bare) skipped sprocket (reported not-installed)"
fi

if [[ -f "${MARKER_ALPHA_TF}" || -f "${MARKER_ALPHA_WIDGET}" ]]; then
    fail "'wb tools upgrade' (bare) ran a tool with no installed-<name> predicate at all"
else
    ok "'wb tools upgrade' (bare) skipped tools with no installed-<name> predicate (unresponsive)"
fi

if echo "${UPGRADE_OUT}" | grep -qi "unresponsive"; then
    ok "'wb tools upgrade' (bare) reports unresponsive tools in its summary"
else
    fail "'wb tools upgrade' (bare) did not report any unresponsive tools"
    echo "${UPGRADE_OUT}"
fi

# ── 7. wb tools upgrade <name>: targeted, same three-way check, always a
#    no-op (not an error) for not-installed/unresponsive. ─────────────────
rm -f "${MARKER_ALPHA_GIZMO}"
if _wb_cmd_tools upgrade gizmo >/tmp/wb-tools-registry-upgrade-gizmo.log 2>&1 && [[ -f "${MARKER_ALPHA_GIZMO}" ]]; then
    ok "'wb tools upgrade gizmo' (targeted, installed) ran install-gizmo"
else
    fail "'wb tools upgrade gizmo' did not run install-gizmo"
    cat /tmp/wb-tools-registry-upgrade-gizmo.log
fi

rm -f "${MARKER_ALPHA_SPROCKET}"
if _wb_cmd_tools upgrade sprocket >/tmp/wb-tools-registry-upgrade-sprocket.log 2>&1; then
    if [[ ! -f "${MARKER_ALPHA_SPROCKET}" ]]; then
        ok "'wb tools upgrade sprocket' (targeted, not-installed) is a no-op, not an error"
    else
        fail "'wb tools upgrade sprocket' ran install-sprocket despite not-installed status"
    fi
else
    fail "'wb tools upgrade sprocket' (targeted, not-installed) returned non-zero — should be a clean no-op"
fi

if _wb_cmd_tools upgrade terraform >/tmp/wb-tools-registry-upgrade-terraform.log 2>&1; then
    if [[ ! -f "${MARKER_ALPHA_TF}" ]] || [[ "$(wc -l < "${MARKER_ALPHA_TF}" 2>/dev/null || echo 0)" -eq 0 ]]; then
        ok "'wb tools upgrade terraform' (targeted, unresponsive — no predicate) is a no-op, not an error"
    else
        fail "'wb tools upgrade terraform' ran install-terraform despite having no installed-<name> predicate"
    fi
else
    fail "'wb tools upgrade terraform' (targeted, unresponsive) returned non-zero — should be a clean no-op"
fi

# ── 8. wb tools list --status shows the three-way status per tool. ─────────
# Anchored on end-of-line with a required leading space, not a bare
# substring match — "installed-gizmo" (the function-name column) and
# "not-installed" (a real status value) both contain "installed" as a
# substring, so a plain `grep "installed"` would false-positive on every
# row regardless of actual status.
STATUS_OUT="$(_wb_cmd_tools_list --status 2>&1)"
if echo "${STATUS_OUT}" | grep "gizmo" | grep -qE '[[:space:]]installed$'; then
    ok "'wb tools list --status' shows gizmo as installed"
else
    fail "'wb tools list --status' did not show gizmo as installed"
    echo "${STATUS_OUT}"
fi
if echo "${STATUS_OUT}" | grep "sprocket" | grep -qE 'not-installed$'; then
    ok "'wb tools list --status' shows sprocket as not-installed"
else
    fail "'wb tools list --status' did not show sprocket as not-installed"
    echo "${STATUS_OUT}"
fi
if echo "${STATUS_OUT}" | grep "terraform" | grep -qE 'unresponsive$'; then
    ok "'wb tools list --status' shows terraform (no predicate) as unresponsive"
else
    fail "'wb tools list --status' did not show terraform as unresponsive"
    echo "${STATUS_OUT}"
fi

# ── 9. Collision: a second module also declaring install-terraform. ────────
SRC_B="${WORK}/src-beta"
BARE_B="${WORK}/beta.git"
mkdir -p "${SRC_B}"
git init -q --bare "${BARE_B}"
git clone -q "${BARE_B}" "${SRC_B}" 2>/dev/null
(
    cd "${SRC_B}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    cat > shell/installers.sh <<EOF
install-terraform() { echo "\${1:-}" >> "${MARKER_BETA_TF}"; }
EOF
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  installers:
    - src: shell/installers.sh
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)

# "beta-tools" sorts after "alpha-tools" alphabetically — alpha-tools must
# win the collision (first-by-module-name-order).
workbench_cmd_add beta-tools "${BARE_B}" --private >/tmp/wb-tools-registry-add-beta.log 2>&1

COLLECT_ERR="$(workbench_tools_collect 2>&1 >/dev/null)"
if echo "${COLLECT_ERR}" | grep -qi "declared by both.*alpha-tools.*beta-tools"; then
    ok "a friendly-name collision between two modules is warned about, naming both modules"
else
    fail "no collision warning was produced for the duplicate 'terraform' friendly name"
    echo "${COLLECT_ERR}"
fi

WINNER="$(workbench_tools_lookup terraform)"
if [[ "${WINNER}" == alpha-tools\|* ]]; then
    ok "the collision resolves deterministically to alpha-tools (first by module-name order)"
else
    fail "the collision did not resolve to the expected winner: ${WINNER}"
fi

rm -f "${MARKER_ALPHA_TF}" "${MARKER_BETA_TF}"
_wb_cmd_tools install terraform >/tmp/wb-tools-registry-install-collision.log 2>&1
if [[ -f "${MARKER_ALPHA_TF}" && ! -f "${MARKER_BETA_TF}" ]]; then
    ok "'wb tools install terraform' invokes the winning (alpha-tools) function, not the losing one"
else
    fail "'wb tools install terraform' invoked the wrong function after a collision"
fi

# ── 10. Reserved words: a module declaring install-all is warned about and
#     excluded from discovery entirely. ────────────────────────────────────
SRC_G="${WORK}/src-gamma"
BARE_G="${WORK}/gamma.git"
mkdir -p "${SRC_G}"
git init -q --bare "${BARE_G}"
git clone -q "${BARE_G}" "${SRC_G}" 2>/dev/null
(
    cd "${SRC_G}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    cat > shell/installers.sh <<'EOF'
install-all() { :; }
EOF
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  installers:
    - src: shell/installers.sh
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)
workbench_cmd_add gamma-tools "${BARE_G}" --private >/tmp/wb-tools-registry-add-gamma.log 2>&1

RESERVED_ERR="$(workbench_tools_collect 2>&1 >/dev/null)"
if echo "${RESERVED_ERR}" | grep -qi "reserved wb tools word"; then
    ok "'install-all' is warned about as a reserved word"
else
    fail "no reserved-word warning was produced for 'install-all'"
    echo "${RESERVED_ERR}"
fi

if workbench_tools_collect 2>/dev/null | grep -q '^gamma-tools|.*|install-all|all$'; then
    fail "'install-all' was discoverable despite being a reserved word"
else
    ok "'install-all' is excluded from the discovered registry"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
