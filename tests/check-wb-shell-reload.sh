#!/usr/bin/env bash
# tests/check-wb-shell-reload.sh — ARCHITECTURE.md §12 D39 acceptance check.
#
# Verifies lib/loader.sh's `wb` shell-function wrapper: state-changing
# subcommands re-source the loader in the *calling* shell afterwards
# (proven via WORKBENCH_OS, a sentinel the loader always re-sets),
# purely-informational subcommands don't, `wb reload` works standalone and
# is never forwarded to the real binary, the wrapped command's own exit
# status survives the reload, `command wb` reaches the real binary exactly
# once (no recursion), and bin/wb's own `reload` case explains itself
# rather than erroring as an unknown command.
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
# The stub records every invocation (proving `command wb` reaches it, and
# reaches it exactly once per call — no wrapper recursion) and its exit
# code is driven by $1 so the wrapper's own exit-status passthrough is
# checkable.
CORE_DIR="${XDG_DATA_HOME}/workbench/modules/core"
mkdir -p "${CORE_DIR}/snapshots/fixture-0000000/bin"
INVOKE_LOG="${WORK}/wb-stub-invocations.log"
cat > "${CORE_DIR}/snapshots/fixture-0000000/bin/wb" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${INVOKE_LOG}"
case "\${1:-}" in
    update) exit 3 ;;
    reload)
        case "\${2:-}" in
            -h|--help) echo "fake help text: wb reload is a shell function" ;;
        esac
        exit 0
        ;;
    *) exit 0 ;;
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

# ── 1. Sourcing lib/loader.sh defines `wb` as a shell function ─────────────
# shellcheck disable=SC1090
source "${REPO_ROOT}/lib/loader.sh" >/tmp/wb-reload-source.log 2>&1

if declare -f wb >/dev/null 2>&1; then
    ok "lib/loader.sh defines 'wb' as a shell function"
else
    fail "'wb' is not a shell function after sourcing lib/loader.sh"
    cat /tmp/wb-reload-source.log
fi

if [[ -n "${WORKBENCH_LOADER_PATH:-}" && -f "${WORKBENCH_LOADER_PATH}" ]]; then
    ok "WORKBENCH_LOADER_PATH is exported and points at a real file"
else
    fail "WORKBENCH_LOADER_PATH is unset or doesn't point at a real file: '${WORKBENCH_LOADER_PATH:-}'"
fi

# ── 2. A read-only subcommand does NOT trigger a reload ────────────────────
: > "${INVOKE_LOG}"
unset WORKBENCH_OS
wb status >/dev/null 2>&1
if [[ -z "${WORKBENCH_OS:-}" ]]; then
    ok "'wb status' did not reload (WORKBENCH_OS stayed unset)"
else
    fail "'wb status' unexpectedly reloaded the shell"
fi
if [[ "$(cat "${INVOKE_LOG}")" == "status" ]]; then
    ok "'wb status' reached the real binary exactly once, via 'command wb'"
else
    fail "'wb status' did not reach the real binary as expected"
    cat "${INVOKE_LOG}"
fi

# ── 3. A state-changing subcommand DOES trigger a reload, and preserves the
#    real binary's own exit status ─────────────────────────────────────────
: > "${INVOKE_LOG}"
unset WORKBENCH_OS
wb update
rc=$?
if [[ "${rc}" -eq 3 ]]; then
    ok "'wb update's exit status (3, from the stub) survives the wrapper"
else
    fail "'wb update' returned ${rc}, expected 3 (the stub's own exit code)"
fi
if [[ -n "${WORKBENCH_OS:-}" ]]; then
    ok "'wb update' reloaded the shell (WORKBENCH_OS was re-set)"
else
    fail "'wb update' did not reload the shell"
fi
if [[ "$(cat "${INVOKE_LOG}")" == "update" ]]; then
    ok "'wb update' reached the real binary exactly once"
else
    fail "'wb update' did not reach the real binary as expected"
    cat "${INVOKE_LOG}"
fi

# ── 4. 'wb reload' is a pure shell-function pseudo-command: never forwarded
#    to the real binary, still reloads ──────────────────────────────────────
: > "${INVOKE_LOG}"
unset WORKBENCH_OS
wb reload >/dev/null 2>&1
if [[ -n "${WORKBENCH_OS:-}" ]]; then
    ok "'wb reload' reloaded the shell"
else
    fail "'wb reload' did not reload the shell"
fi
if [[ ! -s "${INVOKE_LOG}" ]]; then
    ok "'wb reload' was never forwarded to the real binary"
else
    fail "'wb reload' unexpectedly reached the real binary"
    cat "${INVOKE_LOG}"
fi

# ── 4b. 'wb reload --help'/'-h' show help instead of reloading (they must
#    reach bin/wb's own central help interception, not the reload branch) ──
: > "${INVOKE_LOG}"
unset WORKBENCH_OS
HELP_OUT="$(wb reload --help 2>&1)"
if [[ -z "${WORKBENCH_OS:-}" ]] && echo "${HELP_OUT}" | grep -qi "shell function"; then
    ok "'wb reload --help' shows help instead of reloading"
else
    fail "'wb reload --help' did not show help as expected"
    echo "${HELP_OUT}"
fi
if [[ "$(cat "${INVOKE_LOG}")" == "reload --help" ]]; then
    ok "'wb reload --help' reached the real binary (for its help text), exactly once"
else
    fail "'wb reload --help' did not reach the real binary as expected"
    cat "${INVOKE_LOG}"
fi

: > "${INVOKE_LOG}"
unset WORKBENCH_OS
HELP_OUT_SHORT="$(wb reload -h 2>&1)"
if [[ -z "${WORKBENCH_OS:-}" ]] && [[ "${HELP_OUT_SHORT}" == "${HELP_OUT}" ]]; then
    ok "'wb reload -h' agrees with 'wb reload --help' and does not reload"
else
    fail "'wb reload -h' did not agree with 'wb reload --help'"
    echo "${HELP_OUT_SHORT}"
fi

# ── 4c. An unexpected extra argument is rejected, not silently ignored ─────
: > "${INVOKE_LOG}"
unset WORKBENCH_OS
wb reload bogus-extra-arg >/dev/null 2>&1
rc_extra=$?
if [[ "${rc_extra}" -ne 0 && -z "${WORKBENCH_OS:-}" ]]; then
    ok "'wb reload <extra arg>' is rejected instead of silently reloading"
else
    fail "'wb reload <extra arg>' was not rejected as expected (rc=${rc_extra}, WORKBENCH_OS='${WORKBENCH_OS:-}')"
fi

# ── 5. The real binary itself explains 'reload' if invoked directly
#    (wrapper not in scope) rather than a bare 'unknown command' ───────────
DIRECT_OUT="$(bash "${REPO_ROOT}/bin/wb" reload 2>&1)"
DIRECT_RC=$?
if [[ "${DIRECT_RC}" -ne 0 ]] && echo "${DIRECT_OUT}" | grep -qi "shell function"; then
    ok "'bin/wb reload' (no wrapper) explains itself instead of 'unknown command'"
else
    fail "'bin/wb reload' did not explain itself as expected"
    echo "${DIRECT_OUT}"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
