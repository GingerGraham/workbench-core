#!/usr/bin/env bash
# tests/check-ssh-bootstrap-gating.sh — Phase 6 acceptance check.
#
# With zero private modules registered, lib/ssh/bootstrap.sh must be a
# clean no-op. Registering one private module must generate a working
# deploy key + SSH alias, and rewrite that module's REPO_URL to the alias
# form Phase 5's private-repo fetch path (lib/distribution/fetch-git-snapshot.sh)
# consumes. `ssh-keygen` is stubbed with a fake that produces a plausible
# keypair (not a real one) when the real binary isn't on PATH in this
# environment — the logic under test is the config/URL-rewriting mechanics,
# not OpenSSH's own key generation, which is a single well-known,
# unmodified invocation ported verbatim from a working script.
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
mkdir -p "${HOME}"

FAKE_BIN="${WORK}/fakebin"
mkdir -p "${FAKE_BIN}"
if ! command -v ssh-keygen &>/dev/null; then
    cat > "${FAKE_BIN}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
# Minimal stand-in for environments without openssh-client installed —
# produces a plausible-looking (not cryptographically real) keypair at the
# -f path, enough to exercise lib/ssh/bootstrap.sh's own logic.
key=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) key="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[[ -z "${key}" ]] && exit 1
echo "-----BEGIN OPENSSH PRIVATE KEY-----FAKE-----END OPENSSH PRIVATE KEY-----" > "${key}"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE fake@test" > "${key}.pub"
chmod 600 "${key}"
exit 0
EOF
    chmod +x "${FAKE_BIN}/ssh-keygen"
    export PATH="${FAKE_BIN}:${PATH}"
    echo "INFO: real ssh-keygen not found on PATH — using a stub for this check"
fi

# shellcheck source=lib/core/log.sh
source "${REPO_ROOT}/lib/core/log.sh"
# shellcheck source=lib/sync/state.sh
source "${REPO_ROOT}/lib/sync/state.sh"
# shellcheck source=lib/ssh/bootstrap.sh
source "${REPO_ROOT}/lib/ssh/bootstrap.sh"

# ── 1. Zero private modules: clean no-op, no .ssh directory created. ──────
workbench_ssh_bootstrap_all >/tmp/wb-ssh-1.log 2>&1
if [[ ! -d "${HOME}/.ssh" ]]; then
    ok "with zero private modules registered, bootstrap is a clean no-op (no ~/.ssh created)"
else
    fail "bootstrap created ~/.ssh with nothing private registered"
fi

# ── 2. A public module is untouched even when present alongside nothing
#    else — bootstrap must not react to non-private modules at all. ───────
mkdir -p "$(workbench_module_dir core)"
cat > "$(workbench_module_conf_path core)" <<EOF
REPO_URL=https://github.com/GingerGraham/workbench-core.git
PRIVATE=false
TRACK_MODE=latest
REGISTERED=true
SYNC_ENABLED=true
EOF
workbench_ssh_bootstrap_all >/tmp/wb-ssh-2.log 2>&1
if [[ ! -d "${HOME}/.ssh" ]]; then
    ok "a public (PRIVATE=false) registered module still triggers no SSH bootstrap"
else
    fail "bootstrap acted on a public module"
fi

# ── 3. One private module: key + alias generated, REPO_URL rewritten. ─────
mkdir -p "$(workbench_module_dir awsconfd)"
cat > "$(workbench_module_conf_path awsconfd)" <<EOF
REPO_URL=git@github.com:someowner/awsconfd.git
PRIVATE=true
TRACK_MODE=latest
REGISTERED=true
SYNC_ENABLED=true
EOF
workbench_ssh_bootstrap_all >/tmp/wb-ssh-3.log 2>&1

if [[ -f "${HOME}/.ssh/workbench-awsconfd" && -f "${HOME}/.ssh/workbench-awsconfd.pub" ]]; then
    ok "a deploy keypair was generated at ~/.ssh/workbench-awsconfd{,.pub}"
else
    fail "deploy keypair was not generated"
fi

