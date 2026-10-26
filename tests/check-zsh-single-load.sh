#!/usr/bin/env bash
# tests/check-zsh-single-load.sh — docs/decisions-log.md D96 acceptance
# check.
#
# An interactive zsh reads ~/.zshenv and then ~/.zshrc. Both carry a loader
# stub, and before D96 both ran the whole loader, so the second pass saw a
# chpwd hook the first pass defined (workbench-shell's `ls` after every
# cd) and every `$(cd … && pwd)` captured that output before the path.
# This runs a real `wb apply` into an isolated HOME and starts real shells
# through the stubs it wrote. SKIPs only when zsh is absent; ci.yml installs
# zsh on ubuntu so it never skips there, and macOS ships it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WB="${REPO_ROOT}/bin/wb"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

ZSH_BIN="$(command -v zsh 2>/dev/null || true)"
BASH_BIN="$(command -v bash)"
if [[ -z "${ZSH_BIN}" ]]; then
    echo "SKIP: zsh is not installed — nothing to check"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
export XDG_CACHE_HOME="${WORK}/cache"
mkdir -p "${HOME}"

# An existing ~/.zshrc is what makes wb apply write the zsh stubs, both
# ~/.zshrc and ~/.zshenv, as a zsh user's install does.
touch "${HOME}/.zshrc"
if "${WB}" apply </dev/null >"${WORK}/apply.log" 2>&1; then
    ok "wb apply registered core and wrote the rc stubs"
else
    fail "wb apply failed — the shell-start checks below may be meaningless"
    cat "${WORK}/apply.log"
fi

# Local override files are sourced once per loader run (lib/loader.sh,
# _wb_loader_source_sh_files_once), so a counter there counts loader runs.
# The chpwd hook is defined on the first run, so a second run would see it.
LOCAL_DIR="${XDG_CONFIG_HOME}/workbench/local"
mkdir -p "${LOCAL_DIR}"
# shellcheck disable=SC2016  # written for the shell under test to expand
printf '%s\n' '_wb_test_loads=$(( ${_wb_test_loads:-0} + 1 ))' > "${LOCAL_DIR}/90-count.sh"
printf '%s\n' 'chpwd() { echo CHPWD-FIRED; }' > "${LOCAL_DIR}/91-chpwd.sh"

# shell_start <shell> <-i|-c> <commands> <stderr-file> [VAR=value…]
# A shell through the rc stubs, in a clean environment. skip_global_compinit:
# Ubuntu's /etc/zsh/zshrc runs compinit, which on a runner can print
# "compinit: initialization aborted" with no terminal to ask on — runner
# noise, not workbench's.
shell_start() {
    local shell="$1" mode="$2" cmds="$3" err="$4"
    shift 4
    local mode_args=(-c)
    [[ "${mode}" == "-i" ]] && mode_args=(-i -c)
    env -i \
        HOME="${HOME}" \
        XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
        USER="${USER:-runner}" \
        TERM=dumb \
        skip_global_compinit=1 \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        "$@" \
        "${shell}" "${mode_args[@]}" "${cmds}" 2>"${err}" </dev/null
}

# Bash prints two job-control lines when -i has no terminal; nothing else
# on stderr is acceptable.
filtered_stderr() {
    grep -vE 'cannot set terminal process group|no job control in this shell' "$1"
}

# ── 1. Interactive zsh runs the loader once. ──────────────────────────────
# shellcheck disable=SC2016  # expanded by the zsh under test
LOADS="$(shell_start "${ZSH_BIN}" -i 'print -r -- "${_wb_test_loads:-0}"' "${WORK}/zsh-loads.err")"
if [[ "${LOADS}" == "1" ]]; then
    ok "interactive zsh runs the loader once"
else
    fail "interactive zsh ran the loader '${LOADS}' times, expected 1"
fi

# ── 2. WORKBENCH_LOADER_PATH survives the start intact. ────────────────────
# shellcheck disable=SC2016  # expanded by the zsh under test
LP="$(shell_start "${ZSH_BIN}" -i '[[ -f "${WORKBENCH_LOADER_PATH}" ]] && print -r -- "${WORKBENCH_LOADER_PATH}"' "${WORK}/zsh-path.err")"
if [[ -n "${LP}" && "${LP}" != *$'\n'* && "${LP}" != *CHPWD-FIRED* && -f "${LP}" ]]; then
    ok "interactive zsh: WORKBENCH_LOADER_PATH names an existing file, with no newline or chpwd output in it"
else
    fail "interactive zsh: WORKBENCH_LOADER_PATH is garbled or missing: '${LP}'"
fi

# ── 3. Nothing on stderr. ──────────────────────────────────────────────────
if [[ -z "$(filtered_stderr "${WORK}/zsh-path.err")" ]]; then
    ok "interactive zsh starts with empty stderr"
else
    fail "interactive zsh wrote to stderr:"
    sed 's/^/        /' "${WORK}/zsh-path.err"
fi

# ── 4. Non-interactive zsh still loads workbench from .zshenv. ─────────────
WB_FOUND="$(shell_start "${ZSH_BIN}" -c 'command -v wb' "${WORK}/zsh-c.err")"
if [[ -n "${WB_FOUND}" ]]; then
    ok "non-interactive zsh (zsh -c) still loads workbench through .zshenv"
else
    fail "non-interactive zsh did not find wb — .zshenv no longer loads workbench there"
    sed 's/^/        /' "${WORK}/zsh-c.err"
fi

# ── 5. CDPATH makes cd print the directory; the path stays valid. ──────────
for shell in "${ZSH_BIN}" "${BASH_BIN}"; do
    name="$(basename "${shell}")"
    # shellcheck disable=SC2016  # expanded by the shell under test
    LP="$(shell_start "${shell}" -i '[[ -f "${WORKBENCH_LOADER_PATH}" ]] && printf "%s\n" "${WORKBENCH_LOADER_PATH}"' \
        "${WORK}/${name}-cdpath.err" CDPATH=/tmp:.)"
    if [[ -n "${LP}" && "${LP}" != *$'\n'* && -f "${LP}" ]]; then
        ok "${name} -i under CDPATH=/tmp:. still has a valid WORKBENCH_LOADER_PATH"
    else
        fail "${name} -i under CDPATH=/tmp:.: WORKBENCH_LOADER_PATH is '${LP}'"
        sed 's/^/        /' "${WORK}/${name}-cdpath.err"
    fi
done

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
