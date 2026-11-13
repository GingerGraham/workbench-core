#!/usr/bin/env bash
# tests/check-wb-functions-filter.sh — docs/decisions-log.md D112.
#
# `wb functions <filter>...`: a term that exactly equals a module's name
# selects that module's whole content; any other term selects names that
# contain it (case-sensitive); several terms add up; nothing left in a
# section means the section isn't printed; no match is a message on stderr
# and status 1. With no terms the output is what it was before D112.
#
# Two synthetic modules so "only that module" is observable:
#   widget-module: widget-do-a-thing, alias widget-alias, getter
#                  get-widget-functions
#   gadget-module: gadget-run, gadget-stop (needs a tool this host lacks),
#                  alias gdg, getter get-gadget-functions
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
# A fixed width, so `column` lays names out the same way everywhere.
export COLUMNS=200

WB="${REPO_ROOT}/bin/wb"
GOLDEN="${SCRIPT_DIR}/fixtures/wb-functions-nofilter.golden"

# add_module <name> <shell-file-basename> <getter-name> <getter-fn> <label>
# Expects the shell file's content on stdin.
add_module() {
    local name="$1" file="$2" getter="$3" getter_fn="$4" label="$5"
    local src="${WORK}/src-${name}" bare="${WORK}/${name}.git"
    git init -q --bare "${bare}"
    git clone -q "${bare}" "${src}" 2>/dev/null
    mkdir -p "${src}/shell"
    cat > "${src}/shell/${file}"
    (
        cd "${src}" || exit 1
        git config user.email t@t.com
        git config user.name Test
        cat > .dotfiles-sync.yml <<EOF
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/${file}
      tier: tools
  getters:
    - name: ${getter}
      function: ${getter_fn}
      label: "${label}"
EOF
        git add -A && git commit -q -m v1
        git branch -M main
        git push -q origin main
        git tag v1.0.0 && git push -q origin v1.0.0
    ) >/dev/null 2>&1
    bash "${WB}" add "${name}" "${bare}" --private >"${WORK}/add-${name}.log" 2>&1
}

add_module widget-module widget.sh widget get-widget-functions "Widget helpers" <<'SH'
get-widget-functions() { echo "widget functions here"; }
widget-do-a-thing() { :; }
alias widget-alias='widget-do-a-thing'
SH

add_module gadget-module gadget.sh gadget get-gadget-functions "Gadget helpers" <<'SH'
get-gadget-functions() { echo "gadget functions here"; }
gadget-run() { :; }
gadget-stop() { :; }
alias gdg='gadget-run'
_wb_declare_availability tool-absent-gadget-xyz gadget-stop
SH

setup_out="$(bash "${WB}" functions --no-pager 2>&1)"
if ! grep -q 'gadget-run' <<<"${setup_out}"; then
    echo "FAIL: setup — gadget-module's functions are not listed; cannot run the suite"
    cat "${WORK}/add-gadget-module.log"
    exit 1
fi

# run <args...> — stdout only, stderr dropped.
run() { bash "${WB}" functions --no-pager "$@" 2>/dev/null; }
# A listing as one name per line, whatever `column` did to the layout.
words() { tr -s ' \t' '\n' | grep -v '^$' | sort; }

# ── 1. No terms: the listing is what it was before D112. The golden was
#    captured from main's bin/wb with these same two modules. Column
#    layout differs between util-linux and BSD `column`, so compare
#    whitespace-collapsed. ─────────────────────────────────────────────────
norm() { tr -s ' \t' ' ' | sed 's/ $//'; }
if [[ -f "${GOLDEN}" ]] && [[ "$(run | norm)" == "$(norm < "${GOLDEN}")" ]]; then
    ok "no filter: output is unchanged from before D112 (golden from main)"
else
    fail "no filter: output differs from the golden captured on main"
    diff <(run | norm) <(norm < "${GOLDEN}") | head -20
fi

# ── 2. A term equal to a module name selects that module alone, even
#    though none of its names contain the term. ─────────────────────────────
out="$(run gadget-module)"
if grep -q 'gadget-run' <<<"${out}" && grep -q 'gadget-stop' <<<"${out}" \
    && grep -q 'gdg' <<<"${out}" && grep -q 'get-gadget-functions.*Gadget helpers' <<<"${out}" \
    && ! grep -q 'widget' <<<"${out}"; then
    ok "module name: only that module's functions, aliases and getter are listed"
else
    fail "module name: expected all of gadget-module and nothing of widget-module"
    echo "${out}"
fi

# ── 3. A substring of one function name lists that function, drops the
#    other module's names, and leaves out the empty sections. ──────────────
out="$(run gadget-run)"
if [[ "$(grep -v '^\[INFO\]\|^$' <<<"${out}" | words)" == "gadget-run" ]] \
    && ! grep -q 'Loaded aliases' <<<"${out}" \
    && ! grep -q 'Getters' <<<"${out}"; then
    ok "substring of one function: that function only, empty sections left out"
else
    fail "substring of one function: expected only gadget-run under Loaded functions"
    echo "${out}"
fi

# ── 4. A substring matching an alias only: the aliases section appears
#    with just that alias, and there is no functions section. ───────────────
out="$(run gdg)"
if grep -q '\[INFO\] Loaded aliases:' <<<"${out}" \
    && [[ "$(grep -v '^\[INFO\]\|^$' <<<"${out}" | words)" == "gdg" ]] \
    && ! grep -q 'Loaded functions' <<<"${out}"; then
    ok "substring matching an alias only: aliases section with just that alias"
