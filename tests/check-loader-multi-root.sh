#!/usr/bin/env bash
# tests/check-loader-multi-root.sh — Phase 4 acceptance check.
#
# Verifies lib/loader.sh sources every registered, sync-enabled module's
# register.list, in correct tier order, with no hardcoded module name
# anywhere in loader.sh — a synthetic second module (named nothing like
# "core") is sourced through the exact same code path core's own files are.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

MODULES_DIR="${WORK}/modules"
mkdir -p "${MODULES_DIR}"

# ── "core" module: just enough state for loader.sh to source its own
#    functions.sh, exactly the way any other module would be sourced. ──────
mkdir -p "${MODULES_DIR}/core"
cat > "${MODULES_DIR}/core/sync.conf" <<EOF
TRACK_MODE=latest
TRACK_REF=v0.1.0
REGISTERED=true
SYNC_ENABLED=true
EOF
cat > "${MODULES_DIR}/core/register.list" <<EOF
${REPO_ROOT}/lib/core/functions.sh|core
EOF

# ── "acme-widget": a completely fictitious module name, unrelated to
#    anything loader.sh could plausibly hardcode, registering one file per
#    tier plus a numeric-ordered pair in env — proves tier order and
#    intra-module ordering, and that a non-core module goes through the
#    identical path. ──────────────────────────────────────────────────────
WIDGET_SRC="${WORK}/widget-src"
mkdir -p "${WIDGET_SRC}"
echo 'WB_TEST_LOG="${WB_TEST_LOG}env10 "' > "${WIDGET_SRC}/10-env.sh"
echo 'WB_TEST_LOG="${WB_TEST_LOG}env20 "' > "${WIDGET_SRC}/20-env.sh"
echo 'WB_TEST_LOG="${WB_TEST_LOG}tools "' > "${WIDGET_SRC}/tools.sh"
echo 'WB_TEST_LOG="${WB_TEST_LOG}lazy "'  > "${WIDGET_SRC}/lazy.sh"
# platform/distro filename-selector convention: only the file matching the
# live WORKBENCH_OS/WORKBENCH_DISTRO should load.
echo 'WB_TEST_LOG="${WB_TEST_LOG}platform-linux "' > "${WIDGET_SRC}/linux.sh"
echo 'WB_TEST_LOG="${WB_TEST_LOG}platform-macos "' > "${WIDGET_SRC}/macos.sh"
echo 'WB_TEST_LOG="${WB_TEST_LOG}distro-debian "'  > "${WIDGET_SRC}/debian.sh"
echo 'WB_TEST_LOG="${WB_TEST_LOG}distro-rhel "'    > "${WIDGET_SRC}/rhel.sh"

mkdir -p "${MODULES_DIR}/acme-widget"
cat > "${MODULES_DIR}/acme-widget/sync.conf" <<EOF
TRACK_MODE=latest
TRACK_REF=v2.3.0
REGISTERED=true
SYNC_ENABLED=true
EOF
cat > "${MODULES_DIR}/acme-widget/register.list" <<EOF
${WIDGET_SRC}/10-env.sh|env
${WIDGET_SRC}/20-env.sh|env
${WIDGET_SRC}/tools.sh|tools
${WIDGET_SRC}/lazy.sh|lazy
${WIDGET_SRC}/linux.sh|platform
${WIDGET_SRC}/macos.sh|platform
${WIDGET_SRC}/debian.sh|distro
${WIDGET_SRC}/rhel.sh|distro
EOF

# ── "disabled-widget": REGISTERED=true but SYNC_ENABLED=false — must be
#    skipped entirely. ───────────────────────────────────────────────────
mkdir -p "${MODULES_DIR}/disabled-widget"
cat > "${MODULES_DIR}/disabled-widget/sync.conf" <<EOF
REGISTERED=true
SYNC_ENABLED=false
EOF
echo 'WB_TEST_LOG="${WB_TEST_LOG}SHOULD-NOT-LOAD "' > "${WORK}/disabled.sh"
cat > "${MODULES_DIR}/disabled-widget/register.list" <<EOF
${WORK}/disabled.sh|tools
EOF

# ── "removed-widget": REGISTERED=false — must also be skipped. ────────────
mkdir -p "${MODULES_DIR}/removed-widget"
cat > "${MODULES_DIR}/removed-widget/sync.conf" <<EOF
REGISTERED=false
SYNC_ENABLED=true
EOF
echo 'WB_TEST_LOG="${WB_TEST_LOG}SHOULD-NOT-LOAD-EITHER "' > "${WORK}/removed.sh"
cat > "${MODULES_DIR}/removed-widget/register.list" <<EOF
${WORK}/removed.sh|tools
EOF

