#!/usr/bin/env bash
# tests/check-wb-functions-pager.sh — docs/decisions-log.md D72, D111.
#
# _wb_resolve_pager's decision logic is tested directly, without a real
# terminal (it never touches one). _wb_maybe_page's own tty gate is tested
# through the one thing that's actually observable without a pty: any
# command substitution $(...) is never a tty, so every call below
# exercises the exact "stdout isn't a terminal" passthrough path every
# real caller (wb functions | grep, wb functions > file.txt, an existing
# test capturing `wb functions` output) already relies on.
# shellcheck disable=SC2034  # PAGER / WORKBENCH_PAGER are read by
# _wb_resolve_pager, which shellcheck can't see from here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

# shellcheck source=lib/core/log.sh
source "${REPO_ROOT}/lib/core/log.sh"
# shellcheck source=lib/core/version.sh
source "${REPO_ROOT}/lib/core/version.sh"
# shellcheck source=lib/core/pager.sh
source "${REPO_ROOT}/lib/core/pager.sh"

# ── _wb_resolve_pager (D111) ────────────────────────────────────────────────
unset WORKBENCH_PAGER PAGER 2>/dev/null || true

out="$(_wb_resolve_pager)"
# shellcheck disable=SC2015
[[ "${out}" == "builtin" ]] \
    && ok "builtin pager is the default when WORKBENCH_PAGER is unset" \
    || fail "expected default 'builtin', got '${out}'"

PAGER="less"
out="$(_wb_resolve_pager)"
# shellcheck disable=SC2015
[[ "${out}" == "builtin" ]] \
    && ok "PAGER is ignored (workbench-shell exports PAGER=less)" \
    || fail "PAGER should be ignored, got '${out}'"
unset PAGER

WORKBENCH_PAGER="builtin"
out="$(_wb_resolve_pager)"
# shellcheck disable=SC2015
[[ "${out}" == "builtin" ]] \
    && ok "WORKBENCH_PAGER=builtin selects the builtin pager" \
    || fail "WORKBENCH_PAGER=builtin, got '${out}'"

WORKBENCH_PAGER="less -FRX"
out="$(_wb_resolve_pager)"
# shellcheck disable=SC2015
[[ "${out}" == "less -FRX" ]] \
    && ok "WORKBENCH_PAGER (multi-word) used verbatim" \
    || fail "WORKBENCH_PAGER not honoured verbatim, got '${out}'"

for disable_val in "" "cat" "none"; do
    WORKBENCH_PAGER="${disable_val}"
    out="$(_wb_resolve_pager)"
    # shellcheck disable=SC2015
    [[ -z "${out}" ]] \
        && ok "WORKBENCH_PAGER='${disable_val}' disables paging" \
        || fail "WORKBENCH_PAGER='${disable_val}' should disable paging, got '${out}'"
done
unset WORKBENCH_PAGER

# ── _wb_builtin_pager, driven without a terminal ────────────────────────────
# _WB_PAGER_SIZE fixes the terminal size; _WB_PAGER_INPUT is a file of
# key presses read in order.
_gen_lines() {
    local _i=1
    while [[ "${_i}" -le "$1" ]]; do
        printf '\033[1mline\033[0m %d\n' "${_i}"
        _i=$((_i + 1))
    done
}
# The pager erases its prompt with \r ESC[K, so the next line lands on
# the prompt's row. Turn \r into a newline so each prompt and each
# output line can be counted on its own.
# ESC is passed in with $'...' because BSD/macOS sed has no \x1b escape.
_strip() { tr '\r' '\n' | sed $'s/\033\\[[0-9;]*[mK]//g'; }
_KEYS="$(mktemp)"
_PROMPT='-- [0-9]*% --'

