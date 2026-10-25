#!/usr/bin/env bash
# tests/check-generated-getters.sh — docs/decisions-log.md D89 acceptance check.
#
# Core generates every register.getters[] function a module doesn't define
# itself. The sync renders getters.list; the loader defines each missing
# getter as a call to _wb_module_getter, which lists the functions and
# aliases in the module's register.list files. No BASH_SOURCE, so the same
# getter works in bash and zsh. A hand-written getter always wins, and a
# getter name that isn't a plain identifier is never evaluated.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }
skip() { echo "SKIP: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
export XDG_CACHE_HOME="${WORK}/cache"
mkdir -p "${HOME}"

WB="${REPO_ROOT}/bin/wb"
# shellcheck source=bin/wb
source "${WB}" >"${WORK}/source.log" 2>&1
_wb_require modules/add.sh
# The running Core API is read from the version file; write the defaults so
# a fixture declaring core_api ">=1.8 <2.0" is accepted.
_workbench_ensure_version_file

# The platform-tier file is named for the OS this host is NOT running.
case "$(uname -s)" in
    Darwin) OTHER_OS="linux" ;;
    *)      OTHER_OS="macos" ;;
esac

# make_module <dir> <bare> — commit and tag whatever is in <dir> as v1.0.0.
make_module() {
    local src="$1" bare="$2"
    (
        cd "${src}" || exit 1
        git config user.email t@t.com
        git config user.name Test
        git add -A && git commit -q -m v1
        git branch -M main
        git push -q origin main
        git tag v1.0.0 && git push -q origin v1.0.0
    )
}

new_repo() {
    local src="$1" bare="$2"
    mkdir -p "${src}"
    git init -q --bare "${bare}"
    git clone -q "${bare}" "${src}" 2>/dev/null
}

# ── Fixture 1: generated getter. Two shell files, one function and one alias
#    each (the second uses the `function name {` form), and a platform file
#    for the other OS. No getter is defined anywhere. ───────────────────────
SRC_F="${WORK}/src-fixture"; BARE_F="${WORK}/fixture.git"
new_repo "${SRC_F}" "${BARE_F}"
mkdir -p "${SRC_F}/shell"
cat > "${SRC_F}/shell/one.sh" <<'EOF'
fixture-one() { echo one; }
alias fx-one='echo one'
EOF
cat > "${SRC_F}/shell/two.sh" <<'EOF'
function fixture-two {
    echo two
}
alias fx-two='echo two'
EOF
cat > "${SRC_F}/shell/${OTHER_OS}.sh" <<'EOF'
fixture-other-os() { echo other; }
EOF
cat > "${SRC_F}/.dotfiles-sync.yml" <<EOF
version: 1
branch: main
core_api: ">=1.8 <2.0"
register:
  shell:
    - src: shell/one.sh
      tier: tools
    - src: shell/two.sh
      tier: tools
    - src: shell/${OTHER_OS}.sh
      tier: platform
  getters:
    - name: fixture
      function: get-fixture-functions
      label: "Fixture helpers"
EOF
make_module "${SRC_F}" "${BARE_F}"

# ── Fixture 2: a hand-written getter (with a marker), plus an entry whose
#    function is not a plain identifier. ────────────────────────────────────
PWN="${WORK}/pwned"
SRC_O="${WORK}/src-own"; BARE_O="${WORK}/own.git"
new_repo "${SRC_O}" "${BARE_O}"
mkdir -p "${SRC_O}/shell"
cat > "${SRC_O}/shell/own.sh" <<'EOF'
own-thing() { :; }
get-own-functions() { echo "OWN-GETTER-MARKER"; }
EOF
cat > "${SRC_O}/.dotfiles-sync.yml" <<EOF
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/own.sh
      tier: tools
  getters:
    - name: own
      function: get-own-functions
      label: "Own helpers"
    - name: evil
      function: "x; touch ${PWN}"
      label: "Evil"
EOF
make_module "${SRC_O}" "${BARE_O}"

workbench_cmd_add fixture-mod "${BARE_F}" --private >"${WORK}/add-fixture.log" 2>&1
workbench_cmd_add own-mod "${BARE_O}" --private >"${WORK}/add-own.log" 2>&1

MODS="${XDG_DATA_HOME}/workbench/modules"

# Core: only its functions.sh, at the core tier, as the real register.list
# would have it — enough for the loader to give the shell _wb_module_getter.
mkdir -p "${MODS}/core"
cat > "${MODS}/core/sync.conf" <<'EOF'
TRACK_MODE=latest
TRACK_REF=v0.1.0
REGISTERED=true
SYNC_ENABLED=true
EOF
printf '%s|core\n' "${REPO_ROOT}/lib/core/functions.sh" > "${MODS}/core/register.list"

# ── 1. getters.list is rendered. ────────────────────────────────────────────
if grep -qx 'get-fixture-functions|Fixture helpers' "${MODS}/fixture-mod/getters.list" 2>/dev/null; then
    ok "getters.list contains 'get-fixture-functions|Fixture helpers'"
