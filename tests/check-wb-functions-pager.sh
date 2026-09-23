#!/usr/bin/env bash
# tests/check-wb-functions-pager.sh — docs/decisions-log.md D72.
#
# _wb_resolve_pager's decision logic is tested directly, without a real
# terminal (it never touches one). _wb_maybe_page's own tty gate is tested
# through the one thing that's actually observable without a pty: any
# command substitution $(...) is never a tty, so every call below
# exercises the exact "stdout isn't a terminal" passthrough path every
# real caller (wb functions | grep, wb functions > file.txt, an existing
# test capturing `wb functions` output) already relies on.
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

# ── _wb_resolve_pager: WORKBENCH_PAGER wins outright, verbatim ─────────────
unset WORKBENCH_PAGER PAGER 2>/dev/null || true

WORKBENCH_PAGER="most --wrap"
out="$(_wb_resolve_pager)"
[[ "${out}" == "most --wrap" ]] \
    && ok "WORKBENCH_PAGER (multi-word) wins outright, used verbatim" \
    || fail "WORKBENCH_PAGER not honoured verbatim, got '${out}'"
unset WORKBENCH_PAGER

# ── Explicit disable forms never fall through to PAGER ──────────────────────
PAGER="should-never-be-used"
for disable_val in "" "cat" "none"; do
    WORKBENCH_PAGER="${disable_val}"
    out="$(_wb_resolve_pager)"
    [[ -z "${out}" ]] \
        && ok "WORKBENCH_PAGER='${disable_val}' disables paging (empty result, not PAGER)" \
        || fail "WORKBENCH_PAGER='${disable_val}' should disable paging, got '${out}'"
done
unset WORKBENCH_PAGER PAGER

# ── PAGER fallback when WORKBENCH_PAGER is unset ────────────────────────────
PAGER="bat --paging=always"
out="$(_wb_resolve_pager)"
[[ "${out}" == "bat --paging=always" ]] \
    && ok "PAGER used verbatim when WORKBENCH_PAGER is unset" \
    || fail "PAGER fallback not honoured, got '${out}'"
unset PAGER

# ── less default when neither is set ─────────────────────────────────────────
if command -v less &>/dev/null; then
    out="$(_wb_resolve_pager)"
    [[ "${out}" == "less -F -R -X" ]] \
        && ok "bare 'less -F -R -X' picked as the default when nothing else is configured" \
        || fail "expected default 'less -F -R -X', got '${out}'"
else
    echo "SKIP: less not installed in this environment — default-pager case not exercised"
fi

# ── Nothing available at all resolves to no pager ───────────────────────────
out="$(PATH="/nonexistent" _wb_resolve_pager 2>/dev/null)"
[[ -z "${out}" ]] \
    && ok "no WORKBENCH_PAGER/PAGER and no 'less' on PATH resolves to no pager" \
    || fail "expected empty result with no pager available, got '${out}'"

# ── _wb_maybe_page: never pages when stdout isn't a terminal ────────────────
# WORKBENCH_PAGER is set to a command that would fail/hang/produce
# nothing if it were actually invoked — proving the tty check
# short-circuits before the resolved pager value is ever used, not just
# that _wb_resolve_pager itself behaves correctly in isolation.
WORKBENCH_PAGER="false"
out="$(printf 'line one\nline two\n' | _wb_maybe_page)"
[[ "${out}" == "$(printf 'line one\nline two')" ]] \
    && ok "_wb_maybe_page passes input through unchanged when stdout is not a terminal" \
    || fail "_wb_maybe_page altered or lost output under a non-tty stdout"
unset WORKBENCH_PAGER

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
