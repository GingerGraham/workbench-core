#!/usr/bin/env bash
# tests/check-rc-stub-migration.sh — docs/decisions-log.md D64 acceptance
# check.
#
# Two halves: `_wb_write_rc_stub` (bin/wb) backing up real pre-existing rc
# content before ever appending the loader stub, and the persistent
# migration warning + prompt-fallback preclaim fix (lib/loader.sh) that
# reads what that backup step left behind.
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
export XDG_CACHE_HOME="${WORK}/cache"
mkdir -p "${HOME}"

# shellcheck source=bin/wb
source "${WB}" >/tmp/wb-rc-stub-source.log 2>&1

BACKUP_ROOT="${XDG_DATA_HOME}/workbench/backups"

# ── 1. A non-empty .bashrc with no marker yet is backed up, tagged
#    rc-stub, and the stub is still appended. ─────────────────────────────
echo "# my old prompt tooling, pre-workbench" > "${HOME}/.bashrc"
_wb_write_rc_stub "${HOME}/.bashrc" >/tmp/wb-rc-stub-1.log 2>&1
rc=$?
BAK1="$(find "${BACKUP_ROOT}" -name 'rc-stub-.bashrc.*' 2>/dev/null | head -1)"
if [[ "${rc}" -eq 0 ]] && [[ -n "${BAK1}" ]] \
    && [[ "$(cat "${BAK1}")" == "# my old prompt tooling, pre-workbench" ]]; then
    ok "a non-empty rc file with no marker is backed up under the shared backup root, tagged rc-stub"
else
    fail "expected a rc-stub-tagged backup of the pre-existing content — rc=${rc}, found: ${BAK1:-none}"
    cat /tmp/wb-rc-stub-1.log
fi
if grep -qF "# workbench-core loader" "${HOME}/.bashrc"; then
    ok "the loader stub is still appended after backing up the pre-existing content"
else
    fail "loader stub marker missing from .bashrc after backup"
fi

# ── 2. Re-running afterward creates no second backup — marker now present,
#    the gate no longer fires. ─────────────────────────────────────────────
BAK_COUNT_BEFORE="$(find "${BACKUP_ROOT}" -name 'rc-stub-.bashrc.*' 2>/dev/null | wc -l | tr -d ' ')"
_wb_write_rc_stub "${HOME}/.bashrc" >/tmp/wb-rc-stub-2.log 2>&1
BAK_COUNT_AFTER="$(find "${BACKUP_ROOT}" -name 'rc-stub-.bashrc.*' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${BAK_COUNT_AFTER}" -eq "${BAK_COUNT_BEFORE}" ]]; then
    ok "re-running _wb_write_rc_stub once the marker exists creates no second backup"
else
    fail "a second backup was created on re-run (before=${BAK_COUNT_BEFORE}, after=${BAK_COUNT_AFTER})"
fi

# ── 3. A genuinely empty (freshly touched) rc file produces no backup. ────
rm -rf "${BACKUP_ROOT}"
: > "${HOME}/.zshrc"
_wb_write_rc_stub "${HOME}/.zshrc" >/tmp/wb-rc-stub-3.log 2>&1
if [[ ! -d "${BACKUP_ROOT}" ]] || [[ -z "$(find "${BACKUP_ROOT}" -name 'rc-stub-.zshrc.*' 2>/dev/null)" ]]; then
    ok "a genuinely empty rc file produces no backup"
else
    fail "a backup was created for an empty rc file"
fi
if grep -qF "# workbench-core loader" "${HOME}/.zshrc"; then
    ok "the loader stub is still appended to an empty rc file"
else
    fail "loader stub marker missing from the empty .zshrc"
fi

# ── 4. .zshenv gets the same stub treatment (decision #6, parity with
#    dotfiles' shell_stubs list). ──────────────────────────────────────────
echo "# pre-existing zshenv content" > "${HOME}/.zshenv"
_wb_write_rc_stub "${HOME}/.zshenv" >/tmp/wb-rc-stub-4.log 2>&1
BAK_ZSHENV="$(find "${BACKUP_ROOT}" -name 'rc-stub-.zshenv.*' 2>/dev/null | head -1)"
if [[ -n "${BAK_ZSHENV}" ]] && grep -qF "# workbench-core loader" "${HOME}/.zshenv"; then
    ok "_wb_write_rc_stub handles .zshenv the same way as .bashrc/.zshrc"
else
    fail "'.zshenv' was not backed up/stubbed as expected"
    cat /tmp/wb-rc-stub-4.log
fi

