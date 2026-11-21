#!/usr/bin/env bash
# tests/check-ensure-npm-min-major.sh — acceptance check for the optional
# <min_major> argument of _ensure_npm (lib/core/installers-common.sh,
# Core API 1.9). With it, the package-manager fallback must not elevate
# unless the manager's own candidate Node.js is at least <min_major>.
#
# Every case runs in a subshell with a PATH holding only symlinks to the
# few system tools the helper needs, plus stub package managers that log
# what they were asked to do. Nothing real is installed or elevated.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# shellcheck source=lib/core/log.sh
source "${REPO_ROOT}/lib/core/log.sh"
# shellcheck source=lib/core/installers-common.sh
source "${REPO_ROOT}/lib/core/installers-common.sh"

# new_sandbox <name> — creates ${WORK}/<name>/bin holding symlinks to the
# system tools _ensure_npm and its helpers use, and an empty call log.
# Deliberately leaves out npm, node, nvm and every package manager.
new_sandbox() {
    local name="$1" tool tool_path
    SANDBOX="${WORK}/${name}"
    mkdir -p "${SANDBOX}/bin" "${SANDBOX}/home"
    : > "${SANDBOX}/calls.log"
    for tool in sed grep sort tail head cut tr cat chmod mkdir rm printf basename; do
        tool_path="$(type -P "${tool}")" || continue
        ln -s "${tool_path}" "${SANDBOX}/bin/${tool}"
    done

    # sudo stub: log, then run the rest of the command line.
    cat > "${SANDBOX}/bin/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "${WB_TEST_CALLS}"
exec "$@"
EOF
    chmod +x "${SANDBOX}/bin/sudo"
}

# stub_installer <tool> — a package manager whose install
# command logs itself and then drops a working npm stub into the sandbox,
# as a real install would.
stub_installer() {
    local tool="$1"
    cat > "${SANDBOX}/bin/${tool}" <<'EOF'
#!/bin/sh
echo "$(basename "$0") $*" >> "${WB_TEST_CALLS}"
case "$1" in
    install|-S|-Sy) printf '#!/bin/sh\nexit 0\n' > "${WB_TEST_BIN}/npm"; chmod +x "${WB_TEST_BIN}/npm" ;;
esac
exit 0
EOF
    chmod +x "${SANDBOX}/bin/${tool}"
}

# stub_query <tool> <output> — a read-only metadata command that prints
# <output> whatever it is asked.
stub_query() {
    local tool="$1" output="$2"
    printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "${output}" > "${SANDBOX}/bin/${tool}"
    chmod +x "${SANDBOX}/bin/${tool}"
}

# run_ensure_npm <package-manager> [args...] — runs _ensure_npm in the sandbox
# and prints its exit code on the last line of stdout.
run_ensure_npm() {
    local package_manager="$1"
    shift
    (
        export PATH="${SANDBOX}/bin"
        export HOME="${SANDBOX}/home"
        export WB_TEST_CALLS="${SANDBOX}/calls.log"
        export WB_TEST_BIN="${SANDBOX}/bin"
        export PACKAGE_MANAGER="${package_manager}"
        unset NVM_DIR
        get-elevation-command() { echo sudo; }
        _ensure_npm "$@" >/dev/null 2>&1
        echo "$?"
    )
}

elevated() { grep -q '^sudo ' "${SANDBOX}/calls.log"; }
installed() { grep -q "^$1 install" "${SANDBOX}/calls.log"; }

# ── Check 1: no argument — behaviour unchanged, installs without a query ───
new_sandbox c1
stub_installer apt-get
stub_query apt-cache "  Candidate: 18.19.1+dfsg-6"
rc="$(run_ensure_npm apt)"
if [[ "${rc}" == "0" ]] && elevated && installed apt-get; then
    ok "no argument: apt fallback still installs (even with an old candidate)"
else
    fail "no argument: expected install and exit 0 (rc=${rc})"
fi