: > "${_KEYS}"
out="$(_gen_lines 5 | _WB_PAGER_SIZE="10 80" _WB_PAGER_INPUT="${_KEYS}" _wb_builtin_pager | _strip)"
# shellcheck disable=SC2015
[[ "$(printf '%s\n' "${out}" | grep -c -e "${_PROMPT}")" -eq 0 ]] && [[ "$(printf '%s\n' "${out}" | grep -c '^line ')" -eq 5 ]] \
    && ok "output that fits on one screen prints with no prompt" \
    || fail "short output: expected 5 lines and no prompt, got: ${out}"

printf 'q' > "${_KEYS}"
out="$(_gen_lines 25 | _WB_PAGER_SIZE="10 80" _WB_PAGER_INPUT="${_KEYS}" _wb_builtin_pager | _strip)"
# shellcheck disable=SC2015
[[ "$(printf '%s\n' "${out}" | grep -c '^line ')" -eq 9 ]] \
    && ok "first page is rows-1 lines; q stops there" \
    || fail "expected 9 lines before q, got: ${out}"

printf ' \nq' > "${_KEYS}"
out="$(_gen_lines 25 | _WB_PAGER_SIZE="10 80" _WB_PAGER_INPUT="${_KEYS}" _wb_builtin_pager | _strip)"
# shellcheck disable=SC2015
[[ "$(printf '%s\n' "${out}" | grep -c '^line ')" -eq 19 ]] \
    && ok "space = one more page, enter = one more line" \
    || fail "expected 9 + 9 + 1 = 19 lines, got: ${out}"

printf 'a' > "${_KEYS}"
out="$(_gen_lines 25 | _WB_PAGER_SIZE="10 80" _WB_PAGER_INPUT="${_KEYS}" _wb_builtin_pager | _strip)"
# shellcheck disable=SC2015
[[ "$(printf '%s\n' "${out}" | grep -c '^line ')" -eq 25 ]] && [[ "$(printf '%s\n' "${out}" | grep -c -e "${_PROMPT}")" -eq 1 ]] \
    && ok "a prints the rest with no further prompts" \
    || fail "expected all 25 lines and one prompt, got: ${out}"

printf '\033[Bq' > "${_KEYS}"
out="$(_gen_lines 25 | _WB_PAGER_SIZE="10 80" _WB_PAGER_INPUT="${_KEYS}" _wb_builtin_pager | _strip)"
# shellcheck disable=SC2015
[[ "$(printf '%s\n' "${out}" | grep -c '^line ')" -eq 10 ]] \
    && ok "down-arrow escape sequence = one line, leftover bytes not read as keys" \
    || fail "expected 10 lines after down-arrow, got: ${out}"

printf '\033[6~q' > "${_KEYS}"
out="$(_gen_lines 25 | _WB_PAGER_SIZE="10 80" _WB_PAGER_INPUT="${_KEYS}" _wb_builtin_pager | _strip)"
# shellcheck disable=SC2015
[[ "$(printf '%s\n' "${out}" | grep -c '^line ')" -eq 18 ]] \
    && ok "PgDn escape sequence = one page" \
    || fail "expected 18 lines after PgDn, got: ${out}"

: > "${_KEYS}"
out="$(_gen_lines 25 | _WB_PAGER_SIZE="10 80" _WB_PAGER_INPUT="${_KEYS}" _wb_builtin_pager | _strip)"
# shellcheck disable=SC2015
[[ "$(printf '%s\n' "${out}" | grep -c '^line ')" -eq 9 ]] \
    && ok "end of key input stops paging (treated as q)" \
    || fail "expected 9 lines when keys run out, got: ${out}"

out="$(_gen_lines 25 | _WB_PAGER_SIZE="10 80" _WB_PAGER_INPUT="/nonexistent/tty" _wb_builtin_pager | _strip)"
# shellcheck disable=SC2015
[[ "$(printf '%s\n' "${out}" | grep -c '^line ')" -eq 25 ]] && [[ "$(printf '%s\n' "${out}" | grep -c -e "${_PROMPT}")" -eq 0 ]] \
    && ok "unreadable key source prints everything, no prompt, nothing lost" \
    || fail "expected all 25 lines with no prompt, got: ${out}"

