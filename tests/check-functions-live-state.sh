#!/usr/bin/env bash
# tests/check-functions-live-state.sh — Fix 4 acceptance check
# (docs/decisions-log.md D65): _wb_cmd_functions' "Loaded functions"/
# "Loaded aliases" listings now come from a live before/after diff of the
# shell's own function/alias table (after eager-sourcing every registered
# file once), not a second grep pass re-opening each file.
#
# Asserts byte-for-byte equivalence with the old static-grep behaviour for
# an unconditionally-defined function/alias, and the accuracy improvement
# for one defined only inside a guard whose condition is false at source
# time (a tool that genuinely isn't installed) — grep matches the
# "name()" line regardless of the surrounding `if`, so the old approach
# would have shown it even though it was never actually callable; the new
# live-state approach correctly omits it.
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

# ── Synthetic module: one plain function, one alias (both unconditional —
#    the byte-for-byte-equivalence case), and one function whose
#    definition itself sits inside `if command -v <tool that is
#    guaranteed absent>; then ... fi` — never actually defined when the
#    file is sourced, even though a line-based grep still matches its
#    "name()" text regardless of the surrounding control flow. ────────────
SRC="${WORK}/src"
BARE="${WORK}/bare.git"
mkdir -p "${SRC}"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}"
(
    cd "${SRC}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    cat > shell/livestate.sh <<'SH'
livestate-plain-thing() { :; }

alias livestate-plain-alias='echo plain'

if command -v livestate-definitely-missing-tool-xyz &>/dev/null; then
    livestate-guarded-thing() { :; }
    alias livestate-guarded-alias='echo guarded'
fi
SH
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/livestate.sh
      tier: tools
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)

bash "${WB}" add livestate-module "${BARE}" --private >/tmp/wb-functions-live-state-add.log 2>&1
FUNCTIONS_OUT="$(bash "${WB}" functions 2>&1)"

# ── 1. Unconditionally-defined names show exactly as the old static-grep
#    approach would have shown them — same name, same section. ────────────
if echo "${FUNCTIONS_OUT}" | grep -q "livestate-plain-thing"; then
    ok "'wb functions' lists the unconditionally-defined function livestate-plain-thing"
else
    fail "'wb functions' did not list livestate-plain-thing"
    echo "${FUNCTIONS_OUT}"
fi

if echo "${FUNCTIONS_OUT}" | grep -q "livestate-plain-alias"; then
    ok "'wb functions' lists the unconditionally-defined alias livestate-plain-alias"
else
    fail "'wb functions' did not list livestate-plain-alias"
    echo "${FUNCTIONS_OUT}"
fi

# ── 2. The guarded names never actually get defined (the tool their
#    guard checks for is guaranteed absent) — the new live-state approach
#    must correctly omit them, unlike a line-based grep, which would have
#    matched their "name()"/"alias name=" text regardless of the
#    surrounding `if`. ───────────────────────────────────────────────────
if command -v livestate-definitely-missing-tool-xyz &>/dev/null; then
    fail "test precondition broken: livestate-definitely-missing-tool-xyz unexpectedly exists on PATH"
else
    ok "precondition: livestate-definitely-missing-tool-xyz is genuinely absent, so the guarded definitions never run"
fi

if echo "${FUNCTIONS_OUT}" | grep -q "livestate-guarded-thing"; then
    fail "'wb functions' listed livestate-guarded-thing — it was never actually defined (its guard's condition is false), the old static-grep approach's known inaccuracy"
    echo "${FUNCTIONS_OUT}"
else
    ok "'wb functions' correctly omits livestate-guarded-thing (the accuracy improvement over static grep)"
fi

if echo "${FUNCTIONS_OUT}" | grep -q "livestate-guarded-alias"; then
    fail "'wb functions' listed livestate-guarded-alias — it was never actually defined"
    echo "${FUNCTIONS_OUT}"
else
    ok "'wb functions' correctly omits livestate-guarded-alias"
fi

# ── 3. Sanity: sourcing the fixture file directly in an ordinary shell
#    (no gating, no diffing — ground truth for what "actually defined"
#    means) agrees with 'wb functions': the guarded names are genuinely
#    never defined, confirming check 2 above isn't a false negative from
#    some other filtering. ─────────────────────────────────────────────────
GROUND_TRUTH="$(bash -c '
    source shell/livestate.sh 2>/dev/null
    command -v livestate-plain-thing >/dev/null 2>&1 && echo "plain:defined"
    command -v livestate-guarded-thing >/dev/null 2>&1 && echo "guarded:defined" || echo "guarded:undefined"
' 2>&1)"
CURRENT_DIR="$(find "${XDG_DATA_HOME}/workbench/modules/livestate-module/current" -maxdepth 0 2>/dev/null)"
if [[ -n "${CURRENT_DIR}" ]]; then
    GROUND_TRUTH="$(cd "${CURRENT_DIR}" && bash -c '
        source shell/livestate.sh 2>/dev/null
        command -v livestate-plain-thing >/dev/null 2>&1 && echo "plain:defined" || echo "plain:undefined"
        command -v livestate-guarded-thing >/dev/null 2>&1 && echo "guarded:defined" || echo "guarded:undefined"
    ' 2>&1)"
fi

if echo "${GROUND_TRUTH}" | grep -q "plain:defined" && echo "${GROUND_TRUTH}" | grep -q "guarded:undefined"; then
    ok "ground truth confirms: plain-thing is really defined, guarded-thing really is not"
else
    fail "ground truth check itself did not behave as expected"
    echo "${GROUND_TRUTH}"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
