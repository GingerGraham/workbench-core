#!/usr/bin/env bash
# tests/check-no-bare-cd.sh — docs/decisions-log.md D110 guard.
#
# An alias is expanded when a line is READ, and a function body is read
# when the function is DEFINED. So an alias that exists when workbench's
# files are sourced is baked into every function those files define, and
# stays baked in after the alias is removed. Workbench loads from the rc
# file, after the host profile has defined its aliases, so a bare `cd` or
# `ls` in sourced code runs whatever the host aliased it to (zoxide's `z`,
# `eza`, ...).
#
# This guard fails on any `cd` that is not `builtin cd` and any `ls` that
# is not `command ls`, in code that gets sourced or run on the user's
# behalf. To allow a line on purpose, end it with:   # wb-allow-bare
#
# Bash 3.2 compatible: plain grep -E, no features beyond that.
set -uo pipefail

SCRIPT_DIR="$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(builtin cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

# Directories and files to scan. Override with CHECK_NO_BARE_PATHS (space
# separated, relative to the repo root).
SCAN_PATHS="${CHECK_NO_BARE_PATHS:-bin lib bootstrap.sh shell hooks}"

# A command word: at the start of a line, or after a command separator, an
# opening paren or brace, a command substitution, or a shell keyword.
COMMAND_START='(^|[;&|(){`]|\$\(|(^|[[:space:]])(then|do|else|if|while|until))[[:space:]]*'

# What may follow the command word: whitespace, the end of the line, or a
# character that ends a command or closes a group, so `cd;`, `(cd)`,
# `cd&&pwd`, `ls|head` and `$(ls)` are seen too.
COMMAND_END='([[:space:]]|$|[;&|)<>])'

# bare_hits <command-name> — print "file:line:text" for every command-word
# use of <command-name> that is not an allowed form, skipping comment-only
# lines and lines carrying the escape hatch.
bare_hits() {
    local name="$1" path
    for path in ${SCAN_PATHS}; do
        [[ -e "${REPO_ROOT}/${path}" ]] || continue
        ( builtin cd -- "${REPO_ROOT}" && \
            grep -rnE "${COMMAND_START}${name}${COMMAND_END}" "${path}" 2>/dev/null )
    done | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v '# wb-allow-bare'
}

cd_hits="$(bare_hits cd)"
if [[ -z "${cd_hits}" ]]; then
    ok "no bare 'cd' in sourced code — every call is 'builtin cd'"
else
    fail "bare 'cd' found; write 'builtin cd' (or end the line with '# wb-allow-bare'):"
    printf '%s\n' "${cd_hits}"
fi

ls_hits="$(bare_hits ls)"
if [[ -z "${ls_hits}" ]]; then
    ok "no bare 'ls' in sourced code — every call is 'command ls', or the call is gone"
else
    fail "bare 'ls' found; write 'command ls' or drop the call (or end the line with '# wb-allow-bare'):"
    printf '%s\n' "${ls_hits}"
fi

# ── The guard has to see what it claims to see. ─────────────────────────────
# A scanner that matches nothing passes forever, so prove it matches a bare
# call and accepts the allowed forms and the escape hatch.
SELF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wb-no-bare-cd.XXXXXX")"
trap 'rm -rf "${SELF_DIR}"' EXIT
mkdir -p "${SELF_DIR}/lib"
cat > "${SELF_DIR}/lib/sample.sh" <<'SAMPLE_EOF'
here="$(cd -- "$(dirname -- "$0")" && pwd)"
if cd /tmp; then :; fi
list() { ls "$1"; }
ok_cd="$(builtin cd -- /tmp && pwd)"
ok_ls() { command ls "$1"; }
allowed() { cd /tmp; }  # wb-allow-bare
joined() { cd;pwd; }
grouped() { (cd); }
piped() { ls|head -1; }
captured() { local x; x=$(ls); }
# cd in a comment is ignored
SAMPLE_EOF
REPO_ROOT="${SELF_DIR}" SCAN_PATHS="lib"
self_cd="$(bare_hits cd | wc -l | tr -d ' ')"
self_ls="$(bare_hits ls | wc -l | tr -d ' ')"
if [[ "${self_cd}" -eq 4 && "${self_ls}" -eq 3 ]]; then
    ok "self-test: the scanner flags bare cd/ls, and accepts builtin cd, command ls, comments and the escape hatch"
else
    fail "self-test: expected 4 bare cd and 3 bare ls in the sample, got cd=${self_cd} ls=${self_ls}"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
