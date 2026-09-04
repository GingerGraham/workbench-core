#!/usr/bin/env bash
# tests/check-local-overrides.sh — baseline-completion brief §Phase 2
# acceptance check.
#
# The single-file 90-local.sh became a directory,
# ${XDG_CONFIG_HOME:-~/.config}/workbench/local/: one reserved-name
# settings.sh keeping the old two-pass (early + final) semantics, plus any
# number of other user-authored *.sh files sourced once, together,
# filename-sorted, immediately after settings.sh's final pass and BEFORE
# WORKBENCH_USER_EXT_DIR (which stays the true last word of every content
# tier). Verifies: 'wb install' scaffolds a non-empty, commented, never-
# clobbered settings.sh; settings.sh's early pass still gates tier
# behaviour (a regression test against the old 90-local.sh semantics, not
# just a new-file-loads test); settings.sh's final pass still wins over a
# tier; another *.sh file in the same directory is callable in a new shell
# without touching settings.sh; and the local/*.sh -> WORKBENCH_USER_EXT_DIR
# ordering holds.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── 1-3. Scaffolding (_wb_scaffold_local_overrides, bin/wb) ────────────────
export HOME="${WORK}/home"
export XDG_CONFIG_HOME="${WORK}/scaffold-config"
export XDG_DATA_HOME="${WORK}/scaffold-data"
export XDG_CACHE_HOME="${WORK}/scaffold-cache"
mkdir -p "${HOME}"

WB="${REPO_ROOT}/bin/wb"
# shellcheck source=bin/wb
source "${WB}" >/tmp/wb-local-overrides-source.log 2>&1

SETTINGS="${XDG_CONFIG_HOME}/workbench/local/settings.sh"

_wb_scaffold_local_overrides

if [[ -s "${SETTINGS}" ]]; then
    ok "'wb install' scaffolding leaves a non-empty settings.sh in place"
else
    fail "settings.sh was not created (or is empty) by _wb_scaffold_local_overrides"
fi

if grep -q '^# WORKBENCH_PLAIN_SHELL=true$' "${SETTINGS}" 2>/dev/null \
    && grep -q '^# WORKBENCH_SHOW_FUNCTIONS=true$' "${SETTINGS}" 2>/dev/null; then
    ok "default settings.sh contains commented examples of the documented switches"
else
    fail "default settings.sh is missing expected commented examples"
    cat "${SETTINGS}" 2>/dev/null
fi

echo "# my own custom line" >> "${SETTINGS}"
_wb_scaffold_local_overrides
if grep -q "my own custom line" "${SETTINGS}" 2>/dev/null; then
    ok "re-running scaffolding never overwrites an existing settings.sh"
else
    fail "scaffolding clobbered an existing settings.sh"
fi

# ── 4-8. Loader behaviour: tier gating, final-pass precedence, another
#    local/*.sh file, and local/*.sh -> WORKBENCH_USER_EXT_DIR ordering. ────
export XDG_CONFIG_HOME="${WORK}/loader-config"
export XDG_DATA_HOME="${WORK}/loader-data"
export XDG_CACHE_HOME="${WORK}/loader-cache"

LOCAL_DIR="${XDG_CONFIG_HOME}/workbench/local"
USER_EXT_DIR="${XDG_CONFIG_HOME}/workbench/user"
mkdir -p "${LOCAL_DIR}" "${USER_EXT_DIR}"

# settings.sh: sets WORKBENCH_PLAIN_SHELL early (must gate the prompt
# fallback/WORKBENCH_SHOW_FUNCTIONS the same way 90-local.sh's early pass
# always did) and SOME_VAR on its final pass (must win over a tier that
# also set it).
cat > "${LOCAL_DIR}/settings.sh" <<'EOF'
WB_TEST_LOG="${WB_TEST_LOG:-}settings-pass "
WORKBENCH_PLAIN_SHELL=true
SOME_VAR=fromsettings
EOF

# Another, genuinely open local file — must load without touching
# settings.sh, and must NOT be re-sourced by the settings.sh-only early/
# final passes (only settings-pass should show up twice in the log, not
# this file's marker).
cat > "${LOCAL_DIR}/zz-widget.sh" <<'EOF'
WB_TEST_LOG="${WB_TEST_LOG}local-other "
local-extra-fn() { echo "hi from local-extra-fn"; }
EOF

