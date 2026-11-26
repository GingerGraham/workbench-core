#!/usr/bin/env bash
# tests/check-complete-helper.sh — docs/decisions-log.md D132 acceptance
# check.
#
# workbench_complete (Core API 1.13) turns one provider function into bash
# and zsh tab completion. The bash cases run in bash; the zsh cases run in
# `zsh -f` when zsh is installed, with a temporary HOME and ZDOTDIR so
# compinit writes its dump there, and are skipped otherwise.
# shellcheck disable=SC2016  # the script bodies run_in takes are single-quoted on purpose
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
FUNCTIONS_SH="${REPO_ROOT}/lib/core/functions.sh"
WB="${REPO_ROOT}/bin/wb"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }
skip() { echo "SKIP: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
FAKE_HOME="${WORK}/home"
mkdir -p "${FAKE_HOME}"

expect_eq() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected '$3', got '$2'"; fi
}

# The providers every case shares, written once and sourced by each run.
PROVIDERS="${WORK}/providers.sh"
cat > "${PROVIDERS}" <<'EOF'
_p() {
    if [ "$1" -eq 1 ]; then
        printf '%s\t%s\n' windows "Windows 11 VM" macos "macOS VM"
    fi
}
_q() { :; }
_files_provider() { echo @files; }
_colon_provider() { printf '%s\t%s\n' 'a:b' "has a colon"; }
_record_provider() { printf '%s\n' "$*" > "${RECORD_FILE}"; }
EOF

# run_in <bash|zsh> <script> — runs the script in a clean shell that has
# loaded core's functions.sh and the providers. Prints stdout and stderr.
run_in() {
    local shell="$1" prelude
    prelude="${WORK}/prelude-${shell}.sh"
    {
        printf 'source "%s" >/dev/null 2>&1\n' "${FUNCTIONS_SH}"
        printf 'source "%s"\n' "${PROVIDERS}"
        printf '%s\n' "$2"
    } > "${prelude}"
    env -i HOME="${FAKE_HOME}" ZDOTDIR="${FAKE_HOME}" PATH="${PATH}" TERM=dumb \
        RECORD_FILE="${WORK}/record" WB_ZSH_CACHE="${WORK}/wb.zsh.sh" \
        "$(command -v "${shell}")" -f "${prelude}" 2>&1 </dev/null
}

# ── bash ──────────────────────────────────────────────────────────────────

# 1. Registration.
expect_eq "bash: registration uses complete -o default -F _wb_complete_bash" \
    "$(run_in bash 'workbench_complete _p demo-new demo-import; complete -p demo-new')" \
    "complete -o default -F _wb_complete_bash demo-new"

# 2. Candidates: the prefix filters, and no description reaches COMPREPLY.
expect_eq "bash: 'demo-new ma' completes to macos, without its description" \
    "$(run_in bash 'workbench_complete _p demo-new
COMP_WORDS=(demo-new ma); COMP_CWORD=1; _wb_complete_bash demo-new
printf "%s|" "${COMPREPLY[@]}"')" \
    "macos|"
expect_eq "bash: an empty word gets every candidate" \
    "$(run_in bash 'workbench_complete _p demo-new
COMP_WORDS=(demo-new ""); COMP_CWORD=1; _wb_complete_bash demo-new
printf "%s|" "${COMPREPLY[@]}"')" \
    "windows|macos|"

# 3. @files leaves COMPREPLY empty, so complete -o default lists files.
expect_eq "bash: @files leaves COMPREPLY empty" \
    "$(run_in bash 'workbench_complete _files_provider demo-new
COMP_WORDS=(demo-new ""); COMP_CWORD=1; _wb_complete_bash demo-new
echo "n=${#COMPREPLY[@]}"')" \
    "n=0"

# 4. The provider's arguments: <index> <word0> <word1> ...
rm -f "${WORK}/record"
run_in bash 'workbench_complete _record_provider demo-new
COMP_WORDS=(demo-new --name ""); COMP_CWORD=2; _wb_complete_bash demo-new' >/dev/null
expect_eq "bash: the provider gets '<index> <words...>' (2 demo-new --name '')" \
    "$(cat "${WORK}/record" 2>/dev/null)" "2 demo-new --name "

# 5. Names outside the rule: status 2, nothing registered.
expect_eq "bash: 'bad*cmd' returns 2 and registers nothing" \
    "$(run_in bash 'workbench_complete _p "bad*cmd"; echo "rc=$? [${_WB_COMPLETE_PROVIDERS}]"' | tail -n 1)" \
    "rc=2 []"
expect_eq "bash: an empty command name returns 2 and registers nothing" \
    "$(run_in bash 'workbench_complete _p ""; echo "rc=$? [${_WB_COMPLETE_PROVIDERS}]"' | tail -n 1)" \
    "rc=2 []"
expect_eq "bash: no command at all returns 2" \
    "$(run_in bash 'workbench_complete _p; echo "rc=$? [${_WB_COMPLETE_PROVIDERS}]"' | tail -n 1)" \
    "rc=2 []"

# 6. Re-registration: the last provider wins.
expect_eq "bash: registering demo-new again with _q makes _q its provider" \
    "$(run_in bash 'workbench_complete _p demo-new demo-import; workbench_complete _q demo-new
_wb_complete_provider demo-new; _wb_complete_provider demo-import')" \
    "_q
_p"

