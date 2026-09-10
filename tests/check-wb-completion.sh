#!/usr/bin/env bash
# tests/check-wb-completion.sh — Phase 1 'wb completion' acceptance check.
#
# Covers: both shells generate non-empty, syntactically valid output; the
# introspected command list matches bin/wb's actual dispatch case exactly
# (catches drift before it ships — the whole point of introspecting
# rather than hand-maintaining); an unsupported/missing shell argument is
# rejected; and 'wb completion' is reachable via both 'wb help completion'
# and 'wb completion --help'/'-h', matching every other command's
# contract (tests/check-wb-help.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WB="${REPO_ROOT}/bin/wb"

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

# ── 1. Both shells generate output, and bash's is syntactically valid ──────
BASH_OUT="$(bash "${WB}" completion bash 2>&1)"
# shellcheck disable=SC2015
[[ -n "${BASH_OUT}" ]] && ok "'wb completion bash' produced output" || fail "'wb completion bash' produced no output"

if echo "${BASH_OUT}" | bash -n /dev/stdin 2>"${WORK}/bash-syntax.log"; then
    ok "'wb completion bash' output passes 'bash -n'"
else
    fail "'wb completion bash' output failed syntax check"
    cat "${WORK}/bash-syntax.log" >&2
fi

# shellcheck disable=SC2015
echo "${BASH_OUT}" | grep -q "complete -F _wb_completions wb" \
    && ok "'wb completion bash' registers via 'complete -F'" \
    || fail "'wb completion bash' did not register via 'complete -F'"

ZSH_OUT="$(bash "${WB}" completion zsh 2>&1)"
# shellcheck disable=SC2015
[[ -n "${ZSH_OUT}" ]] && ok "'wb completion zsh' produced output" || fail "'wb completion zsh' produced no output"

# shellcheck disable=SC2015
echo "${ZSH_OUT}" | grep -q "compdef _wb_completions wb" \
    && ok "'wb completion zsh' registers via 'compdef'" \
    || fail "'wb completion zsh' did not register via 'compdef'"

# ── 2. The introspected command list matches the real dispatch case — the
#    single-source-of-truth guarantee this whole mechanism exists for.
#    Adjust the COMPLETION_CMDS extraction regex here if the generated
#    bash format changes. ───────────────────────────────────────────────
DISPATCH_CMDS="$(sed -n '/^case "\${_wb_cmd}" in$/,/^esac$/p' "${WB}" \
    | grep -oE '^[[:space:]]*[a-z][a-zA-Z0-9_-]*\)' | tr -d ' )' | sort -u)"
COMPLETION_CMDS="$(echo "${BASH_OUT}" | grep -oE 'compgen -W "[^"]*"' \
    | sed -E 's/compgen -W "//; s/"$//' | tr ' ' '\n' | sort -u)"

if [[ "${DISPATCH_CMDS}" == "${COMPLETION_CMDS}" ]]; then
    ok "completion command list matches bin/wb's dispatch case exactly — no drift"
else
    fail "completion command list does not match the dispatch case"
    diff <(echo "${DISPATCH_CMDS}") <(echo "${COMPLETION_CMDS}") >&2
fi

# ── 3. Unsupported/missing shell argument is rejected, not silently
#    accepted. ──────────────────────────────────────────────────────────
if bash "${WB}" completion fish >/dev/null 2>&1; then
    fail "'wb completion fish' was accepted — unsupported shells must error"
else
    ok "'wb completion fish' is rejected"
fi

if bash "${WB}" completion >/dev/null 2>&1; then
    fail "'wb completion' with no argument was accepted"
else
    ok "'wb completion' with no argument errors"
fi

# ── 4. Reachable via 'wb help completion' and 'wb completion --help'/'-h',
#    agreeing exactly — same contract every other command has. ──────────
via_help="$(bash "${WB}" help completion 2>&1)"
via_flag_long="$(bash "${WB}" completion --help 2>&1)"
via_flag_short="$(bash "${WB}" completion -h 2>&1)"

# shellcheck disable=SC2015
[[ -n "${via_help}" ]] && ok "'wb help completion' produces detail" || fail "'wb help completion' produced no output"
# shellcheck disable=SC2015
[[ "${via_help}" == "${via_flag_long}" ]] && ok "'wb help completion' and 'wb completion --help' agree" || fail "'wb help completion' and 'wb completion --help' differ"
# shellcheck disable=SC2015
[[ "${via_help}" == "${via_flag_short}" ]] && ok "'wb help completion' and 'wb completion -h' agree" || fail "'wb help completion' and 'wb completion -h' differ"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
