#!/usr/bin/env bash
# tests/check-wb-completion-no-reload.sh — Fix 1 acceptance check
# (docs/decisions-log.md D65).
#
# lib/loader.sh's `wb` shell-function wrapper reloads the whole shell
# (re-sources WORKBENCH_LOADER_PATH) after any subcommand it doesn't
# explicitly recognise as read-only. `__complete` — the hidden dispatcher
# the generated bash/zsh completion scripts shell out to on every
# keystroke past the first TAB level (D54) — was missing from that
# read-only list, meaning every keystroke of second-level tab completion
# paid for a full shell reload. This asserts the gap is closed:
# `wb __complete <kind>` no longer reloads, while an ordinary
# state-changing subcommand still does, as a control (same fixture/stub
# pattern as tests/check-wb-shell-reload.sh, which this file deliberately
# mirrors).
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
export XDG_CACHE_HOME="${WORK}/cache"
mkdir -p "${HOME}"

# ── Fixture: a bootstrapped core module with a stub bin/wb ─────────────────
# Same stub shape as tests/check-wb-shell-reload.sh: records every
# invocation and its exit code is driven by $1.
CORE_DIR="${XDG_DATA_HOME}/workbench/modules/core"
mkdir -p "${CORE_DIR}/snapshots/fixture-0000000/bin"
INVOKE_LOG="${WORK}/wb-stub-invocations.log"
cat > "${CORE_DIR}/snapshots/fixture-0000000/bin/wb" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${INVOKE_LOG}"
case "\${1:-}" in
    __complete) echo "registered-modules" ;;
    update)     exit 3 ;;
    *)          exit 0 ;;
esac
EOF
chmod +x "${CORE_DIR}/snapshots/fixture-0000000/bin/wb"
ln -s "${CORE_DIR}/snapshots/fixture-0000000" "${CORE_DIR}/current"
cat > "${CORE_DIR}/sync.conf" <<'EOF'
TRACK_MODE=latest
REGISTERED=true
SYNC_ENABLED=true
EOF

# shellcheck disable=SC1090
source "${REPO_ROOT}/bin/wb" >/dev/null 2>&1
_wb_link_cli_bin >/dev/null 2>&1

# shellcheck disable=SC1090
source "${REPO_ROOT}/lib/loader.sh" >/tmp/wb-completion-no-reload-source.log 2>&1

if declare -f wb >/dev/null 2>&1; then
    ok "lib/loader.sh defines 'wb' as a shell function"
else
    fail "'wb' is not a shell function after sourcing lib/loader.sh"
    cat /tmp/wb-completion-no-reload-source.log
fi

# ── 1. 'wb __complete <kind>' does NOT trigger a reload ────────────────────
: > "${INVOKE_LOG}"
unset WORKBENCH_OS
COMPLETE_OUT="$(wb __complete registered-modules 2>&1)"
if [[ -z "${WORKBENCH_OS:-}" ]]; then
    ok "'wb __complete registered-modules' did not reload (WORKBENCH_OS stayed unset)"
else
    fail "'wb __complete registered-modules' unexpectedly reloaded the shell"
fi
if [[ "$(cat "${INVOKE_LOG}")" == "__complete registered-modules" ]]; then
    ok "'wb __complete registered-modules' reached the real binary exactly once, via 'command wb'"
else
    fail "'wb __complete registered-modules' did not reach the real binary as expected"
    cat "${INVOKE_LOG}"
fi
if [[ "${COMPLETE_OUT}" == "registered-modules" ]]; then
    ok "'wb __complete registered-modules' output passed through the wrapper unchanged"
else
    fail "'wb __complete registered-modules' output was not passed through unchanged: '${COMPLETE_OUT}'"
fi

# ── 2. A second __complete kind, run back-to-back, still never reloads ─────
: > "${INVOKE_LOG}"
unset WORKBENCH_OS
wb __complete tools >/dev/null 2>&1
if [[ -z "${WORKBENCH_OS:-}" ]]; then
    ok "a second, back-to-back 'wb __complete' call still does not reload"
else
    fail "a second 'wb __complete' call unexpectedly reloaded the shell"
fi

# ── 3. Control: an ordinary state-changing subcommand still reloads, exactly
#    as before this fix — the exclusion list grew by one entry, it didn't
#    become a blanket exemption ─────────────────────────────────────────────
: > "${INVOKE_LOG}"
unset WORKBENCH_OS
wb update
rc=$?
if [[ "${rc}" -eq 3 ]]; then
    ok "'wb update's exit status (3, from the stub) still survives the wrapper"
else
    fail "'wb update' returned ${rc}, expected 3 (the stub's own exit code)"
fi
if [[ -n "${WORKBENCH_OS:-}" ]]; then
    ok "'wb update' (control) still reloads the shell — __complete's exclusion is scoped, not blanket"
else
    fail "'wb update' (control) did not reload the shell — the exclusion list is too broad"
fi
if [[ "$(cat "${INVOKE_LOG}")" == "update" ]]; then
    ok "'wb update' (control) reached the real binary exactly once"
else
    fail "'wb update' (control) did not reach the real binary as expected"
    cat "${INVOKE_LOG}"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