# 7. An unregistered command.
expect_eq "bash: an unregistered command returns 0 with COMPREPLY empty" \
    "$(run_in bash 'COMP_WORDS=(nope ""); COMP_CWORD=1; _wb_complete_bash nope; echo "rc=$? n=${#COMPREPLY[@]}"')" \
    "rc=0 n=0"

# ── zsh ───────────────────────────────────────────────────────────────────

if ! command -v zsh >/dev/null 2>&1; then
    skip "zsh is not installed — zsh cases 8 to 11 are skipped"
else
    # 8. Register, a later compinit empties the table, the hook restores it.
    out="$(run_in zsh 'autoload -Uz compinit && compinit -u
workbench_complete _p demo-new demo-import
print -r -- "after-register ${_comps[demo-new]:-} ${_comps[demo-import]:-}"
n=0; for f in "${precmd_functions[@]}"; do [ "$f" = _wb_complete_rearm ] && n=$((n + 1)); done
print -r -- "hooks $n"
compinit -u
print -r -- "after-compinit [${_comps[demo-new]:-}]"
_wb_complete_rearm
print -r -- "after-rearm ${_comps[demo-new]:-} ${_comps[demo-import]:-}"
workbench_complete _q demo-new
n=0; for f in "${precmd_functions[@]}"; do [ "$f" = _wb_complete_rearm ] && n=$((n + 1)); done
print -r -- "hooks-again $n"')"
    expect_eq "zsh: both commands registered to _wb_complete_zsh" \
        "$(printf '%s\n' "${out}" | grep '^after-register')" "after-register _wb_complete_zsh _wb_complete_zsh"
    expect_eq "zsh: the precmd hook is added once" \
        "$(printf '%s\n' "${out}" | grep '^hooks ')" "hooks 1"
    expect_eq "zsh: a later 'compinit -u' empties the registration (so the next check means something)" \
        "$(printf '%s\n' "${out}" | grep '^after-compinit')" "after-compinit []"
    expect_eq "zsh: _wb_complete_rearm restores both commands" \
        "$(printf '%s\n' "${out}" | grep '^after-rearm')" "after-rearm _wb_complete_zsh _wb_complete_zsh"
    expect_eq "zsh: registering again doesn't add the hook twice" \
        "$(printf '%s\n' "${out}" | grep '^hooks-again')" "hooks-again 1"

    # 9. The adapter, with _describe and _files stubbed.
    adapter_prelude='_describe() { local arr="$2"; print -r -- "describe ${(P)arr}"; }
_files() { print -r -- "files called"; }'
    expect_eq "zsh: candidates reach _describe as value:description" \
        "$(run_in zsh "autoload -Uz compinit && compinit -u
workbench_complete _p demo-new
${adapter_prelude}
words=(demo-new '') CURRENT=2 _wb_complete_zsh")" \
        "describe windows:Windows 11 VM macos:macOS VM"
    expect_eq "zsh: a colon in a candidate arrives escaped as \\:" \
        "$(run_in zsh "autoload -Uz compinit && compinit -u
workbench_complete _colon_provider demo-new
${adapter_prelude}
words=(demo-new '') CURRENT=2 _wb_complete_zsh")" \
        'describe a\:b:has a colon'
    expect_eq "zsh: @files calls _files" \
        "$(run_in zsh "autoload -Uz compinit && compinit -u
workbench_complete _files_provider demo-new
${adapter_prelude}
words=(demo-new '') CURRENT=2 _wb_complete_zsh")" \
        "files called"

    # 10. compinit not loaded yet: workbench_complete loads it.
    expect_eq "zsh: without compinit loaded, workbench_complete loads it" \
        "$(run_in zsh 'command -v compdef >/dev/null 2>&1 && print before-yes || print before-no
workbench_complete _p demo-new
command -v compdef >/dev/null 2>&1 && print after-yes || print after-no
print -r -- "${_comps[demo-new]:-}"')" \
        "before-no
after-yes
_wb_complete_zsh"

    # 11. wb's own zsh completion survives a later compinit. The generated
    #     cache is sourced, then the same registration shell/completions/
    #     wb.sh's new block makes.
    if bash "${WB}" completion zsh > "${WORK}/wb.zsh.sh" 2>/dev/null && [[ -s "${WORK}/wb.zsh.sh" ]]; then
        if grep -q 'compdef _wb_completions wb' "${WORK}/wb.zsh.sh"; then
            ok "zsh: the generated wb completion registers _wb_completions"
        else
            fail "zsh: the generated wb completion doesn't register _wb_completions"
        fi
        expect_eq "zsh: wb's completion is restored after a later compinit" \
            "$(run_in zsh 'autoload -Uz compinit && compinit -u
source "${WB_ZSH_CACHE}"
if command -v _wb_complete_zsh_register >/dev/null 2>&1; then
    _wb_complete_zsh_register _wb_completions wb
fi
print -r -- "registered ${_comps[wb]:-}"
compinit -u
print -r -- "after-compinit [${_comps[wb]:-}]"
_wb_complete_rearm
print -r -- "restored ${_comps[wb]:-}"')" \
            "registered _wb_completions
after-compinit []
restored _wb_completions"
        if grep -q '_wb_complete_zsh_register _wb_completions wb' "${REPO_ROOT}/shell/completions/wb.sh"; then
            ok "shell/completions/wb.sh registers wb through _wb_complete_zsh_register"
        else
            fail "shell/completions/wb.sh doesn't register wb through _wb_complete_zsh_register"
        fi
    else
        fail "zsh: 'wb completion zsh' produced no output"
    fi
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks failed."
exit 1