else
    fail "alias-only match: expected only the aliases section with gdg"
    echo "${out}"
fi

# ── 5. A substring that matches a getter's function name lists the getter
#    line (and the function of the same name). ──────────────────────────────
out="$(run get-widget)"
if grep -q 'get-widget-functions.*Widget helpers' <<<"${out}" && ! grep -q 'gadget' <<<"${out}"; then
    ok "substring matching a getter name lists that getter"
else
    fail "getter match: expected the widget getter line only"
    echo "${out}"
fi

# ── 6. Two terms: the union of what each matches. ──────────────────────────
out="$(run gadget-run widget-alias)"
if [[ "$(grep -v '^\[INFO\]\|^$' <<<"${out}" | words | tr '\n' ' ')" == "gadget-run widget-alias " ]]; then
    ok "two terms: the union of both matches"
else
    fail "two terms: expected gadget-run and widget-alias"
    echo "${out}"
fi

# A module term and a name term together: whole module plus the extra name.
out="$(run gadget-module widget-do)"
if grep -q 'gadget-stop' <<<"${out}" && grep -q 'widget-do-a-thing' <<<"${out}" \
    && ! grep -q 'widget-alias' <<<"${out}"; then
    ok "a module term and a name term together: the module plus the extra names"
else
    fail "module + name term: expected all of gadget-module plus widget-do-a-thing only"
    echo "${out}"
fi

# ── 7. No match: nothing on stdout, a message on stderr, status 1. ─────────
stdout="$(bash "${WB}" functions --no-pager zzz-nothing yyy-nothing 2>"${WORK}/stderr")"
rc=$?
if [[ -z "${stdout}" ]] && [[ "${rc}" -eq 1 ]] \
    && [[ "$(cat "${WORK}/stderr")" == "No functions, aliases or getters match: zzz-nothing yyy-nothing" ]]; then
    ok "no match: nothing on stdout, message on stderr, exit 1"
else
    fail "no match: expected empty stdout, the stderr message and exit 1 (got rc=${rc}, stdout='${stdout}', stderr='$(cat "${WORK}/stderr")')"
fi

# The same through the pager wrapper: the pipeline's status is the impl's.
bash "${WB}" functions zzz-nothing >/dev/null 2>&1
if [[ $? -eq 1 ]]; then
    ok "no match: exit 1 also when the listing goes through the pager pipeline"
else
    fail "no match: exit status lost when the output is piped through _wb_maybe_page"
fi

# ── 8. Flags still apply with a filter. ────────────────────────────────────
out="$(run gadget-module --no-aliases)"
if grep -q 'gadget-run' <<<"${out}" && ! grep -q 'Loaded aliases' <<<"${out}" && ! grep -q 'gdg' <<<"${out}"; then
    ok "--no-aliases with a filter: aliases section left out"
else
    fail "--no-aliases with a filter: aliases still shown"
    echo "${out}"
fi

# gadget-stop is gated on a missing tool: hidden by default, listed by --all.
out="$(run gadget-stop)"
if grep -q 'available once tooling is installed' <<<"${out}" && grep -q 'gadget-stop' <<<"${out}" \
    && ! grep -q 'gadget-run' <<<"${out}"; then
    ok "a filtered name that needs missing tooling appears in the 'available once' block"
else
    fail "filtered unavailable name: expected the 'available once tooling is installed' block with gadget-stop"
    echo "${out}"
fi

out="$(run gadget-stop --all)"
if ! grep -q 'available once tooling is installed' <<<"${out}" && grep -q 'gadget-stop' <<<"${out}"; then
    ok "--all with a filter: the gated function is listed in the main list"
else
    fail "--all with a filter: gadget-stop should be in the main list with no 'available once' block"
    echo "${out}"
fi

out="$(run gadget-module --compact)"
if grep -q 'need tooling you don.t have' <<<"${out}" && ! grep -q 'available once tooling is installed' <<<"${out}"; then
    ok "--compact with a filter: the 'available once' block is one line"
else
    fail "--compact with a filter: expected the one-line summary"
    echo "${out}"
fi

# ── 9. Terms and flags in either order give the same output. ──────────────
a="$(bash "${WB}" functions gadget --no-aliases --no-pager 2>&1)"
b="$(bash "${WB}" functions --no-pager --no-aliases gadget 2>&1)"
c="$(bash "${WB}" functions --no-aliases gadget --no-pager 2>&1)"
if [[ -n "${a}" ]] && [[ "${a}" == "${b}" ]] && [[ "${b}" == "${c}" ]]; then
    ok "terms and flags in any order: identical output"
else
    fail "terms and flags in a different order changed the output"
fi

# ── 10. Matching is case-sensitive and an unknown --flag is not a term. ────
if [[ -z "$(run GADGET)" ]]; then
    ok "matching is case-sensitive"
else
    fail "GADGET should not match lowercase names"
fi

if [[ "$(run --not-a-flag)" == "$(run)" ]]; then
    ok "an unknown --flag is ignored, not treated as a term"
else
    fail "an unknown --flag changed the listing"
fi

# ── 11. The help documents the filter. ─────────────────────────────────────
if bash "${WB}" help functions 2>&1 | grep -q 'filter'; then
    ok "'wb help functions' documents the filter"
else
    fail "'wb help functions' does not mention the filter"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
