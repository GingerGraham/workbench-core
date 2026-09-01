#!/usr/bin/env bash
# tests/check-getter-registry.sh — Phase 9 acceptance check.
#
# ARCHITECTURE.md §3/§5: get-functions/get-installers/domain getters are
# driven by each registered module's register.getters[] declarations, not a
# hardcoded registry inside core. Verified two ways: (1) `wb functions`
# lists a getter declared by a synthetic module with no core code change,
# and (2) grepping lib/ for anything that looks like a hardcoded getter
# name list (the donor's old _function_getters_registry() pattern) finds
# nothing.
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

# ── 1. lib/ contains no hardcoded getter-name registry — the donor
#    codebase's _function_getters_registry() pattern (a fixed heredoc list
#    of domain|filter|getter|label rows) must not have been ported forward.
if grep -rE '_function_getters_registry|get-gpg-functions|get-git-functions|get-terraform-functions' "${REPO_ROOT}/lib" 2>/dev/null; then
    fail "lib/ contains a hardcoded getter registry or a hardcoded domain getter name — these must come from register.getters[] only"
else
    ok "lib/ contains no hardcoded getter registry or hardcoded domain getter names"
fi

# ── 2. A synthetic module declaring register.getters[] shows up in
#    `wb functions` output, verbatim from its manifest — no core code
#    change was needed to add it. ──────────────────────────────────────────
SRC="${WORK}/src"
BARE="${WORK}/bare.git"
mkdir -p "${SRC}"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}"
(
    cd "${SRC}"
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    cat > shell/widget.sh <<'SH'
get-widget-functions() { echo "widget functions here"; }
widget-do-a-thing() { :; }
SH
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/widget.sh
      tier: tools
  getters:
    - name: widget
      function: get-widget-functions
      label: "Widget helpers"
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)

bash "${WB}" add widget-module "${BARE}" --private >/tmp/wb-getter-add.log 2>&1
functions_out="$(bash "${WB}" functions 2>&1)"

if echo "${functions_out}" | grep -q "get-widget-functions"; then
    ok "wb functions lists the getter declared by a module's register.getters[] entry"
else
    fail "wb functions did not list the module's declared getter"
    cat /tmp/wb-getter-add.log
    echo "${functions_out}"
fi

if echo "${functions_out}" | grep -q "Widget helpers"; then
    ok "wb functions includes the getter's declared label"
else
    fail "wb functions did not include the getter's label"
fi

if echo "${functions_out}" | grep -q "widget-do-a-thing"; then
    ok "wb functions lists a function actually defined in the module's registered shell file"
else
    fail "wb functions did not list a function from the registered shell file"
    echo "${functions_out}"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
