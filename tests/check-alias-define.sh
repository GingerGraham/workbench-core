#!/usr/bin/env bash
# tests/check-alias-define.sh — docs/decisions-log.md D124 acceptance check.
#
# workbench_alias_define defines an alias only when the name is free:
#   free     = we defined it earlier in this shell (a reload refreshes it),
#              nothing of that name exists, or an alias exists whose
#              definition is identical to what we would set.
#   not free = a function of that name exists, or a different alias does.
# A name that is not free is recorded as a clash and left alone.
#
# The reported incident: a host profile defines a function `gd() {`;
# workbench defined `alias gd="git diff"`; re-sourcing the host's file
# (`bashsource`) then failed with "syntax error near unexpected token `('",
# because bash expands an alias when a line is read, including the name in
# a function definition. Case 5 reproduces that sequence, shows it failing
# with the old pattern, and shows it working with the helper.
#
# Fixtures that define aliases are separate files: a one-line `bash -c`
# string does not expand them. Every run is `env -i` with a fake HOME.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
FUNCTIONS_SH="${REPO_ROOT}/lib/core/functions.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }
skip() { echo "SKIP: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
FAKE_HOME="${WORK}/home"
mkdir -p "${FAKE_HOME}"

# run_case <bash|zsh> <script-file> — runs the script in a clean shell that
# has already loaded core's functions.sh. Prints the script's own output.
run_case() {
    local shell="$1" script="$2" prelude
    prelude="${WORK}/prelude-${shell}.sh"
    if [[ "${shell}" == "bash" ]]; then
        printf 'shopt -s expand_aliases\nsource "%s" >/dev/null 2>&1\nsource "%s"\n' "${FUNCTIONS_SH}" "${script}" > "${prelude}"
    else
        printf 'source "%s" >/dev/null 2>&1\nsource "%s"\n' "${FUNCTIONS_SH}" "${script}" > "${prelude}"
    fi
    env -i HOME="${FAKE_HOME}" PATH="/usr/local/bin:/usr/bin:/bin" TERM=dumb \
        "${shell}" -f "${prelude}" 2>&1 </dev/null
}

# The host's own definitions live in fixture files, sourced one line at a
# time, the way a real profile would define them.
cat > "${WORK}/host-alias.sh" <<'EOF'
alias hostdiff='git diff --stat'
alias same-as-ours='git status'
EOF
cat > "${WORK}/host-function.sh" <<'EOF'
gd() {
    echo "host gd function"
}
EOF

# ── The cases, written once and run in each shell. ──────────────────────────
write_cases() {
    # 1. Nothing exists.
    cat > "${WORK}/case1.sh" <<'EOF'
workbench_alias_define fresh-name git "git status"
echo "RC=$?"
alias fresh-name
workbench_alias_is_ours fresh-name && echo "OURS=yes" || echo "OURS=no"
echo "CLASHES=[${WORKBENCH_ALIAS_CLASHES}]"
EOF
    # 2. A different alias is already there.
    cat > "${WORK}/case2.sh" <<EOF
source "${WORK}/host-alias.sh"
workbench_alias_define hostdiff git "git diff"
echo "RC=\$?"
alias hostdiff
workbench_alias_is_ours hostdiff && echo "OURS=yes" || echo "OURS=no"
printf 'CLASHES=[%s]\n' "\${WORKBENCH_ALIAS_CLASHES}"
EOF
    # 3. An identical alias is already there.
    cat > "${WORK}/case3.sh" <<EOF
source "${WORK}/host-alias.sh"
workbench_alias_define same-as-ours git "git status"
echo "RC=\$?"
workbench_alias_is_ours same-as-ours && echo "OURS=yes" || echo "OURS=no"
echo "CLASHES=[\${WORKBENCH_ALIAS_CLASHES}]"
EOF
    # 4. A function is already there; the alias must not be defined.
    cat > "${WORK}/case4.sh" <<EOF
source "${WORK}/host-function.sh"
workbench_alias_define gd git "git diff"
echo "RC=\$?"
alias gd 2>/dev/null && echo "ALIAS-DEFINED" || echo "NO-ALIAS"
type gd | head -n 1
printf 'CLASHES=[%s]\n' "\${WORKBENCH_ALIAS_CLASHES}"
EOF
    # 5. The reported sequence. Host first (a fresh shell), then workbench,
    #    then the host's file again, twice (bashsource).
    cat > "${WORK}/case5-new.sh" <<EOF
source "${WORK}/host-function.sh"
workbench_alias_define gd git "git diff"
source "${WORK}/host-function.sh"; echo "RESOURCE-1 rc=\$?"
source "${WORK}/host-function.sh"; echo "RESOURCE-2 rc=\$?"
type gd | head -n 1
gd
EOF
    # 5 control. The old pattern: a bare alias.
    cat > "${WORK}/case5-old.sh" <<EOF
source "${WORK}/host-function.sh"
alias gd="git diff"
source "${WORK}/host-function.sh"; echo "RESOURCE-1 rc=\$?"
EOF
    # 5 limitation. A shell that already holds workbench's alias from before
    #    the update. The helper cannot remove it.
    cat > "${WORK}/case5-stale.sh" <<EOF
alias gd="git diff"
source "${WORK}/host-function.sh"; echo "STALE-RESOURCE rc=\$?"
unalias gd
source "${WORK}/host-function.sh"; echo "AFTER-UNALIAS rc=\$?"
type gd | head -n 1
EOF
    # 6. A reload refreshes our own alias and reports no clash.
    cat > "${WORK}/case6.sh" <<'EOF'
workbench_alias_define reloaded git "git status"
workbench_alias_define reloaded git "git status --short"
echo "RC=$?"
alias reloaded
echo "CLASHES=[${WORKBENCH_ALIAS_CLASHES}]"
EOF
    # 7. In-place upgrade: the shell holds the OLD workbench's alias (plain,
    #    same value). Not a clash.
    cat > "${WORK}/case7.sh" <<'EOF'
alias upgraded="git status"
workbench_alias_define upgraded git "git status"
echo "RC=$?"
workbench_alias_is_ours upgraded && echo "OURS=yes" || echo "OURS=no"
echo "CLASHES=[${WORKBENCH_ALIAS_CLASHES}]"
EOF
    # 8. Awkward names.
    cat > "${WORK}/case8.sh" <<'EOF'
workbench_alias_define .. git "cd .."
echo "RC1=$?"
workbench_alias_define git-remove-untracked git "git clean -fd"
echo "RC2=$?"
alias ..
alias git-remove-untracked
workbench_alias_is_ours .. && echo "OURS1=yes" || echo "OURS1=no"
workbench_alias_is_ours git-remove-untracked && echo "OURS2=yes" || echo "OURS2=no"
workbench_alias_is_ours git && echo "PREFIX-MATCH" || echo "NO-PREFIX-MATCH"
EOF
    # A value with "|" and a quote survives, and is recorded last.
    cat > "${WORK}/case9.sh" <<EOF
source "${WORK}/host-alias.sh"
workbench_alias_define hostdiff git "git log | head -n 5"
printf 'CLASHES=[%s]\n' "\${WORKBENCH_ALIAS_CLASHES}"
EOF
}
write_cases

# ═══════════════════════════════════════════════════════════════════════════
# Cases 1–8, in bash and in zsh
# ═══════════════════════════════════════════════════════════════════════════
check_shell() {
    local shell="$1" out

    out="$(run_case "${shell}" "${WORK}/case1.sh")"
    if grep -q '^RC=0$' <<<"${out}" && grep -q "fresh-name='git status'" <<<"${out}" \
        && grep -q '^OURS=yes$' <<<"${out}" && grep -q '^CLASHES=\[\]$' <<<"${out}"; then
        ok "${shell}: nothing exists — defined, value correct, listed as ours, no clash"
    else
        fail "${shell}: nothing exists"; printf '%s\n' "${out}"
    fi

    out="$(run_case "${shell}" "${WORK}/case2.sh")"
    if grep -q '^RC=1$' <<<"${out}" && grep -q "hostdiff='git diff --stat'" <<<"${out}" \
        && grep -q '^OURS=no$' <<<"${out}" && grep -q 'hostdiff|git|alias|git diff' <<<"${out}"; then
        ok "${shell}: a different alias exists — left untouched, one clash recorded with kind alias"
    else
        fail "${shell}: a different alias exists"; printf '%s\n' "${out}"
    fi

    out="$(run_case "${shell}" "${WORK}/case3.sh")"
    if grep -q '^RC=0$' <<<"${out}" && grep -q '^OURS=yes$' <<<"${out}" && grep -q '^CLASHES=\[\]$' <<<"${out}"; then
        ok "${shell}: an identical alias exists — treated as ours, no clash"
    else
        fail "${shell}: an identical alias exists"; printf '%s\n' "${out}"
    fi

    out="$(run_case "${shell}" "${WORK}/case4.sh")"
    if grep -q '^RC=1$' <<<"${out}" && grep -q '^NO-ALIAS$' <<<"${out}" \
        && grep -q 'gd is a .*function' <<<"${out}" && grep -q 'gd|git|function|git diff' <<<"${out}"; then
        ok "${shell}: a function exists — alias not defined, function intact, one clash recorded with kind function"
    else
        fail "${shell}: a function exists"; printf '%s\n' "${out}"
    fi

    # 5. The reported sequence.
    out="$(run_case "${shell}" "${WORK}/case5-old.sh")"
    if grep -q 'syntax error\|parse error\|defining function based on alias' <<<"${out}"; then
        ok "${shell}: CONTROL — the old pattern (bare alias, then the host's file again) fails exactly as reported"
    else
        fail "${shell}: CONTROL — expected the old pattern to fail on re-source"; printf '%s\n' "${out}"
    fi
    out="$(run_case "${shell}" "${WORK}/case5-new.sh")"
    if grep -q 'RESOURCE-1 rc=0' <<<"${out}" && grep -q 'RESOURCE-2 rc=0' <<<"${out}" \
        && grep -q 'gd is a .*function' <<<"${out}" && grep -q '^host gd function$' <<<"${out}" \
        && ! grep -qi 'syntax error\|parse error' <<<"${out}"; then
        ok "${shell}: the reported sequence — host file re-sourced twice after workbench loaded: no error, gd is still the host's function"
    else
        fail "${shell}: the reported sequence"; printf '%s\n' "${out}"
    fi

    out="$(run_case "${shell}" "${WORK}/case5-stale.sh")"
    if grep -q 'syntax error\|parse error\|defining function based on alias' <<<"${out}" \
        && grep -q 'AFTER-UNALIAS rc=0' <<<"${out}" && grep -q 'gd is a .*function' <<<"${out}"; then
        ok "${shell}: known limitation — a shell that already holds the alias still fails on re-source until 'unalias gd' (a new terminal also fixes it)"
    else
        fail "${shell}: the stale-shell limitation did not behave as documented"; printf '%s\n' "${out}"
    fi

    out="$(run_case "${shell}" "${WORK}/case6.sh")"
    if grep -q '^RC=0$' <<<"${out}" && grep -q "reloaded='git status --short'" <<<"${out}" && grep -q '^CLASHES=\[\]$' <<<"${out}"; then
        ok "${shell}: reload — our alias is refreshed with the new value and is not reported as a clash"
    else
        fail "${shell}: reload"; printf '%s\n' "${out}"
    fi

    out="$(run_case "${shell}" "${WORK}/case7.sh")"
    if grep -q '^RC=0$' <<<"${out}" && grep -q '^OURS=yes$' <<<"${out}" && grep -q '^CLASHES=\[\]$' <<<"${out}"; then
        ok "${shell}: in-place upgrade — an old workbench alias with an unchanged value is identical, not a clash"
    else
        fail "${shell}: in-place upgrade"; printf '%s\n' "${out}"
    fi

    out="$(run_case "${shell}" "${WORK}/case8.sh")"
    if grep -q '^RC1=0$' <<<"${out}" && grep -q '^RC2=0$' <<<"${out}" \
        && grep -q '^OURS1=yes$' <<<"${out}" && grep -q '^OURS2=yes$' <<<"${out}" \
        && grep -q '^NO-PREFIX-MATCH$' <<<"${out}"; then
        ok "${shell}: names '..' and 'git-remove-untracked' are handled, and 'git' is not matched by 'git-remove-untracked'"
    else
        fail "${shell}: awkward names"; printf '%s\n' "${out}"
    fi

    out="$(run_case "${shell}" "${WORK}/case9.sh")"
    if grep -qF 'CLASHES=[hostdiff|git|alias|git log | head -n 5' <<<"${out}"; then
        ok "${shell}: a value containing '|' is recorded whole (it is the last field)"
    else
        fail "${shell}: value with a pipe"; printf '%s\n' "${out}"
    fi
}

check_shell bash
if command -v zsh >/dev/null 2>&1; then
    check_shell zsh
else
    skip "zsh is not installed — the zsh cases were not run"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Plain host: no foreign state, so the helper changes nothing a bare alias
# would not have. Aliases, functions and exported environment compare equal.
# ═══════════════════════════════════════════════════════════════════════════
cat > "${WORK}/twin-bare.sh" <<'EOF'
alias gst="git status"
alias gd="git diff"
alias gitkeep='find . -type d -empty -exec touch {}/.gitkeep \;'
alias ..="cd .."
EOF
cat > "${WORK}/twin-helper.sh" <<'EOF'
workbench_alias_define gst git "git status"
workbench_alias_define gd git "git diff"
workbench_alias_define gitkeep git 'find . -type d -empty -exec touch {}/.gitkeep \;'
workbench_alias_define .. git "cd .."
EOF
cat > "${WORK}/twin-snapshot.sh" <<'EOF'
{
    echo "## aliases";  alias | sort
    echo "## functions"; declare -F | sed 's/^declare -f //' | sort
    echo "## exported env"; env | grep -v '^_=' | sort
} > "$SNAPSHOT_OUT"
EOF
twin_run() {
    local variant="$1" out="$2"
    printf 'shopt -s expand_aliases\nsource "%s" >/dev/null 2>&1\nsource "%s"\nSNAPSHOT_OUT="%s"\nsource "%s"\n' \
        "${FUNCTIONS_SH}" "${WORK}/twin-${variant}.sh" "${out}" "${WORK}/twin-snapshot.sh" > "${WORK}/twin-${variant}-run.sh"
    env -i HOME="${FAKE_HOME}" PATH="/usr/local/bin:/usr/bin:/bin" TERM=dumb \
        bash --noprofile --norc "${WORK}/twin-${variant}-run.sh" >/dev/null 2>&1 </dev/null
}
twin_run bare "${WORK}/twin-bare.txt"
twin_run helper "${WORK}/twin-helper.txt"
if [[ -s "${WORK}/twin-bare.txt" ]] && diff -u "${WORK}/twin-bare.txt" "${WORK}/twin-helper.txt" >"${WORK}/twin.diff"; then
    ok "plain host: aliases, functions and exported environment are identical to what bare 'alias' lines produce"
else
    fail "plain host: the helper changed shell state a bare alias would not have"
    cat "${WORK}/twin.diff"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks failed."
exit 1