# ── Check 2: apt candidate too old — refuses, never elevates ───────────────
new_sandbox c2
stub_installer apt-get
stub_query apt-cache "  Candidate: 18.19.1+dfsg-6"
rc="$(run_ensure_npm apt 22)"
if [[ "${rc}" == "1" ]] && ! elevated && [[ ! -s "${SANDBOX}/calls.log" ]]; then
    ok "apt candidate 18 < 22: exit 1, no sudo, nothing installed"
else
    fail "apt candidate 18 < 22: expected exit 1 and no calls (rc=${rc}): $(cat "${SANDBOX}/calls.log")"
fi

# ── Check 3: apt candidate new enough, with an epoch — installs ────────────
new_sandbox c3
stub_installer apt-get
stub_query apt-cache "  Candidate: 2:22.11.0-1nodesource1"
rc="$(run_ensure_npm apt 22)"
if [[ "${rc}" == "0" ]] && elevated && installed apt-get; then
    ok "apt candidate 2:22.11.0 >= 22: epoch stripped, installs via sudo"
else
    fail "apt candidate 2:22.11.0 >= 22: expected install and exit 0 (rc=${rc})"
fi

# ── Check 4: apt has no candidate — refuses, never elevates ────────────────
new_sandbox c4
stub_installer apt-get
stub_query apt-cache "  Candidate: (none)"
rc="$(run_ensure_npm apt 22)"
if [[ "${rc}" == "1" ]] && ! elevated; then
    ok "apt candidate (none): exit 1, no sudo"
else
    fail "apt candidate (none): expected exit 1 and no sudo (rc=${rc})"
fi

# ── Check 5: metadata command missing — cannot tell, refuses ───────────────
new_sandbox c5
stub_installer apt-get
rc="$(run_ensure_npm apt 22)"
if [[ "${rc}" == "1" ]] && ! elevated; then
    ok "apt-cache unavailable: version unknown, exit 1, no sudo"
else
    fail "apt-cache unavailable: expected exit 1 and no sudo (rc=${rc})"
fi

# ── Check 6: dnf lists several versions — highest wins ─────────────────────
new_sandbox c6
# dnf is both the metadata query and the installer, so the stub answers
# `repoquery` with versions and logs anything else as an install.
cat > "${SANDBOX}/bin/dnf" <<'EOF'
#!/bin/sh
case "$*" in
    *repoquery*) printf '20.11.1\n22.2.0\n'; exit 0 ;;
esac
echo "dnf $*" >> "${WB_TEST_CALLS}"
printf '#!/bin/sh\nexit 0\n' > "${WB_TEST_BIN}/npm"; chmod +x "${WB_TEST_BIN}/npm"
EOF
chmod +x "${SANDBOX}/bin/dnf"
rc="$(run_ensure_npm dnf 22)"
if [[ "${rc}" == "0" ]] && elevated && installed dnf; then
    ok "dnf lists 20 and 22: highest (22) meets the minimum, installs"
else
    fail "dnf lists 20 and 22: expected install and exit 0 (rc=${rc})"
fi

# ── Check 7: dnf candidate too old — refuses ───────────────────────────────
new_sandbox c7
cat > "${SANDBOX}/bin/dnf" <<'EOF'
#!/bin/sh
case "$*" in
    *repoquery*) printf '20.11.1\n'; exit 0 ;;
esac
echo "dnf $*" >> "${WB_TEST_CALLS}"
EOF
chmod +x "${SANDBOX}/bin/dnf"
rc="$(run_ensure_npm dnf 22)"
if [[ "${rc}" == "1" ]] && ! elevated && [[ ! -s "${SANDBOX}/calls.log" ]]; then
    ok "dnf candidate 20 < 22: exit 1, no sudo, nothing installed"
else
    fail "dnf candidate 20 < 22: expected exit 1 and no calls (rc=${rc})"
fi