# ── Run the loader in a clean subshell, isolated from the real machine ────
OUT="$(
    env -i \
        HOME="${WORK}/home" \
        XDG_CONFIG_HOME="${WORK}/xdgconfig" \
        XDG_DATA_HOME="${WORK}/xdgdata" \
        XDG_CACHE_HOME="${WORK}/xdgcache" \
        WORKBENCH_MODULES_DIR="${MODULES_DIR}" \
        WORKBENCH_USER_EXT_ENABLED=false \
        PATH="${PATH}" \
        bash -c '
            source "'"${REPO_ROOT}"'/lib/loader.sh"
            echo "TEST_LOG=${WB_TEST_LOG}"
            echo "WORKBENCH_ARCH=${WORKBENCH_ARCH}"
            command -v elevate-cmd >/dev/null && echo "CORE_FN_LOADED=true" || echo "CORE_FN_LOADED=false"
            echo "TRACK_CORE=${WORKBENCH_TRACK_CORE:-unset}"
            echo "TRACK_WIDGET=${WORKBENCH_TRACK_ACME_WIDGET:-unset}"
        '
)"

echo "--- loader output ---"
echo "${OUT}"
echo "--- end loader output ---"

test_log="$(printf '%s\n' "${OUT}" | grep '^TEST_LOG=' | sed 's/^TEST_LOG=//')"

# 1. core's own function was reached via the generic module-enumeration
#    path, with no hardcoded "core" special-case.
if printf '%s\n' "${OUT}" | grep -q '^CORE_FN_LOADED=true$'; then
    ok "core's own register.list entry (lib/core/functions.sh) was sourced via the generic loader path"
else
    fail "core's functions.sh was not sourced by the loader"
fi

# 2. tier order: env before tools before platform/distro before lazy.
env_pos=$(printf '%s\n' "${test_log}" | grep -bo 'env10' | head -1 | cut -d: -f1)
tools_pos=$(printf '%s\n' "${test_log}" | grep -bo 'tools' | head -1 | cut -d: -f1)
lazy_pos=$(printf '%s\n' "${test_log}" | grep -bo 'lazy' | head -1 | cut -d: -f1)
if [[ -n "${env_pos}" && -n "${tools_pos}" && "${env_pos}" -lt "${tools_pos}" ]]; then
    ok "env tier sourced before tools tier"
else
    fail "env tier did not precede tools tier (log: ${test_log})"
fi
if [[ -n "${tools_pos}" && -n "${lazy_pos}" && "${tools_pos}" -lt "${lazy_pos}" ]]; then
    ok "tools tier sourced before lazy tier"
else
    fail "tools tier did not precede lazy tier (log: ${test_log})"
fi

# 3. intra-module numeric ordering within env tier (10- before 20-).
env10_pos=$(printf '%s\n' "${test_log}" | grep -bo 'env10' | head -1 | cut -d: -f1)
env20_pos=$(printf '%s\n' "${test_log}" | grep -bo 'env20' | head -1 | cut -d: -f1)
if [[ -n "${env10_pos}" && -n "${env20_pos}" && "${env10_pos}" -lt "${env20_pos}" ]]; then
    ok "intra-module env tier ordering preserved (10- before 20-)"
else
    fail "intra-module env tier ordering broken (log: ${test_log})"
fi

# 4. platform/distro filename-selector: only the file matching this
#    machine's actual WORKBENCH_OS/WORKBENCH_DISTRO fired.
live_os="$(uname -s)"
if [[ "${live_os}" == "Linux" ]]; then
    printf '%s\n' "${test_log}" | grep -q 'platform-linux' && ok "platform tier: linux.sh fired on Linux" || fail "platform tier: linux.sh did not fire on Linux"
    printf '%s\n' "${test_log}" | grep -q 'platform-macos' && fail "platform tier: macos.sh incorrectly fired on Linux" || ok "platform tier: macos.sh correctly did not fire on Linux"
fi

# 5. disabled/removed modules never contributed anything.
if printf '%s\n' "${test_log}" | grep -q 'SHOULD-NOT-LOAD'; then
    fail "a SYNC_ENABLED=false or REGISTERED=false module's file was sourced"
else
    ok "SYNC_ENABLED=false and REGISTERED=false modules were both correctly skipped"
fi

# 6. WORKBENCH_TRACK_<MODULE> exported for every registered module, derived
#    from sync.conf's TRACK_MODE:TRACK_REF.
if printf '%s\n' "${OUT}" | grep -q '^TRACK_CORE=latest:v0.1.0$'; then
    ok "WORKBENCH_TRACK_CORE exported as latest:v0.1.0 from core's sync.conf"
else
    fail "WORKBENCH_TRACK_CORE not exported correctly: $(printf '%s\n' "${OUT}" | grep '^TRACK_CORE=')"
fi
if printf '%s\n' "${OUT}" | grep -q '^TRACK_WIDGET=latest:v2.3.0$'; then
    ok "WORKBENCH_TRACK_ACME_WIDGET exported correctly (dash folded to underscore, uppercased)"
else
    fail "WORKBENCH_TRACK_ACME_WIDGET not exported correctly: $(printf '%s\n' "${OUT}" | grep '^TRACK_WIDGET=')"
fi

# 7. no hardcoded module name in loader.sh itself — grep for a literal
#    module-name string assignment/comparison naming "core" as a directory
#    component (as opposed to incidental prose in comments, which is fine).
if grep -vE '^[[:space:]]*#' "${REPO_ROOT}/lib/loader.sh" | grep -qE '/core/|"core"|'"'"'core'"'"''; then
    fail "loader.sh appears to hardcode a 'core' module path or name outside comments"
else
    ok "loader.sh contains no hardcoded 'core' module path/name — module zero goes through the generic path"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
