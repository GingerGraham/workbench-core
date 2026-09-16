#!/usr/bin/env bash
# tests/check-function-availability-gating.sh — regression guard for the
# "_<name>-available" predicate convention (docs/module-authoring.md
# "Declaring function availability"): a function whose predicate reports
# unavailable must be hidden from `wb functions`, one whose predicate
# reports available (or has none) must still show, --all/
# WORKBENCH_FUNCTIONS_SHOW_ALL must override gating, and the hint line
# must report a reason only when it can be recovered mechanically.
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

# ── Synthetic module: a plain function, one gated off (via
#    _wb_declare_availability, on a binary guaranteed absent), one gated
#    on (present binary), and one gated off via a hand-written predicate
#    (to confirm the hint line's reason stays mechanical-only). ─────────
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
    cat > shell/sprocket.sh <<'SH'
sprocket-plain-thing() { :; }

sprocket-gated-off() { :; }
_wb_declare_availability false-binary-xyz sprocket-gated-off

sprocket-gated-on() { :; }
_wb_declare_availability bash sprocket-gated-on

sprocket-hand-gated() { :; }
_sprocket-hand-gated-available() { [[ -n "${SOME_VAR:-}" ]] || command -v false-binary-xyz &>/dev/null; }
SH
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/sprocket.sh
      tier: tools
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)

bash "${WB}" add sprocket-module "${BARE}" --private >/tmp/wb-availability-add.log 2>&1
functions_out="$(bash "${WB}" functions 2>&1)"
functions_all_out="$(bash "${WB}" functions --all 2>&1)"

if echo "${functions_out}" | grep -q "sprocket-plain-thing"; then
    ok "wb functions lists a function with no availability predicate"
else
    fail "wb functions did not list sprocket-plain-thing (no predicate declared — should always show)"
    cat /tmp/wb-availability-add.log
    echo "${functions_out}"
fi

if echo "${functions_out}" | grep -q "sprocket-gated-off"; then
    fail "wb functions listed sprocket-gated-off — its predicate reports unavailable, it must be hidden"
else
    ok "wb functions hides a function whose predicate reports unavailable"
fi

if echo "${functions_out}" | grep -q "sprocket-gated-on"; then
    ok "wb functions lists a function whose predicate reports available"
else
    fail "wb functions did not list sprocket-gated-on — its predicate should report available (bash is always present)"
fi

if echo "${functions_out}" | grep -qE '^_sprocket-.*-available$'; then
    fail "wb functions listed a predicate function itself — predicates must stay hidden (leading underscore)"
else
    ok "wb functions does not list the predicate functions themselves"
fi

if echo "${functions_all_out}" | grep -q "sprocket-gated-off" && echo "${functions_all_out}" | grep -q "sprocket-hand-gated"; then
    ok "wb functions --all shows gated functions regardless of their predicates"
else
    fail "wb functions --all did not show every gated function"
    echo "${functions_all_out}"
fi

if echo "${functions_out}" | grep -q "more hidden (missing: false-binary-xyz)"; then
    ok "hint line reports the specific missing command for a _wb_declare_availability predicate"
else
    fail "hint line did not report the mechanically-recoverable reason"
    echo "${functions_out}"
fi

if echo "${functions_out}" | grep -qE "more hidden \(missing: [^)]*false-binary-xyz, false-binary-xyz"; then
    fail "hint line duplicated the same reason instead of deduplicating"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
