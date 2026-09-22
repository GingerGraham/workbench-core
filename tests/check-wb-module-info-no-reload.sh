#!/usr/bin/env bash
# tests/check-wb-module-info-no-reload.sh — D67 acceptance check.
#
# lib/loader.sh's `wb` shell-function wrapper reloads the whole shell
# (re-sources WORKBENCH_LOADER_PATH) after any subcommand it doesn't
# explicitly recognise as read-only. `module` was never added to that
# list, so every `wb module ...` call reloaded — including `info`/`docs`,
# which docs/decisions-log.md D45 and docs/architecture.md document as
# read-only. This asserts the gap is closed for `info`/`docs`, while
# `reset` (genuinely state-changing) and an ordinary top-level
# state-changing subcommand still reload, as controls — the exclusion is
# scoped to two `wb module` subcommands, not a blanket exemption for the
# whole command group.
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
# Same stub shape as tests/check-wb-completion-no-reload.sh: records every
# invocation and its exit code is driven by $1.
CORE_DIR="${XDG_DATA_HOME}/workbench/modules/core"
mkdir -p "${CORE_DIR}/snapshots/fixture-0000000/bin"
INVOKE_LOG="${WORK}/wb-stub-invocations.log"
cat > "${CORE_DIR}/snapshots/fixture-0000000/bin/wb" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${INVOKE_LOG}"
case "\${1:-}" in
    update) exit 3 ;;
    *)      exit 0 ;;
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
source "${REPO_ROOT}/lib/loader.sh" >/tmp/wb-module-info-no-reload-source.log 2>&1

if declare -f wb >/dev/null 2>&1; then
    ok "lib/loader.sh defines 'wb' as a shell function"
else
    fail "'wb' is not a shell function after sourcing lib/loader.sh"
    cat /tmp/wb-module-info-no-reload-source.log
fi

# ── 1. 'wb module info <name>' does NOT trigger a reload ───────────────────
: > "${INVOKE_LOG}"
unset WORKBENCH_OS
wb module info core >/dev/null 2>&1
if [[ -z "${WORKBENCH_OS:-}" ]]; then
    ok "'wb module info core' did not reload (WORKBENCH_OS stayed unset)"
else
    fail "'wb module info core' unexpectedly reloaded the shell"
fi
if [[ "$(cat "${INVOKE_LOG}")" == "module info core" ]]; then
    ok "'wb module info core' reached the real binary exactly once, via 'command wb'"
else
    fail "'wb module info core' did not reach the real binary as expected"
    cat "${INVOKE_LOG}"
fi

# ── 2. 'wb module docs <name>' does NOT trigger a reload ───────────────────
: > "${INVOKE_LOG}"
unset WORKBENCH_OS
wb module docs core >/dev/null 2>&1
if [[ -z "${WORKBENCH_OS:-}" ]]; then
    ok "'wb module docs core' did not reload (WORKBENCH_OS stayed unset)"
else
    fail "'wb module docs core' unexpectedly reloaded the shell"
fi
if [[ "$(cat "${INVOKE_LOG}")" == "module docs core" ]]; then
    ok "'wb module docs core' reached the real binary exactly once"
else
    fail "'wb module docs core' did not reach the real binary as expected"
    cat "${INVOKE_LOG}"
fi

# ── 3. Control: 'wb module reset <name> <target>' still reloads — the
#    exclusion is scoped to info/docs, not the whole 'module' group ────────
: > "${INVOKE_LOG}"
unset WORKBENCH_OS
wb module reset core tmux.conf >/dev/null 2>&1
if [[ -n "${WORKBENCH_OS:-}" ]]; then
    ok "'wb module reset core tmux.conf' (control) still reloads the shell"
else
    fail "'wb module reset core tmux.conf' (control) did not reload — the exclusion is too broad"
fi

# ── 4. Control: an ordinary state-changing top-level subcommand still
#    reloads, exactly as before this fix ───────────────────────────────────
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
    ok "'wb update' (control) still reloads the shell"
else
    fail "'wb update' (control) did not reload the shell"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