# A synthetic registered module with one env-tier file, to prove
# settings.sh's final pass overrides a tier that touched the same variable.
mkdir -p "${WORK}/modules/acme-widget"
cat > "${WORK}/modules/acme-widget/sync.conf" <<EOF
TRACK_MODE=latest
TRACK_REF=v1.0.0
REGISTERED=true
SYNC_ENABLED=true
EOF
mkdir -p "${WORK}/widget-src"
cat > "${WORK}/widget-src/10-env.sh" <<'EOF'
WB_TEST_LOG="${WB_TEST_LOG}tier "
SOME_VAR=fromtier
EOF
cat > "${WORK}/modules/acme-widget/register.list" <<EOF
${WORK}/widget-src/10-env.sh|env
EOF

# WORKBENCH_USER_EXT_DIR content — must load AFTER local/zz-widget.sh.
cat > "${USER_EXT_DIR}/zz-ext.sh" <<'EOF'
WB_TEST_LOG="${WB_TEST_LOG}ext "
EOF

# shellcheck disable=SC2016
OUT="$(
    env -i \
        HOME="${WORK}/home" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
        WORKBENCH_MODULES_DIR="${WORK}/modules" \
        PATH="${PATH}" \
        bash -c '
            source "'"${REPO_ROOT}"'/lib/loader.sh"
            echo "TEST_LOG=${WB_TEST_LOG:-}"
            echo "SOME_VAR=${SOME_VAR:-unset}"
            echo "SHOW_FUNCTIONS=${WORKBENCH_SHOW_FUNCTIONS:-unset}"
            echo "PROMPT_ENGINE=${WORKBENCH_PROMPT_ENGINE:-unset}"
            command -v local-extra-fn >/dev/null && echo "EXTRA_FN=true" || echo "EXTRA_FN=false"
        '
)"

echo "--- loader output ---"
echo "${OUT}"
echo "--- end loader output ---"

test_log="$(printf '%s\n' "${OUT}" | grep '^TEST_LOG=' | sed 's/^TEST_LOG=//')"

# 4. settings.sh's early pass still gates tier behaviour: WORKBENCH_PLAIN_SHELL
#    set there forces WORKBENCH_SHOW_FUNCTIONS off and the plain prompt
#    engine, exactly like the old single-file 90-local.sh did.
if printf '%s\n' "${OUT}" | grep -q '^SHOW_FUNCTIONS=false$'; then
    ok "settings.sh's early pass still gates WORKBENCH_SHOW_FUNCTIONS via WORKBENCH_PLAIN_SHELL"
else
    fail "settings.sh's early pass did not gate WORKBENCH_SHOW_FUNCTIONS as expected"
fi
if printf '%s\n' "${OUT}" | grep -q '^PROMPT_ENGINE=plain$'; then
    ok "settings.sh's early pass still gates the plain prompt fallback via WORKBENCH_PLAIN_SHELL"
else
    fail "settings.sh's early pass did not select the plain prompt engine as expected"
fi

# 5. settings.sh's final pass wins over a tier that touched the same var.
if printf '%s\n' "${OUT}" | grep -q '^SOME_VAR=fromsettings$'; then
    ok "settings.sh's final pass still wins over a tier that also set the same variable"
else
    fail "a tier's value survived settings.sh's final pass unexpectedly: $(printf '%s\n' "${OUT}" | grep '^SOME_VAR=')"
fi

# 6. another local/*.sh file is callable, without touching settings.sh.
if printf '%s\n' "${OUT}" | grep -q '^EXTRA_FN=true$'; then
    ok "a second, genuinely open local/*.sh file's function is callable in a new shell"
else
    fail "local/zz-widget.sh's function was not sourced/callable"
fi

# 7. settings.sh itself is sourced exactly twice (early + final) — the
#    "other files" pass must exclude it, not source it a third time.
settings_count="$(printf '%s\n' "${test_log}" | grep -o 'settings-pass' | wc -l | tr -d ' ')"
if [[ "${settings_count}" -eq 2 ]]; then
    ok "settings.sh is sourced exactly twice (early + final), never picked up again by the 'other files' pass"
else
    fail "settings.sh was sourced ${settings_count} time(s), expected exactly 2 (log: ${test_log})"
fi

# 8. Ordering: local/*.sh (other files) before WORKBENCH_USER_EXT_DIR.
local_pos=$(printf '%s\n' "${test_log}" | grep -bo 'local-other' | head -1 | cut -d: -f1)
ext_pos=$(printf '%s\n' "${test_log}" | grep -bo 'ext' | head -1 | cut -d: -f1)
if [[ -n "${local_pos}" && -n "${ext_pos}" && "${local_pos}" -lt "${ext_pos}" ]]; then
    ok "other local/*.sh files are sourced before WORKBENCH_USER_EXT_DIR"
else
    fail "ordering broken: local/*.sh did not precede WORKBENCH_USER_EXT_DIR (log: ${test_log})"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
