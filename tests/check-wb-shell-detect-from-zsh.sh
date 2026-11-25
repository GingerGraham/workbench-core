#!/usr/bin/env bash
# tests/check-wb-shell-detect-from-zsh.sh — docs/decisions-log.md D130.
#
# `bin/wb` always runs under bash, but a zsh session exports
# WORKBENCH_SHELL=zsh and WORKBENCH_PLATFORM_DETECTED=true. Before D130,
# _workbench_detect_platform returned early on the cached flag and left
# WORKBENCH_SHELL=zsh inside the bash process, so a module file that evals
# `direnv hook "${WORKBENCH_SHELL}"` ran direnv's zsh hook in bash. The zsh
# hook contains `${precmd_functions[(r)_direnv_hook]+1}`, an arithmetic
# expansion error in bash, which ends a non-interactive shell. `wb functions`
# sourced the module with its output sent to /dev/null, so it exited before
# printing anything.
#
# This test reproduces that with a synthetic module and a direnv stub, so it
# needs neither zsh nor the real direnv.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
# Snapshots are read-only (D120): unseal before deleting them.
trap 'chmod -R u+w "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT
export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
export XDG_STATE_HOME="${WORK}/state"
export XDG_CACHE_HOME="${WORK}/cache"
mkdir -p "${HOME}"
export COLUMNS=200

WB="${REPO_ROOT}/bin/wb"

# A direnv stand-in: `direnv hook zsh` prints a zsh hook line, any other shell
# a harmless one, as the real direnv does. The `(r)` subscript flag is valid
# zsh and a syntax error in bash.
STUB_BIN="${WORK}/stub-bin"
mkdir -p "${STUB_BIN}"
cat > "${STUB_BIN}/direnv" <<'SH'
#!/bin/sh
if [ "$1" = "hook" ] && [ "$2" = "zsh" ]; then
    echo 'if [[ -z "${precmd_functions[(r)_direnv_hook]+1}" ]]; then :; fi'
else
    echo ':'
fi
SH
chmod +x "${STUB_BIN}/direnv"

# The same line a real module has (workbench-shell's shell/direnv.sh): the
# hook is generated for ${WORKBENCH_SHELL}, whatever that holds.
src="${WORK}/src-zshprobe-module"
bare="${WORK}/zshprobe-module.git"
git init -q --bare "${bare}"
git clone -q "${bare}" "${src}" 2>/dev/null
mkdir -p "${src}/shell"
cat > "${src}/shell/zshprobe.sh" <<'SH'
get-zshprobe-functions() { echo "zshprobe functions here"; }
zshprobe-do-a-thing() { :; }
if command -v direnv >/dev/null 2>&1; then
    eval "$(direnv hook "${WORKBENCH_SHELL}")"
fi
SH
(
    cd "${src}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/zshprobe.sh
      tier: tools
  getters:
    - name: zshprobe
      function: get-zshprobe-functions
      label: "Zshprobe helpers"
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
) >/dev/null 2>&1

# Installing the module sources its shell file, so it runs with a clean
# environment: no stub on PATH, and no inherited shell facts.
env -u WORKBENCH_SHELL -u WORKBENCH_PLATFORM_DETECTED -u WORKBENCH_DISTRO_ID \
    bash "${WB}" add zshprobe-module "${bare}" --private >"${WORK}/add.log" 2>&1

# ── 1. The environment a zsh session hands to bin/wb. ─────────────────────
out="$(
    PATH="${STUB_BIN}:${PATH}" \
    WORKBENCH_PLATFORM_DETECTED=true \
    WORKBENCH_DISTRO_ID=fedora \
    WORKBENCH_SHELL=zsh \
    bash "${WB}" functions --no-pager 2>&1
)"
rc=$?

if [[ "${rc}" -eq 0 ]]; then
    ok "wb functions with an inherited WORKBENCH_SHELL=zsh exits 0"
else
    fail "wb functions with an inherited WORKBENCH_SHELL=zsh exited ${rc}, expected 0"
    echo "${out}" | head -20
    cat "${WORK}/add.log"
fi

if grep -q '\[INFO\] Getters' <<<"${out}"; then
    ok "the Getters header is printed"
else
    fail "the Getters header is missing: wb ended before printing"
fi

if grep -q 'zshprobe-do-a-thing' <<<"${out}" && grep -q 'get-zshprobe-functions.*Zshprobe helpers' <<<"${out}"; then
    ok "the synthetic module's function and getter are listed"
else
    fail "the synthetic module's function or getter is not listed"
    echo "${out}"
    echo "${out}" | head -20
fi

# ── 2. The detection itself, without wb around it. ────────────────────────
detected="$(
    cd "${REPO_ROOT}" && bash -c '
        export WORKBENCH_PLATFORM_DETECTED=true WORKBENCH_DISTRO_ID=fedora WORKBENCH_SHELL=zsh
        source lib/core/functions.sh
        echo "${WORKBENCH_SHELL}"
    ' 2>/dev/null
)"
if [[ "${detected}" == "bash" ]]; then
    ok "sourced in bash with an inherited zsh: WORKBENCH_SHELL is bash"
else
    fail "sourced in bash with an inherited zsh: WORKBENCH_SHELL is '${detected}', expected bash"
fi

# ── 3. The cached platform facts stay cached. ─────────────────────────────
distro_id="$(
    cd "${REPO_ROOT}" && bash -c '
        export WORKBENCH_PLATFORM_DETECTED=true WORKBENCH_DISTRO_ID=fedora WORKBENCH_SHELL=zsh
        source lib/core/functions.sh
        echo "${WORKBENCH_DISTRO_ID}"
    ' 2>/dev/null
)"
if [[ "${distro_id}" == "fedora" ]]; then
    ok "the other platform facts are still read from the cache"
else
    fail "WORKBENCH_DISTRO_ID was re-detected (got '${distro_id}'), expected the cached 'fedora'"
fi

# ── 4. The shell is exported, so child processes see it. ──────────────────
exported="$(
    cd "${REPO_ROOT}" && bash -c '
        export WORKBENCH_PLATFORM_DETECTED=true WORKBENCH_DISTRO_ID=fedora WORKBENCH_SHELL=zsh
        source lib/core/functions.sh
        bash -c "echo \"\${WORKBENCH_SHELL}\""
    ' 2>/dev/null
)"
if [[ "${exported}" == "bash" ]]; then
    ok "WORKBENCH_SHELL is exported as bash to child processes"
else
    fail "a child process sees WORKBENCH_SHELL='${exported}', expected bash"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
