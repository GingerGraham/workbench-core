#!/usr/bin/env bash
# tests/check-tools-isolation.sh — docs/decisions-log.md D93 acceptance check.
#
# 'wb tools' runs each installer (and each installed-* predicate) in its own
# subshell with errexit, nounset and pipefail off, and reads its 'all' tool
# list on fd 3 rather than stdin. One installer can no longer end a
# 'wb tools install all' / 'wb tools upgrade all' run: not by an unbound
# variable, not by calling `exit`, and not by reading stdin and swallowing
# the rest of the list.
#
# Every 'wb tools' call here is a fresh 'bash bin/wb' subprocess, as a user
# runs it: bin/wb's own `set -uo pipefail` is what the installers used to
# inherit.
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

# The installers write their markers here; exported because they run in a
# separate 'wb' process.
export MARK="${WORK}/marks"
mkdir -p "${MARK}"

WB="${REPO_ROOT}/bin/wb"
# shellcheck source=bin/wb
source "${WB}" >"${WORK}/source.log" 2>&1
_wb_require modules/add.sh

# ── Fixture: one module, one installers.sh, five tools. ─────────────────────
# Friendly names sort a..e, which is also the order they're declared in, so
# the 'all' loops reach them in this order.
#   a  reads stdin                     — must not see the tool list
#   b  expands an unbound "$1"         — fatal under bin/wb's `set -u` before D93
#   c  calls `exit 7`                  — fatal to the caller before D93
#   d  plain success                   — must run, after a, b and c
#   e  plain success, but its predicate expands an unbound variable and
#      then runs it as a command (exit 127) — reported unresponsive
SRC="${WORK}/src-iso"
BARE="${WORK}/iso.git"
mkdir -p "${SRC}"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}" 2>/dev/null
(
    cd "${SRC}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    # Quoted heredoc: everything below is expanded when the installer runs.
    cat > shell/installers.sh <<'EOF'
install-a-reads-stdin() { read -r _x; echo "read:${_x}" > "${MARK}/a"; }
installed-a-reads-stdin() { return 0; }
install-b-unbound() { local v="$1"; echo "$v"; touch "${MARK}/b"; }
installed-b-unbound() { return 0; }
install-c-exits() { touch "${MARK}/c"; exit 7; }
installed-c-exits() { return 0; }
install-d-ok() { touch "${MARK}/d"; }
installed-d-ok() { return 0; }
install-e-badpred() { touch "${MARK}/e"; }
installed-e-badpred() { "${WB_TEST_NEVER_SET}" --version; }
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
workbench_cmd_add iso-tools "${BARE}" --private >"${WORK}/add.log" 2>&1

INSTLIST="${XDG_DATA_HOME}/workbench/modules/iso-tools/installers.list"
if [[ -s "${INSTLIST}" ]]; then
    ok "fixture module registered and its installers.list rendered"
else
    fail "fixture module did not register (installers.list missing or empty)"
    cat "${WORK}/add.log"
fi

# ── 1-5. wb tools install all ───────────────────────────────────────────────
# The one 'y' answers the confirmation prompt; after that stdin is at EOF.
printf 'y\n' | bash "${WB}" tools install all >"${WORK}/install-all.log" 2>&1
install_rc=$?

if [[ -f "${MARK}/d" ]]; then
    ok "install all: install-d-ok ran after b (unbound \$1) and c (exit 7)"
else
    fail "install all: install-d-ok never ran — the run ended early"
    cat "${WORK}/install-all.log"
fi

if [[ -f "${MARK}/a" ]] && ! grep -q 'iso-tools\||' "${MARK}/a"; then
    ok "install all: install-a-reads-stdin read nothing from the tool list (got '$(cat "${MARK}/a")')"
else
    fail "install all: install-a-reads-stdin consumed the tool list (got '$(cat "${MARK}/a" 2>/dev/null)')"
fi

# With nounset off, b's "$1" expands to empty and b succeeds — that is the
# point of D93 (installers behave as they would in an interactive shell).
# Only c fails, so the exit status (the failure count) is 1.
if [[ -f "${MARK}/b" ]]; then
    ok "install all: install-b-unbound ran to completion with nounset off"
else
    fail "install all: install-b-unbound did not complete"
fi

if [[ "${install_rc}" -eq 1 ]]; then
    ok "install all: exit status is 1 (one failure: c)"
else
    fail "install all: expected exit status 1, got ${install_rc}"
    cat "${WORK}/install-all.log"
fi

if grep -q 'c-exits (iso-tools): failed (exit 7)' "${WORK}/install-all.log" \
    && grep -q '1 tool(s) failed: c-exits' "${WORK}/install-all.log"; then
    ok "install all: output names c-exits as the failure, with its exit status"
else
    fail "install all: output does not name c-exits as a failure"
    cat "${WORK}/install-all.log"
fi

# ── 6-9. wb tools upgrade all ───────────────────────────────────────────────
rm -f "${MARK}"/*
bash "${WB}" tools upgrade all </dev/null >"${WORK}/upgrade-all.log" 2>&1
upgrade_rc=$?

if [[ -f "${MARK}/a" && -f "${MARK}/b" && -f "${MARK}/d" ]]; then
    ok "upgrade all: a, b and d ran (c's exit did not end the run)"
else
    fail "upgrade all: not every installed tool ran"
    cat "${WORK}/upgrade-all.log"
fi

if grep -q 'wb tools upgrade: 3 tool(s) upgraded, 1 failed' "${WORK}/upgrade-all.log"; then
    ok "upgrade all: the run completed and printed its summary"
else
    fail "upgrade all: no completion summary — the run ended early"
    cat "${WORK}/upgrade-all.log"
fi

if [[ ! -f "${MARK}/e" ]] \
    && grep -q '1 tool(s) skipped as unresponsive' "${WORK}/upgrade-all.log" \
    && grep -q 'e-badpred (iso-tools)' "${WORK}/upgrade-all.log"; then
    ok "upgrade all: the predicate that expands an unbound variable is reported unresponsive, and e was not run"
else
    fail "upgrade all: e-badpred was not reported unresponsive (or was run)"
    cat "${WORK}/upgrade-all.log"
fi

if [[ "${upgrade_rc}" -eq 1 ]]; then
    ok "upgrade all: exit status is 1 (one failure: c)"
else
    fail "upgrade all: expected exit status 1, got ${upgrade_rc}"
fi

# ── 10. A single-target install that exits does not take wb with it. ───────
# The process must still reach its own exit and report the status.
bash "${WB}" tools install c-exits </dev/null >"${WORK}/install-c.log" 2>&1
single_rc=$?
if [[ "${single_rc}" -eq 7 ]]; then
    ok "install c-exits: wb reports the installer's own exit status (7)"
else
    fail "install c-exits: expected exit status 7, got ${single_rc}"
    cat "${WORK}/install-c.log"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