# ── 5. A failed backup aborts the stub write — nothing is appended
#    unprotected (flag-back #4). Simulated by making the backup root
#    unwritable. ───────────────────────────────────────────────────────────
rm -rf "${BACKUP_ROOT}"
mkdir -p "$(dirname "${BACKUP_ROOT}")"
: > "${BACKUP_ROOT}"  # a plain file where a directory is expected — mkdir -p inside the backup helper fails
echo "# some other pre-existing content" > "${HOME}/.bashrc.failtest"
_wb_write_rc_stub "${HOME}/.bashrc.failtest" >/tmp/wb-rc-stub-5.log 2>&1
rc=$?
if [[ "${rc}" -ne 0 ]] && ! grep -qF "# workbench-core loader" "${HOME}/.bashrc.failtest"; then
    ok "a failed backup aborts the stub write rather than proceeding unprotected"
else
    fail "expected the stub write to abort when the backup failed (rc=${rc})"
    cat /tmp/wb-rc-stub-5.log
fi
rm -f "${BACKUP_ROOT}"

# ── 6. lib/loader.sh: the persistent migration warning fires while a
#    rc-stub-tagged backup exists, naming the file, and clears once it's
#    removed. Isolated with env -i, same pattern as
#    tests/check-prompt-reset-on-reload.sh. ────────────────────────────────
mkdir -p "${BACKUP_ROOT}/2026-01-01/0900"
echo "old content" > "${BACKUP_ROOT}/2026-01-01/0900/rc-stub-.bashrc.090000"

WARN_OUT="$(
    env -i \
        HOME="${HOME}" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
        PATH="${PATH}" \
        bash -c "source '${REPO_ROOT}/lib/loader.sh'" 2>&1
)"
if printf '%s\n' "${WARN_OUT}" | grep -q "Shell rc migration pending" \
    && printf '%s\n' "${WARN_OUT}" | grep -q "rc-stub-.bashrc.090000"; then
    ok "the persistent migration warning fires and names the specific backup file"
else
    fail "expected the migration warning naming the backup file, got:"
    printf '%s\n' "${WARN_OUT}"
fi

rm -rf "${BACKUP_ROOT}"
WARN_OUT2="$(
    env -i \
        HOME="${HOME}" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
        PATH="${PATH}" \
        bash -c "source '${REPO_ROOT}/lib/loader.sh'" 2>&1
)"
if ! printf '%s\n' "${WARN_OUT2}" | grep -q "Shell rc migration pending"; then
    ok "removing the rc-stub-tagged backup clears the warning on the next shell start"
else
    fail "the migration warning still fired after the backup was removed"
fi

# ── 7. A synthetic fixture that sets PROMPT_COMMAND (bash) before the
#    loader runs → the fallback does not override PS1 afterward. ─────────
PRECLAIM_OUT="$(
    env -i \
        HOME="${HOME}" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
        PATH="${PATH}" \
        bash <<INNER_EOF
        PROMPT_COMMAND="my_preexisting_hook"
        PS1='[preclaimed]\$ '
        source "${REPO_ROOT}/lib/loader.sh" >/dev/null 2>&1
        echo "\${PS1}"
INNER_EOF
)"
if [[ "${PRECLAIM_OUT}" == *"[preclaimed]"* ]]; then
    ok "a pre-existing PROMPT_COMMAND is detected and the prompt fallback does not override PS1"
else
    fail "the prompt fallback overrode PS1 despite a pre-existing PROMPT_COMMAND: '${PRECLAIM_OUT}'"
fi

# ── 8. Regression guard: a plain Fedora-style session (only /etc/bashrc's
#    own PS1 set, no PROMPT_COMMAND, no module claiming the prompt) still
#    gets workbench's own fallback prompt — the fix must not disable the
#    fallback for the ordinary/default case. ──────────────────────────────
PLAIN_OUT="$(
    env -i \
        HOME="${HOME}" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
        PATH="${PATH}" \
        bash <<INNER_EOF
        PS1='\u@\h \$ '
        source "${REPO_ROOT}/lib/loader.sh" >/dev/null 2>&1
        echo "ENGINE=\${WORKBENCH_PROMPT_ENGINE:-unset}"
INNER_EOF
)"
if [[ "${PLAIN_OUT}" == *"ENGINE=fallback"* ]]; then
    ok "the ordinary case (only a distro default PS1, no PROMPT_COMMAND) still gets workbench's own fallback prompt"
else
    fail "the fallback was unexpectedly skipped for the ordinary/default case: '${PLAIN_OUT}'"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
