#!/usr/bin/env bash
# tests/check-no-bare-alias.sh — docs/decisions-log.md D124 guard.
#
# Workbench never replaces an alias or function it did not define. A name is
# claimed only through workbench_alias_define (Core API 1.10), which yields
# to an existing definition and records the clash. A bare `alias name=...`
# in sourced code replaces whatever was there, and as a side effect makes a
# host's later `name() {` fail to parse, because bash expands an alias when
# a line is read.
#
# This guard fails on any line that defines an alias without going through
# the helper. To allow a line on purpose, end it with:   # wb-allow-bare-alias
# (the helper's own body does, since it is the one place that may.)
#
# Not flagged: a query (`alias name`, `alias -p`), `unalias`, comment lines,
# and the word "alias" inside text.
#
# Bash 3.2 compatible: plain grep -E, no features beyond that.
set -uo pipefail

SCRIPT_DIR="$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(builtin cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

# Directories and files to scan. Override with CHECK_NO_BARE_ALIAS_PATHS
# (space separated, relative to the repo root).
SCAN_PATHS="${CHECK_NO_BARE_ALIAS_PATHS:-bin lib bootstrap.sh shell hooks}"

# A command word: at the start of a line, or after a command separator, an
# opening paren or brace, a command substitution, or a shell keyword. A
# leading `builtin` or `command` does not hide the call.
COMMAND_START='(^|[;&|(){`]|\$\(|(^|[[:space:]])(then|do|else|if|while|until))[[:space:]]*((builtin|command)[[:space:]]+)?'

# A definition: `alias`, optional `--`, then a token ending in `=`. The token
# may be quoted or a variable (`alias "${name}=..."`), so anything without
# whitespace up to the `=` counts. `alias name` and `alias -p` have no `=`.
ALIAS_DEFINITION='alias[[:space:]]+(--[[:space:]]+)?[^[:space:];&|()=]*='

# bare_hits — print "file:line:text" for every alias definition that does
# not carry the escape hatch, skipping comment-only lines.
bare_hits() {
    local path
    for path in ${SCAN_PATHS}; do
        [[ -e "${REPO_ROOT}/${path}" ]] || continue
        ( builtin cd -- "${REPO_ROOT}" && \
            grep -rnE "${COMMAND_START}${ALIAS_DEFINITION}" "${path}" 2>/dev/null )
    done | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v '# wb-allow-bare-alias'
}

hits="$(bare_hits)"
if [[ -z "${hits}" ]]; then
    ok "no bare 'alias name=...' in sourced code — every alias goes through workbench_alias_define"
else
    fail "bare alias definition found; use workbench_alias_define <name> <module> <value> (or end the line with '# wb-allow-bare-alias'):"
    printf '%s\n' "${hits}"
fi

# ── The guard has to see what it claims to see. ─────────────────────────────
SELF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wb-no-bare-alias.XXXXXX")"
trap 'rm -rf "${SELF_DIR}"' EXIT
mkdir -p "${SELF_DIR}/shell"
cat > "${SELF_DIR}/shell/sample.sh" <<'SAMPLE_EOF'
alias gd="git diff"
if true; then alias a=b; fi
true && alias c=d
builtin alias e=f
alias -- g=h
alias "${name}=${value}"
workbench_alias_define gd git "git diff"
alias gd
alias -p
unalias gd
allowed() { alias z=y; }  # wb-allow-bare-alias
# alias in a comment: alias k=l
echo "an alias is a shortcut"
SAMPLE_EOF
REPO_ROOT="${SELF_DIR}" SCAN_PATHS="shell"
self_hits="$(bare_hits | wc -l | tr -d ' ')"
if [[ "${self_hits}" -eq 6 ]]; then
    ok "self-test: flags bare, 'then', '&&', 'builtin', '--' and variable-name definitions; accepts the helper, queries, unalias, comments, text and the escape hatch"
else
    fail "self-test: expected 6 flagged lines in the sample, got ${self_hits}"
    bare_hits
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