# A newly-generated key's public content and "add this deploy key"
# instructions must actually be printed (flagged in review: the docstring
# promised this and docs/getting-started.md relies on it, but nothing
# actually printed the key).
if grep -q "ACTION REQUIRED" /tmp/wb-ssh-3.log && grep -q "ssh-ed25519" /tmp/wb-ssh-3.log; then
    ok "bootstrap prints the newly-generated public key with 'ACTION REQUIRED' instructions"
else
    fail "bootstrap did not print the public key / instructions for a newly-generated key"
    cat /tmp/wb-ssh-3.log
fi

if [[ "$(stat -c '%a' "${HOME}/.ssh/workbench-awsconfd" 2>/dev/null || stat -f '%Lp' "${HOME}/.ssh/workbench-awsconfd")" == "600" ]]; then
    ok "the private key file has 600 permissions"
else
    fail "the private key file does not have 600 permissions"
fi

if grep -qx "Host workbench-awsconfd" "${HOME}/.ssh/config.d/10-workbench.conf" 2>/dev/null; then
    ok "an SSH config.d alias block for workbench-awsconfd was written"
else
    fail "no SSH config.d alias block was written for awsconfd"
fi

if grep -q "HostName github.com" "${HOME}/.ssh/config.d/10-workbench.conf" 2>/dev/null; then
    ok "the alias's HostName correctly resolves to the original host (github.com)"
else
    fail "the alias's HostName is missing or wrong"
fi

if grep -qF "Include ~/.ssh/config.d/*.conf" "${HOME}/.ssh/config" 2>/dev/null; then
    ok "~/.ssh/config includes the config.d directory"
else
    fail "~/.ssh/config does not include config.d"
fi

new_url="$(workbench_module_conf_get awsconfd REPO_URL "")"
if [[ "${new_url}" == "git@workbench-awsconfd:someowner/awsconfd.git" ]]; then
    ok "awsconfd's REPO_URL was rewritten to the alias form (git@workbench-awsconfd:someowner/awsconfd.git)"
else
    fail "REPO_URL was not rewritten correctly: '${new_url}'"
fi

# ── 4. core is never private (ARCHITECTURE.md §2) — even if somehow marked
#    so, this is just confirming the mechanism has no core-specific
#    special-casing at all: it acted identically on "awsconfd" as it would
#    on any name, including "core", per module zero (grep check). ─────────
if grep -vE '^[[:space:]]*#' "${REPO_ROOT}/lib/ssh/bootstrap.sh" | grep -qE '"core"|'"'"'core'"'"''; then
    fail "lib/ssh/bootstrap.sh appears to hardcode the name 'core' outside comments"
else
    ok "lib/ssh/bootstrap.sh contains no hardcoded reference to 'core' — no module-zero special-casing"
fi

# ── 5. Idempotency: re-running does not regenerate the key or duplicate
#    the config.d block. ───────────────────────────────────────────────────
key_mtime_before="$(stat -c '%Y' "${HOME}/.ssh/workbench-awsconfd" 2>/dev/null || stat -f '%m' "${HOME}/.ssh/workbench-awsconfd")"
sleep 1
workbench_ssh_bootstrap_all >/tmp/wb-ssh-4.log 2>&1
key_mtime_after="$(stat -c '%Y' "${HOME}/.ssh/workbench-awsconfd" 2>/dev/null || stat -f '%m' "${HOME}/.ssh/workbench-awsconfd")"
alias_count="$(grep -c '^Host workbench-awsconfd$' "${HOME}/.ssh/config.d/10-workbench.conf")"

if [[ "${key_mtime_before}" == "${key_mtime_after}" ]]; then
    ok "re-running bootstrap does not regenerate an already-existing deploy key"
else
    fail "re-running bootstrap regenerated the deploy key"
fi
if [[ "${alias_count}" -eq 1 ]]; then
    ok "re-running bootstrap does not duplicate the SSH config.d alias block"
else
    fail "re-running bootstrap duplicated the alias block (count: ${alias_count})"
fi
if grep -q "ACTION REQUIRED" /tmp/wb-ssh-4.log; then
    fail "re-running bootstrap re-printed the deploy-key instructions for an already-bootstrapped module"
else
    ok "re-running bootstrap does not re-print deploy-key instructions once already bootstrapped"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
