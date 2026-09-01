#!/usr/bin/env bash
# tests/check-tools-registry.sh — baseline-completion brief §Phase 3
# acceptance check.
#
# `register.installers[].src` was declared/parsed/validated from Wave B
# onward but nothing ever consumed it at runtime — this is the acceptance
# check for the framework that finally does (lib/core/tools.sh,
# workbench_render_installers_list in lib/sync/engine.sh, and `wb tools` in
# bin/wb). Verifies discovery/grouping, that `wb tools update <name>`
# sources+calls the right function exactly once without requiring it
# already be loaded, and the first-by-module-name-order-wins collision
# rule with its one-time warning.
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
MARKER_BETA_TF="${WORK}/beta-terraform-ran"

# ── "alpha-tools": two install-* functions across register.installers[]. ───
SRC_A="${WORK}/src-alpha"
BARE_A="${WORK}/alpha.git"
mkdir -p "${SRC_A}"
git init -q --bare "${BARE_A}"
git clone -q "${BARE_A}" "${SRC_A}" 2>/dev/null
(
    cd "${SRC_A}"
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    cat > shell/installers.sh <<EOF
install-terraform() { echo "\${1:-}" >> "${MARKER_ALPHA_TF}"; }
install-widget()    { echo "\${1:-}" >> "${MARKER_ALPHA_WIDGET}"; }
_install-hidden()   { :; }
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

if grep -q '|install-terraform|terraform$' "${ALPHA_INSTLIST}" 2>/dev/null \
    && grep -q '|install-widget|widget$' "${ALPHA_INSTLIST}" 2>/dev/null; then
    ok "installers.list records both discovered install-* functions with the install- prefix stripped as the friendly name"
else
    fail "installers.list does not contain the expected entries"
    cat "${ALPHA_INSTLIST}" 2>/dev/null
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
    && echo "${LIST_OUT}" | grep -q "widget"; then
    ok "'wb tools list' groups discovered install-* tools under the declaring module's name"
else
    fail "'wb tools list' did not list alpha-tools' installers as expected"
    echo "${LIST_OUT}"
fi

# ── 3. wb tools update <name> sources+calls the right function exactly
#    once, without it already being loaded in the calling shell. ──────────
if command -v install-terraform &>/dev/null; then
    fail "install-terraform is unexpectedly already defined before 'wb tools update' ran"
else
    ok "install-terraform is NOT already loaded in this shell before 'wb tools update terraform' runs"
fi

rm -f "${MARKER_ALPHA_TF}"
_wb_cmd_tools update terraform >/tmp/wb-tools-registry-update1.log 2>&1
if [[ -f "${MARKER_ALPHA_TF}" ]] && [[ "$(wc -l < "${MARKER_ALPHA_TF}")" -eq 1 ]]; then
    ok "'wb tools update terraform' sourced the installer file and called install-terraform exactly once"
else
    fail "'wb tools update terraform' did not call install-terraform exactly once"
    cat /tmp/wb-tools-registry-update1.log
    cat "${MARKER_ALPHA_TF}" 2>/dev/null
fi

if command -v install-terraform &>/dev/null; then
    ok "install-terraform is now defined in this shell, having been sourced by 'wb tools update'"
else
    fail "install-terraform was not actually sourced into the calling shell"
fi

# ── 4. wb tools update with no name runs every discovered installer. ───────
rm -f "${MARKER_ALPHA_TF}" "${MARKER_ALPHA_WIDGET}"
_wb_cmd_tools update >/tmp/wb-tools-registry-update-all.log 2>&1
if [[ -f "${MARKER_ALPHA_TF}" && -f "${MARKER_ALPHA_WIDGET}" ]]; then
    ok "'wb tools update' with no name runs every discovered installer"
else
    fail "'wb tools update' with no name did not run all discovered installers"
    cat /tmp/wb-tools-registry-update-all.log
fi

# ── 5. Collision: a second module also declaring install-terraform. ────────
SRC_B="${WORK}/src-beta"
BARE_B="${WORK}/beta.git"
mkdir -p "${SRC_B}"
git init -q --bare "${BARE_B}"
git clone -q "${BARE_B}" "${SRC_B}" 2>/dev/null
(
    cd "${SRC_B}"
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

COLLISION_COUNT="$(workbench_tools_collect 2>&1 >/dev/null | grep -c "declared by both" || true)"
if [[ "${COLLISION_COUNT}" -eq 1 ]]; then
    ok "the collision is warned about exactly once per aggregation pass"
else
    fail "expected exactly one collision warning, got ${COLLISION_COUNT}"
fi

rm -f "${MARKER_ALPHA_TF}" "${MARKER_BETA_TF}"
_wb_cmd_tools update terraform >/tmp/wb-tools-registry-update-collision.log 2>&1
if [[ -f "${MARKER_ALPHA_TF}" && ! -f "${MARKER_BETA_TF}" ]]; then
    ok "'wb tools update terraform' invokes the winning (alpha-tools) function, not the losing one"
else
    fail "'wb tools update terraform' invoked the wrong function after a collision"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
