#!/usr/bin/env bash
# tests/check-install-finish-message.sh — docs/decisions-log.md D113
# acceptance check.
#
# Verifies the last line of a successful `wb install`/`wb apply`:
#   - plain "done." when the loader's wb() wrapper will reload the shell
#     (_WB_WRAPPER_RELOADS=true) or when there's no terminal;
#   - otherwise, "source <rc>" naming the rc file of the shell that ran the
#     command, read from the parent process and falling back to $SHELL,
#     then bash;
#   - the old fixed "Start a new shell" text is gone from bin/wb.
#
# Calls _wb_install_finish_message directly rather than running a full
# `wb install`, with `_wb_have_tty` and `ps` replaced by stubs.
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

WB="${REPO_ROOT}/bin/wb"
# shellcheck source=bin/wb
source "${WB}" >"${WORK}/wb-source.log" 2>&1

# ── Stubs ──────────────────────────────────────────────────────────────────
_tty_yes() { _wb_have_tty() { return 0; }; }
_tty_no()  { _wb_have_tty() { return 1; }; }

# A stub 'ps' first on PATH, in a directory of its own. It prints
# ${FAKE_PS_COMM} and exits 0, or exits 1 when FAKE_PS_FAIL=1.
STUB_BIN="${WORK}/stub-bin"
mkdir -p "${STUB_BIN}"
cat > "${STUB_BIN}/ps" <<'STUB'
#!/bin/sh
if [ "${FAKE_PS_FAIL:-}" = "1" ]; then
    exit 1
fi
printf '%s\n' "${FAKE_PS_COMM:-}"
exit 0
STUB
chmod +x "${STUB_BIN}/ps"
export PATH="${STUB_BIN}:${PATH}"

# run_message <description> <expected-substring|-> <forbidden-substring|->
# Captures _wb_install_finish_message's output and checks it.
run_message() {
    local description="$1" want="$2" forbid="$3" out
    out="$(_wb_install_finish_message 2>&1)"
    if [[ "${out}" != *"done."* ]]; then
        fail "${description}: output has no 'done.': ${out}"
        return
    fi
    if [[ "${want}" != "-" && "${out}" != *"${want}"* ]]; then
        fail "${description}: expected '${want}' in: ${out}"
        return
    fi
    if [[ "${forbid}" != "-" && "${out}" == *"${forbid}"* ]]; then
        fail "${description}: did not expect '${forbid}' in: ${out}"
        return
    fi
    ok "${description}"
}

unset FAKE_PS_FAIL FAKE_PS_COMM _WB_WRAPPER_RELOADS

# ── 1. The wrapper will reload: nothing for the user to do ─────────────────
_tty_yes
_WB_WRAPPER_RELOADS=true
export _WB_WRAPPER_RELOADS
FAKE_PS_COMM="-zsh"
export FAKE_PS_COMM
run_message "marker set, tty: plain 'done.'" "-" "source"
unset _WB_WRAPPER_RELOADS

# ── 2. No terminal: nothing to load into ───────────────────────────────────
_tty_no
run_message "marker unset, no tty: plain 'done.'" "-" "source"

# ── 3–5. The shell is read from the parent process ─────────────────────────
_tty_yes
FAKE_PS_COMM="-zsh"
run_message "ps '-zsh' (login-shell dash) names ~/.zshrc" "source ~/.zshrc" "-"

FAKE_PS_COMM="/bin/zsh"
run_message "ps '/bin/zsh' (path) names ~/.zshrc" "source ~/.zshrc" "-"

FAKE_PS_COMM="bash"
run_message "ps 'bash' names ~/.bashrc" "source ~/.bashrc" "-"

# ── 6. ps fails: fall back to $SHELL ───────────────────────────────────────
FAKE_PS_FAIL=1
export FAKE_PS_FAIL
FAKE_PS_COMM=""
SHELL=/usr/bin/zsh run_message "ps fails, SHELL=zsh names ~/.zshrc" "source ~/.zshrc" "-"
unset FAKE_PS_FAIL

# ── 7. Parent isn't a shell (sudo, CI runner): fall back to $SHELL ─────────
FAKE_PS_COMM="sudo"
SHELL=/bin/bash run_message "ps 'sudo', SHELL=bash names ~/.bashrc" "source ~/.bashrc" "-"

# ── 8. Nothing usable anywhere: default to bash ────────────────────────────
FAKE_PS_COMM="fish"
SHELL="" run_message "ps 'fish', SHELL empty defaults to ~/.bashrc" "source ~/.bashrc" "-"

# ── 9–11. A parent wb process hands its answer down (D114) ─────────────────
# In a child 'wb apply' $PPID is the parent wb process, so ps would name
# bash for a zsh user. _WB_CALLING_SHELL_RC carries the parent's answer.
FAKE_PS_COMM="bash"
# shellcheck disable=SC2088  # a literal '~': the rc name is display text
_WB_CALLING_SHELL_RC="~/.zshrc" run_message "handed-down ~/.zshrc beats ps 'bash'" "source ~/.zshrc" "-"

FAKE_PS_COMM="zsh"
# shellcheck disable=SC2088  # a literal '~': the rc name is display text
_WB_CALLING_SHELL_RC="~/.bashrc" run_message "handed-down ~/.bashrc beats ps 'zsh'" "source ~/.bashrc" "-"

FAKE_PS_COMM="zsh"
_WB_CALLING_SHELL_RC="/etc/passwd" run_message "an unrecognised handed-down value is ignored" "source ~/.zshrc" "/etc/passwd"

# ── 12. The old fixed message is gone ───────────────────────────────────────
old_count="$(grep -c 'Start a new shell' "${WB}")"
if [[ "${old_count}" -eq 0 ]]; then
    ok "bin/wb no longer contains the old 'Start a new shell' text"
else
    fail "bin/wb still contains 'Start a new shell' (${old_count} line(s))"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