_long="$(printf 'x%.0s' $(seq 200))"
: > "${_KEYS}"
out="$(printf '%s\n%s\n%s\n' "${_long}" "${_long}" "${_long}" | _WB_PAGER_SIZE="10 80" _WB_PAGER_INPUT="${_KEYS}" _wb_builtin_pager | _strip)"
# shellcheck disable=SC2015
[[ "$(printf '%s\n' "${out}" | grep -c -e "${_PROMPT}")" -eq 0 ]] \
    && ok "wrapped lines counted as screen rows: 3 x 200 chars on 80 cols = 9 rows, fits" \
    || fail "3 wrapped lines should fit a 10-row screen"

out="$(printf '%s\n%s\n%s\n%s\n' "${_long}" "${_long}" "${_long}" "${_long}" | _WB_PAGER_SIZE="10 80" _WB_PAGER_INPUT="${_KEYS}" _wb_builtin_pager | _strip)"
# shellcheck disable=SC2015
[[ "$(printf '%s\n' "${out}" | grep -c -e "${_PROMPT}")" -eq 1 ]] \
    && ok "4 wrapped lines (12 rows) exceed a 10-row screen and prompt" \
    || fail "4 wrapped lines should trigger a prompt"

# Tab-indented lines (gitconfig in the install diff view): 2 tabs + 70
# chars displays wider than 80 columns, so each line takes 2 rows and
# 9 of them cannot fit a 10-row screen. Counting a tab as 1 character
# would print all 9 with no prompt and scroll the top ones off.
_tabbed="$(printf '\t\t%070d' 0)"
out="$(for _i in 1 2 3 4 5 6 7 8 9; do printf '%s\n' "${_tabbed}"; done | _WB_PAGER_SIZE="10 80" _WB_PAGER_INPUT="${_KEYS}" _wb_builtin_pager | _strip)"
# shellcheck disable=SC2015
[[ "$(printf '%s\n' "${out}" | grep -c -e "${_PROMPT}")" -eq 1 ]] \
    && ok "tabs counted as 8 columns: wide tab-indented lines trigger a prompt" \
    || fail "tab-indented lines wider than the screen should trigger a prompt"

out="$(printf '' | _WB_PAGER_SIZE="10 80" _WB_PAGER_INPUT="${_KEYS}" _wb_builtin_pager)"
# shellcheck disable=SC2015
[[ -z "${out}" ]] \
    && ok "empty input prints nothing (no unbound-array error under set -u)" \
    || fail "empty input should print nothing, got '${out}'"

rm -f "${_KEYS}"

# ── _wb_maybe_page: never pages when stdout isn't a terminal ────────────────
# WORKBENCH_PAGER is set to a command that would fail/hang/produce
# nothing if it were actually invoked — proving the tty check
# short-circuits before the resolved pager value is ever used, not just
# that _wb_resolve_pager itself behaves correctly in isolation.
WORKBENCH_PAGER="false"
out="$(printf 'line one\nline two\n' | _wb_maybe_page)"
# shellcheck disable=SC2015
[[ "${out}" == "$(printf 'line one\nline two')" ]] \
    && ok "_wb_maybe_page passes input through unchanged when stdout is not a terminal" \
    || fail "_wb_maybe_page altered or lost output under a non-tty stdout"
unset WORKBENCH_PAGER

# Default (WORKBENCH_PAGER unset) resolves to the built-in pager, which
# would read /dev/tty if reached. Same non-tty gate must short-circuit it.
out="$(printf 'line one\nline two\n' | _wb_maybe_page)"
# shellcheck disable=SC2015
[[ "${out}" == "$(printf 'line one\nline two')" ]] \
    && ok "_wb_maybe_page passes input through unchanged with WORKBENCH_PAGER unset (builtin never reached)" \
    || fail "_wb_maybe_page altered output under a non-tty stdout with the default pager"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
