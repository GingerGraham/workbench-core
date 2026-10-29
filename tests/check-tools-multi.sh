#!/usr/bin/env bash
# tests/check-tools-multi.sh — docs/decisions-log.md D106 acceptance check.
#
# 'wb tools install <name>...' and 'wb tools upgrade <name>...' take a list.
# Every name is resolved before any installer runs: one unknown name means
# nothing runs and the exit status is 2. A name given twice (or in both its
# friendly and install-<name> spelling) runs once. 'all' can't be mixed with
# names. The run ends with one summary naming what was installed, what
# failed, and (for upgrade) what was skipped. Collision warnings print once
# per command, not once per name.
#
# Every 'wb tools' call is a fresh 'bash bin/wb' subprocess, as a user runs it.
#
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# shellcheck disable=SC2015
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

# Installers write their markers here; exported because they run in a
# separate 'wb' process. Each installer appends one line per run, so a
# marker's line count is how many times it ran.
export MARK="${WORK}/marks"
mkdir -p "${MARK}"

WB="${REPO_ROOT}/bin/wb"
# shellcheck source=bin/wb
source "${WB}" >"${WORK}/source.log" 2>&1
_wb_require modules/add.sh

# make_module <module-name> <installers.sh content>
# A local bare repo with one installers file, registered with 'wb add'.
make_module() {
    local module="$1" content="$2" src="${WORK}/src-$1" bare="${WORK}/$1.git"
    git init -q --bare "${bare}"
    git clone -q "${bare}" "${src}" 2>/dev/null
    (
        cd "${src}" || exit 1
        git config user.email t@t.com
        git config user.name Test
        mkdir -p shell
        printf '%s\n' "${content}" > shell/installers.sh
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
    workbench_cmd_add "${module}" "${bare}" --private >"${WORK}/add-${module}.log" 2>&1
}

# Fixture tools, all in module 'multi-tools':
#   d-ok        succeeds; installed
#   c-exits     exits 7;  installed
#   f-absent    succeeds; NOT installed (predicate exits 1)
#   e-badpred   succeeds; predicate is broken -> unresponsive
#   g-ok        succeeds; installed
# Quoted: expanded when the installer runs, not here.
# shellcheck disable=SC2016
make_module multi-tools '
install-d-ok() { echo run >> "${MARK}/d"; }
installed-d-ok() { return 0; }
install-c-exits() { echo run >> "${MARK}/c"; exit 7; }
installed-c-exits() { return 0; }
install-f-absent() { echo run >> "${MARK}/f"; }
installed-f-absent() { return 1; }
install-e-badpred() { echo run >> "${MARK}/e"; }
installed-e-badpred() { return 9; }
install-g-ok() { echo run >> "${MARK}/g"; }
installed-g-ok() { return 0; }'

# A second module also declaring install-d-ok: a collision that
# 'multi-tools' wins (first by module-name order) and warns about.
# shellcheck disable=SC2016
make_module zz-dup '
install-d-ok() { echo dup >> "${MARK}/dup"; }'

if [[ -s "${XDG_DATA_HOME}/workbench/modules/multi-tools/installers.list" ]]; then
    ok "fixture modules registered"
else
    fail "fixture module did not register"
    cat "${WORK}/add-multi-tools.log"
fi

runs() { if [[ -f "${MARK}/$1" ]]; then wc -l < "${MARK}/$1" | tr -d ' '; else echo 0; fi; }
reset_marks() { rm -f "${MARK}"/*; }

# ── 1-3. install two names: both run, in order, with a summary. ────────────
reset_marks
bash "${WB}" tools install g-ok d-ok </dev/null >"${WORK}/i1.log" 2>&1
rc=$?
[[ "${rc}" -eq 0 && "$(runs g)" -eq 1 && "$(runs d)" -eq 1 ]] \
    && ok "install g-ok d-ok: both ran once, exit 0" \
    || { fail "install g-ok d-ok: rc=${rc} g=$(runs g) d=$(runs d)"; cat "${WORK}/i1.log"; }
grep -q 'wb tools install: 2 tool(s) installed: g-ok d-ok' "${WORK}/i1.log" \
    && ok "install g-ok d-ok: summary names both, in the order given" \
    || { fail "install g-ok d-ok: no summary naming both"; cat "${WORK}/i1.log"; }
[[ "$(grep -c "declared by both 'multi-tools' and 'zz-dup'" "${WORK}/i1.log")" -eq 1 ]] \
    && ok "install g-ok d-ok: the d-ok collision warning printed once, not once per name" \
    || { fail "install g-ok d-ok: collision warning count is $(grep -c 'declared by both' "${WORK}/i1.log")"; cat "${WORK}/i1.log"; }

# ── 4-5. an unknown name runs nothing and exits 2. ─────────────────────────
reset_marks
bash "${WB}" tools install d-ok nope-one g-ok nope-two </dev/null >"${WORK}/i2.log" 2>&1
rc=$?
[[ "${rc}" -eq 2 && "$(runs d)" -eq 0 && "$(runs g)" -eq 0 ]] \
    && ok "install with unknown names: exit 2, nothing ran" \
    || { fail "install with unknown names: rc=${rc} d=$(runs d) g=$(runs g)"; cat "${WORK}/i2.log"; }
grep -q 'no discovered installer named: nope-one nope-two' "${WORK}/i2.log" \
    && ok "install with unknown names: one error naming every unknown name" \
    || { fail "install with unknown names: error doesn't name both"; cat "${WORK}/i2.log"; }

# ── 6. a repeated name, in either spelling, runs once. ─────────────────────
reset_marks
bash "${WB}" tools install d-ok install-d-ok d-ok g-ok </dev/null >"${WORK}/i3.log" 2>&1
[[ "$(runs d)" -eq 1 && "$(runs g)" -eq 1 && "$(runs dup)" -eq 0 ]] \
    && ok "install d-ok install-d-ok d-ok g-ok: d-ok ran once, the collision loser never" \
    || { fail "install duplicates: d=$(runs d) g=$(runs g) dup=$(runs dup)"; cat "${WORK}/i3.log"; }

# ── 7. 'all' mixed with names is a usage error. ────────────────────────────
reset_marks
printf 'y\n' | bash "${WB}" tools install all d-ok >"${WORK}/i4.log" 2>&1
rc=$?
[[ "${rc}" -eq 2 && "$(runs d)" -eq 0 ]] \
    && ok "install all d-ok: exit 2, nothing ran" \
    || { fail "install all d-ok: rc=${rc} d=$(runs d)"; cat "${WORK}/i4.log"; }

# ── 8-9. one failure: the rest still run; the summary names the failure. ───
reset_marks
bash "${WB}" tools install c-exits d-ok </dev/null >"${WORK}/i5.log" 2>&1
rc=$?
[[ "${rc}" -eq 1 && "$(runs d)" -eq 1 ]] \
    && ok "install c-exits d-ok: d-ok still ran after c-exits exited; exit 1" \
    || { fail "install c-exits d-ok: rc=${rc} d=$(runs d)"; cat "${WORK}/i5.log"; }
grep -q 'wb tools install: 1 tool(s) installed: d-ok' "${WORK}/i5.log" \
    && grep -q 'wb tools install: 1 tool(s) failed: c-exits' "${WORK}/i5.log" \
    && ok "install c-exits d-ok: summary separates installed from failed" \
    || { fail "install c-exits d-ok: summary missing or wrong"; cat "${WORK}/i5.log"; }

# ── 10-12. upgrade a list: only installed tools run; the rest are named. ───
reset_marks
bash "${WB}" tools upgrade d-ok f-absent e-badpred g-ok </dev/null >"${WORK}/u1.log" 2>&1
rc=$?
[[ "${rc}" -eq 0 && "$(runs d)" -eq 1 && "$(runs g)" -eq 1 && "$(runs f)" -eq 0 && "$(runs e)" -eq 0 ]] \
    && ok "upgrade d-ok f-absent e-badpred g-ok: only d-ok and g-ok ran, exit 0" \
    || { fail "upgrade list: rc=${rc} d=$(runs d) g=$(runs g) f=$(runs f) e=$(runs e)"; cat "${WORK}/u1.log"; }
grep -q "1 tool(s) not installed — nothing to upgrade (use 'wb tools install'): f-absent" "${WORK}/u1.log" \
    && ok "upgrade list: the named not-installed tool is reported, not silently dropped" \
    || { fail "upgrade list: f-absent not reported as not installed"; cat "${WORK}/u1.log"; }
grep -q '1 tool(s) skipped as unresponsive' "${WORK}/u1.log" \
    && grep -q 'e-badpred (multi-tools)' "${WORK}/u1.log" \
    && ok "upgrade list: the unresponsive tool is reported" \
    || { fail "upgrade list: e-badpred not reported unresponsive"; cat "${WORK}/u1.log"; }

# ── 13. upgrade with an unknown name runs nothing and exits 2. ─────────────
reset_marks
bash "${WB}" tools upgrade d-ok nope-one </dev/null >"${WORK}/u2.log" 2>&1
rc=$?
[[ "${rc}" -eq 2 && "$(runs d)" -eq 0 ]] \
    && ok "upgrade with an unknown name: exit 2, nothing ran" \
    || { fail "upgrade with an unknown name: rc=${rc} d=$(runs d)"; cat "${WORK}/u2.log"; }

# ── 14. a single name keeps its exact existing behaviour. ──────────────────
reset_marks
bash "${WB}" tools install c-exits </dev/null >"${WORK}/i6.log" 2>&1
rc=$?
[[ "${rc}" -eq 7 ]] \
    && ok "install c-exits (one name): exit status is still the installer's own (7)" \
    || { fail "install c-exits (one name): expected 7, got ${rc}"; cat "${WORK}/i6.log"; }

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
