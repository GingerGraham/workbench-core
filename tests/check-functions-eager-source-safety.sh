#!/usr/bin/env bash
# tests/check-functions-eager-source-safety.sh — regression guard for a
# confirmed crash: `wb functions` eager-sources every registered file so
# "_<name>-available" predicates are callable (lib/core/functions.sh
# "Declaring function availability"), inside bin/wb's own `set -u`
# process. Every module's shell/*.sh is written and tested only against
# lib/loader.sh's own sourcing, which never sets -u — an unquoted
# reference to a genuinely-unset variable (e.g. a bare "${DISPLAY}",
# confirmed in workbench-shell's shell/editors.sh) is completely fine
# there. Under nounset, a non-interactive shell doesn't just fail that
# one expansion, it exits the whole process outright — `wb functions`
# crashed silently (no output, exit 1) the moment a registered module
# had any such reference, taking out every other module's listing in
# the same run along with it.
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

# ── Synthetic module: one file referencing a genuinely-unset variable
#    with no ":-" default, exactly like shell/editors.sh's real
#    "${DISPLAY}" reference — fine under lib/loader.sh, fatal under
#    bin/wb's own set -u unless the eager-source step guards against
#    it. A second, unrelated function in the same file confirms the
#    rest of the file still gets sourced (and its predicates still
#    work) despite the unset-variable line. ─────────────────────────
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
    cat > shell/gizmo.sh <<'SH'
if [[ -n "${SOME_TOTALLY_UNSET_VAR}" ]]; then
    :
fi

gizmo-do-a-thing() { :; }

gizmo-gated-off() { :; }
_wb_declare_availability false-binary-xyz gizmo-gated-off
SH
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
core_api: ">=1.2 <2.0"
register:
  shell:
    - src: shell/gizmo.sh
      tier: tools
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)

bash "${WB}" add gizmo-module "${BARE}" --private >/tmp/wb-eager-source-add.log 2>&1
functions_out="$(bash "${WB}" functions 2>&1)"
functions_rc=$?

if [[ "${functions_rc}" -eq 0 ]]; then
    ok "wb functions exits 0 when a registered file references an unset variable"
else
    fail "wb functions exited ${functions_rc} instead of 0"
    cat /tmp/wb-eager-source-add.log
    echo "${functions_out}"
fi

if echo "${functions_out}" | grep -q "gizmo-do-a-thing"; then
    ok "wb functions still lists a function from the same file as the unset-variable reference"
else
    fail "wb functions did not list gizmo-do-a-thing — the unset-variable line likely killed the whole process"
    echo "${functions_out}"
fi

if echo "${functions_out}" | grep -q "gizmo-gated-off"; then
    fail "wb functions listed gizmo-gated-off — its predicate reports unavailable, it must be hidden"
else
    ok "availability gating still works for a file that also has an unset-variable reference"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