else
    fail "getters.list for fixture-mod is missing the declared getter"
    cat "${MODS}/fixture-mod/getters.list" 2>/dev/null
    cat "${WORK}/add-fixture.log"
fi

# ── 2-3. An entry whose function isn't a plain identifier is skipped with a
#    warning and never written. ──────────────────────────────────────────────
if grep -q 'touch' "${MODS}/own-mod/getters.list" 2>/dev/null; then
    fail "getters.list contains the unsafe entry"
    cat "${MODS}/own-mod/getters.list"
elif grep -qx 'get-own-functions|Own helpers' "${MODS}/own-mod/getters.list" 2>/dev/null; then
    ok "the unsafe getter entry is not written to getters.list (the valid one is)"
else
    fail "getters.list for own-mod is missing its valid getter"
    cat "${MODS}/own-mod/getters.list" 2>/dev/null
fi
if grep -q "skipping register.getters\[\] entry 'evil'" "${WORK}/add-own.log"; then
    ok "the unsafe getter entry is skipped with a warning"
else
    fail "no warning for the unsafe getter entry"
    cat "${WORK}/add-own.log"
fi

# run_in_shell <bash|zsh> <commands> — source the real loader in a clean
# environment, then run <commands>.
run_in_shell() {
    local shell="$1" cmds="$2" flag="-c"
    [[ "${shell}" == "zsh" ]] && flag="-ic"
    env -i \
        HOME="${HOME}" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
        WORKBENCH_USER_EXT_ENABLED=false \
        TERM=dumb \
        PATH="${PATH}" \
        "${shell}" "${flag}" "source '${REPO_ROOT}/lib/loader.sh'; ${cmds}"
}

# check_shell <bash|zsh> — the generated and hand-written getters in one shell.
check_shell() {
    local shell="$1" out own
    out="$(run_in_shell "${shell}" 'get-fixture-functions' 2>"${WORK}/${shell}-getter.err")"

    if printf '%s\n' "${out}" | grep -q 'Fixture helpers — functions' \
        && printf '%s\n' "${out}" | grep -qw 'fixture-one' \
        && printf '%s\n' "${out}" | grep -qw 'fixture-two'; then
        ok "${shell}: get-fixture-functions is generated and lists both functions (incl. the 'function name {' form)"
    else
        fail "${shell}: get-fixture-functions did not list both functions"
        printf '%s\n' "${out}"
        cat "${WORK}/${shell}-getter.err"
    fi

    if printf '%s\n' "${out}" | grep -q 'Fixture helpers — aliases' \
        && printf '%s\n' "${out}" | grep -qw 'fx-one' \
        && printf '%s\n' "${out}" | grep -qw 'fx-two'; then
        ok "${shell}: get-fixture-functions lists both aliases"
    else
        fail "${shell}: get-fixture-functions did not list both aliases"
        printf '%s\n' "${out}"
    fi

    if printf '%s\n' "${out}" | grep -q 'fixture-other-os'; then
        fail "${shell}: get-fixture-functions lists the other OS's platform file"
    else
        ok "${shell}: get-fixture-functions leaves out the other OS's platform-tier file"
    fi

    # zsh runs interactive (-i), so it also exercises the loader's
    # interactive-only blocks; none of them may write to stderr.
    if [[ "${shell}" == "zsh" ]]; then
        if [[ ! -s "${WORK}/${shell}-getter.err" ]]; then
            ok "zsh: an interactive start through the loader writes nothing to stderr"
        else
            fail "zsh: the loader wrote to stderr:"
            cat "${WORK}/${shell}-getter.err"
        fi
    fi

    own="$(run_in_shell "${shell}" 'get-own-functions' 2>/dev/null)"
    if [[ "${own}" == *"OWN-GETTER-MARKER"* ]]; then
        ok "${shell}: a hand-written getter keeps its own body"
    else
        fail "${shell}: the hand-written get-own-functions was replaced (got: ${own})"
    fi
}

check_shell bash

if command -v zsh &>/dev/null; then
    check_shell zsh
else
    skip "zsh is not installed — zsh checks not run (CI installs zsh on ubuntu so it never skips there)"
fi

# ── Last: nothing was ever executed from the unsafe entry. ─────────────────
if [[ ! -e "${PWN}" ]]; then
    ok "the unsafe getter entry's command was never executed"
else
    fail "the unsafe getter entry's command was executed"
fi

# ── _extract_function_names: all three definition forms. ───────────────────
cat > "${WORK}/forms.sh" <<'EOF'
plain-form() { :; }
function keyword-brace {
    :
}
function keyword-parens() { :; }
    function indented-keyword {
        :
    }
function _private-keyword { :; }
EOF
FORMS="$(_extract_function_names "${WORK}/forms.sh" | tr '\n' ' ')"
if [[ "${FORMS}" == "indented-keyword keyword-brace keyword-parens plain-form " ]]; then
    ok "_extract_function_names matches name(), function name {, function name() { and indented forms, and still drops _private"
else
    fail "_extract_function_names returned: '${FORMS}'"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