# ── Check 8: pacman candidate too old, then new enough ─────────────────────
new_sandbox c8
stub_query pacman "Version         : 20.18.0-1"
rc="$(run_ensure_npm pacman 22)"
if [[ "${rc}" == "1" ]] && ! elevated; then
    ok "pacman candidate 20 < 22: exit 1, no sudo"
else
    fail "pacman candidate 20 < 22: expected exit 1 and no sudo (rc=${rc})"
fi

new_sandbox c9
cat > "${SANDBOX}/bin/pacman" <<'EOF'
#!/bin/sh
case "$1" in
    -Si) printf 'Version         : 25.2.0-1\n'; exit 0 ;;
esac
echo "pacman $*" >> "${WB_TEST_CALLS}"
printf '#!/bin/sh\nexit 0\n' > "${WB_TEST_BIN}/npm"; chmod +x "${WB_TEST_BIN}/npm"
EOF
chmod +x "${SANDBOX}/bin/pacman"
rc="$(run_ensure_npm pacman 22)"
if [[ "${rc}" == "0" ]] && elevated; then
    ok "pacman candidate 25 >= 22: installs via sudo"
else
    fail "pacman candidate 25 >= 22: expected install and exit 0 (rc=${rc})"
fi

# ── Check 10: zypper candidate too old — refuses ───────────────────────────
new_sandbox c10
stub_query zypper "Version        : 20.18.1-1.1"
rc="$(run_ensure_npm zypper 22)"
if [[ "${rc}" == "1" ]] && ! elevated; then
    ok "zypper candidate 20 < 22: exit 1, no sudo"
else
    fail "zypper candidate 20 < 22: expected exit 1 and no sudo (rc=${rc})"
fi

# ── Check 11: brew never elevates, so the minimum doesn't gate it ──────────
new_sandbox c11
stub_installer brew
rc="$(run_ensure_npm brew 22)"
if [[ "${rc}" == "0" ]] && ! elevated && installed brew; then
    ok "brew with a minimum: installs without elevation"
else
    fail "brew with a minimum: expected a plain brew install (rc=${rc})"
fi

# ── Check 12: npm already on PATH — returns at once, nothing queried ───────
new_sandbox c12
stub_installer apt-get
printf '#!/bin/sh\nexit 0\n' > "${SANDBOX}/bin/npm"
chmod +x "${SANDBOX}/bin/npm"
rc="$(run_ensure_npm apt 22)"
if [[ "${rc}" == "0" ]] && [[ ! -s "${SANDBOX}/calls.log" ]]; then
    ok "npm already resolves: exit 0, no package manager involved"
else
    fail "npm already resolves: expected exit 0 and no calls (rc=${rc})"
fi

# ── Check 13: nvm provides npm — package manager never reached ─────────────
new_sandbox c13
stub_installer apt-get
mkdir -p "${SANDBOX}/home/.nvm"
cat > "${SANDBOX}/home/.nvm/nvm.sh" <<'EOF'
npm() { :; }
EOF
rc="$(run_ensure_npm apt 22)"
if [[ "${rc}" == "0" ]] && [[ ! -s "${SANDBOX}/calls.log" ]]; then
    ok "nvm.sh supplies npm: exit 0, no sudo, no package manager"
else
    fail "nvm.sh supplies npm: expected exit 0 and no calls (rc=${rc})"
fi

# ── Check 14: a non-numeric minimum is rejected up front ───────────────────
new_sandbox c14
stub_installer apt-get
rc="$(run_ensure_npm apt twenty-two)"
if [[ "${rc}" == "1" ]] && [[ ! -s "${SANDBOX}/calls.log" ]]; then
    ok "non-numeric <min_major>: exit 1, nothing run"
else
    fail "non-numeric <min_major>: expected exit 1 and no calls (rc=${rc})"
fi

echo
if [[ "${FAILED}" -ne 0 ]]; then
    echo "${FAILED} check(s) failed."
    exit 1
fi
echo "All ${check_no} checks passed."
