#!/usr/bin/env bash
# tests/check-wb-functions-show-scope.sh — docs/decisions-log.md D73.
#
# Real-world regression, reported live: with WORKBENCH_SHOW_FUNCTIONS=true,
# every new interactive shell dropped into an interactive `less` session on
# launch/reload (surprising — this banner used to just print and return),
# and its column-formatted output collapsed to a much narrower layout than
# before, since `column` loses real-terminal-width detection once its own
# stdout is the write end of a pipe rather than the tty itself.
#
# Fixed by decoupling the automatic startup banner from both the pager
# (lib/loader.sh now calls `get-functions --no-pager --no-aliases`, never
# `get-functions` bare) and the aliases section (dropped from the banner
# entirely, not just hidden, per the "may be beneficial to only show
# functions loaded and the getters list" follow-up). This suite covers the
# two things a non-tty test harness *can* observe directly: --no-aliases
# actually drops the "Loaded aliases" section while keeping functions/
# getters, and get-functions forwards its arguments to `wb functions`
# unchanged rather than hardcoding any flags itself. The pager/column-width
# fix itself (COLUMNS capture in _wb_cmd_functions, bin/wb) needs a real
# tty to observe and is covered by manual verification in the PR, not here
# — tests/check-wb-functions-pager.sh already covers _wb_maybe_page's own
# tty gate without one.
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

# ── Synthetic module: a function plus an alias, so both sections have
#    something real to show/hide. ────────────────────────────────────────
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
    cat > shell/widget.sh <<'SH'
get-widget-functions() { echo "widget functions here"; }
widget-do-a-thing() { :; }
alias widget-alias='widget-do-a-thing'
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
) >/dev/null 2>&1

bash "${WB}" add widget-module "${BARE}" --private >/tmp/wb-show-scope-add.log 2>&1

# ── 1-3. Default `wb functions` still shows everything (no regression to
#    the documented default — only an explicit --no-aliases trims it). ─────
default_out="$(bash "${WB}" functions --no-pager 2>&1)"

if echo "${default_out}" | grep -q '\[INFO\] Loaded aliases:'; then
    ok "default 'wb functions' still includes the Loaded aliases section"
else
    fail "default 'wb functions' unexpectedly dropped the Loaded aliases section"
    echo "${default_out}"
fi

if echo "${default_out}" | grep -q "widget-alias"; then
    ok "default 'wb functions' lists the synthetic module's alias"
else
    fail "default 'wb functions' did not list widget-alias"
    echo "${default_out}"
fi

if echo "${default_out}" | grep -q "widget-do-a-thing"; then
    ok "default 'wb functions' still lists loaded functions alongside aliases"
else
    fail "default 'wb functions' did not list widget-do-a-thing"
fi

# ── 4-6. --no-aliases drops the aliases section but keeps functions and
#    getters — the shape the automatic startup banner now uses. ────────────
trimmed_out="$(bash "${WB}" functions --no-pager --no-aliases 2>&1)"

if echo "${trimmed_out}" | grep -q '\[INFO\] Loaded aliases:'; then
    fail "--no-aliases did not suppress the Loaded aliases section"
    echo "${trimmed_out}"
else
    ok "--no-aliases suppresses the Loaded aliases section"
fi

if echo "${trimmed_out}" | grep -q "widget-do-a-thing"; then
    ok "--no-aliases still lists loaded functions"
else
    fail "--no-aliases unexpectedly dropped loaded functions too"
    echo "${trimmed_out}"
fi

if echo "${trimmed_out}" | grep -q "get-widget-functions.*Widget helpers"; then
    ok "--no-aliases still lists getters"
else
    fail "--no-aliases unexpectedly dropped the getters section"
    echo "${trimmed_out}"
fi

# ── 7. get-functions forwards its arguments to `wb functions` unchanged —
#    the mechanism lib/loader.sh's startup banner relies on. ────────────────
mkdir -p "${XDG_DATA_HOME}/workbench/modules/core/current/bin"
ln -sf "${WB}" "${XDG_DATA_HOME}/workbench/modules/core/current/bin/wb"

# shellcheck source=lib/core/log.sh
source "${REPO_ROOT}/lib/core/log.sh"
# shellcheck source=lib/core/functions.sh
source "${REPO_ROOT}/lib/core/functions.sh"

get_functions_out="$(get-functions --no-pager --no-aliases 2>&1)"
if echo "${get_functions_out}" | grep -q '\[INFO\] Loaded aliases:'; then
    fail "get-functions did not forward --no-aliases through to 'wb functions'"
    echo "${get_functions_out}"
else
    ok "get-functions forwards its arguments through to 'wb functions' unchanged"
fi

# ── 8. lib/loader.sh's own interactive-startup call passes both flags —
#    a cheap regression guard against silently reverting the wiring. ───────
if grep -q 'get-functions --no-pager --no-aliases' "${REPO_ROOT}/lib/loader.sh"; then
    ok "lib/loader.sh's interactive startup banner calls get-functions --no-pager --no-aliases"
else
    fail "lib/loader.sh no longer calls get-functions with --no-pager --no-aliases"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
