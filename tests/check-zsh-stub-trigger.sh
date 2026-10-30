#!/usr/bin/env bash
# tests/check-zsh-stub-trigger.sh — docs/decisions-log.md D107 acceptance check.
#
# The zsh loader stubs (~/.zshrc, ~/.zshenv) are written when wb runs under
# zsh, when ~/.zshrc exists, or when the account's login shell is zsh — and
# 'wb tools install|upgrade' checks them again afterwards, so an installer
# that runs chsh leaves a working zsh behind. That refresh only happens on a
# host where 'wb install' has already written a stub.
#
# The login shell is faked: stub getent and dscl on PATH read it from a
# file, and a fixture installer writes that file the way chsh would update
# the passwd database. No real account is touched, and nothing reaches the
# host's package manager.
#
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# shellcheck disable=SC2015
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

MARKER="# workbench-core loader"

# ── Fake login-shell lookups ────────────────────────────────────────────────
# Both read ${FAKE_LOGIN_SHELL_FILE}. getent answers on Linux, dscl on
# macOS; _wb_login_shell picks one by uname, so both are stubbed.
export FAKE_LOGIN_SHELL_FILE="${WORK}/login-shell"
FAKE_BIN="${WORK}/fake-bin"
mkdir -p "${FAKE_BIN}"
cat > "${FAKE_BIN}/getent" <<'STUB'
#!/bin/sh
[ "$1" = "passwd" ] || exit 2
printf '%s:x:1000:1000::/home/%s:%s\n' "$2" "$2" "$(cat "${FAKE_LOGIN_SHELL_FILE}")"
STUB
cat > "${FAKE_BIN}/dscl" <<'STUB'
#!/bin/sh
printf 'UserShell: %s\n' "$(cat "${FAKE_LOGIN_SHELL_FILE}")"
STUB
chmod +x "${FAKE_BIN}/getent" "${FAKE_BIN}/dscl"
export PATH="${FAKE_BIN}:${PATH}"

set_login_shell() { printf '%s\n' "$1" > "${FAKE_LOGIN_SHELL_FILE}"; }

WB="${REPO_ROOT}/bin/wb"
# shellcheck source=bin/wb
source "${WB}" >"${WORK}/source.log" 2>&1
_wb_require modules/add.sh

reset_home() {
    rm -rf "${HOME}"
    mkdir -p "${HOME}"
}
has_stub() { grep -qF "${MARKER}" "$1" 2>/dev/null; }

# ── 1. _wb_login_shell reads the account's shell, not ${SHELL}. ────────────
set_login_shell /usr/bin/zsh
got="$(SHELL=/bin/bash _wb_login_shell)"
[[ "${got}" == "/usr/bin/zsh" ]] \
    && ok "_wb_login_shell reports the passwd/Directory Services shell (/usr/bin/zsh), not \${SHELL}" \
    || fail "_wb_login_shell printed '${got}', expected /usr/bin/zsh"

# ── 2. Login shell bash, no ~/.zshrc: only ~/.bashrc (unchanged). ──────────
reset_home
set_login_shell /bin/bash
_wb_write_rc_stubs >"${WORK}/w2.log" 2>&1
has_stub "${HOME}/.bashrc" && [[ ! -e "${HOME}/.zshrc" && ! -e "${HOME}/.zshenv" ]] \
    && ok "login shell bash, no ~/.zshrc: ~/.bashrc stubbed, no zsh files created" \
    || { fail "login shell bash: unexpected zsh files or missing .bashrc stub"; ls -la "${HOME}"; cat "${WORK}/w2.log"; }

# ── 3-4. Login shell zsh, no ~/.zshrc: both zsh stubs, right kinds. ────────
reset_home
set_login_shell /usr/bin/zsh
_wb_write_rc_stubs >"${WORK}/w3.log" 2>&1
has_stub "${HOME}/.zshrc" && has_stub "${HOME}/.zshenv" \
    && ok "login shell zsh, no ~/.zshrc: ~/.zshrc and ~/.zshenv created with the loader stub" \
    || { fail "login shell zsh: zsh stubs missing"; ls -la "${HOME}"; cat "${WORK}/w3.log"; }
grep -F "${MARKER}" "${HOME}/.zshenv" | grep -qF '[[ -o interactive ]] ||' \
    && ! grep -F "${MARKER}" "${HOME}/.zshrc" | grep -qF '[[ -o interactive ]]' \
    && ok "the new ~/.zshenv gets the non-interactive-only line, ~/.zshrc the plain one (D96)" \
    || { fail "stub kinds wrong"; cat "${HOME}/.zshrc" "${HOME}/.zshenv"; }

# ── 5. /bin/zsh counts too (merged-/usr spelling). ─────────────────────────
reset_home
set_login_shell /bin/zsh
_wb_write_rc_stubs >/dev/null 2>&1
has_stub "${HOME}/.zshrc" \
    && ok "login shell /bin/zsh is recognised as zsh" \
    || fail "login shell /bin/zsh: ~/.zshrc not stubbed"

# ── 6. A second run changes nothing. ───────────────────────────────────────
sum_before="$(cat "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.zshenv" | cksum)"
_wb_write_rc_stubs >"${WORK}/w6.log" 2>&1
sum_after="$(cat "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.zshenv" | cksum)"
[[ "${sum_before}" == "${sum_after}" ]] && ! grep -q "loader stub" "${WORK}/w6.log" \
    && ok "re-running _wb_write_rc_stubs changes nothing and logs nothing" \
    || { fail "second run changed the rc files or logged a write"; cat "${WORK}/w6.log"; }

# ── Fixture module for the 'wb tools' checks ───────────────────────────────
# make_module <module-name> <installers.sh content>
# A local bare repo with one installers file, registered with 'wb add'.
make_module() {
    local module="$1" content="$2" src="${WORK}/src-$1" bare="${WORK}/$1.git"
    git init -q --bare "${bare}"
    git clone -q "${bare}" "${src}" 2>/dev/null
    (
        cd "${src}" || exit 1
        git config user.email t@t.com
        git config user.name Test
        mkdir -p shell
        printf '%s\n' "${content}" > shell/installers.sh
        cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  installers:
    - src: shell/installers.sh
EOF
        git add -A && git commit -q -m v1
        git branch -M main
        git push -q origin main
        git tag v1.0.0 && git push -q origin v1.0.0
    )
    workbench_cmd_add "${module}" "${bare}" --private >"${WORK}/add-${module}.log" 2>&1
}

# fake-chsh  writes zsh as the login shell, as chsh -s would
# fails-7    exits 7 and changes nothing
# Quoted: expanded when the installer runs, not here.
# shellcheck disable=SC2016
make_module stub-tools '
install-fake-chsh() { printf "%s\n" /usr/bin/zsh > "${FAKE_LOGIN_SHELL_FILE}"; }
installed-fake-chsh() { return 0; }
install-fails-7() { exit 7; }
installed-fails-7() { return 0; }'

if [[ -s "${XDG_DATA_HOME}/workbench/modules/stub-tools/installers.list" ]]; then
    ok "fixture module registered"
else
    fail "fixture module did not register"
    cat "${WORK}/add-stub-tools.log"
fi

# installed_home: what 'wb install' leaves on a bash user's host —
# a stubbed ~/.bashrc and no zsh files.
installed_home() {
    reset_home
    printf '\n[ -f "x" ] && source "x"  %s\n' "${MARKER}" > "${HOME}/.bashrc"
}

# ── 8-9. The bug: chsh from an installer, then the zsh stubs appear. ───────
installed_home
set_login_shell /bin/bash
bash "${WB}" tools install fake-chsh </dev/null >"${WORK}/t8.log" 2>&1
rc=$?
[[ "${rc}" -eq 0 ]] && has_stub "${HOME}/.zshrc" && has_stub "${HOME}/.zshenv" \
    && ok "wb tools install fake-chsh: login shell now zsh, ~/.zshrc and ~/.zshenv stubbed in the same run" \
    || { fail "wb tools install fake-chsh (rc ${rc}): zsh stubs not written"; ls -la "${HOME}"; cat "${WORK}/t8.log"; }
installed_home
set_login_shell /bin/bash
bash "${WB}" tools upgrade fake-chsh </dev/null >"${WORK}/t9.log" 2>&1
has_stub "${HOME}/.zshrc" \
    && ok "wb tools upgrade refreshes the stubs too" \
    || { fail "wb tools upgrade fake-chsh: ~/.zshrc not stubbed"; cat "${WORK}/t9.log"; }

# ── 10. Never on a host where wb install hasn't run. ───────────────────────
reset_home
set_login_shell /bin/bash
bash "${WB}" tools install fake-chsh </dev/null >"${WORK}/t10.log" 2>&1
[[ ! -e "${HOME}/.bashrc" && ! -e "${HOME}/.zshrc" && ! -e "${HOME}/.zshenv" ]] \
    && ok "no existing stub: wb tools writes no rc file at all" \
    || { fail "wb tools wrote rc files on a host with no stub"; ls -la "${HOME}"; cat "${WORK}/t10.log"; }

# ── 11. The installer's exit status still stands. ──────────────────────────
installed_home
set_login_shell /usr/bin/zsh
bash "${WB}" tools install fails-7 </dev/null >"${WORK}/t11.log" 2>&1
rc=$?
[[ "${rc}" -eq 7 ]] && has_stub "${HOME}/.zshrc" \
    && ok "a failing installer still exits with its own status (7); the stub refresh still ran" \
    || { fail "wb tools install fails-7: rc ${rc}, expected 7"; cat "${WORK}/t11.log"; }

# ── 12. A host already in the broken state is repaired by convergence,
#    with no tool run: zsh is the login shell, ~/.bashrc is stubbed, there
#    is no ~/.zshrc. The real _wb_cmd_apply, in the form the timer runs it
#    after a core update (--skip-ansible, D20). Prerequisite installs, SSH
#    bootstrap and the scheduler are stubbed: a test must never reach the
#    host's package manager or systemd/launchd. ───────────────────────────
installed_home
set_login_shell /usr/bin/zsh
rc=0
(
    workbench_missing_shell_prereqs() { :; }
    workbench_install_shell_prereqs() { echo "TEST: prerequisite install attempted" >&2; return 1; }
    workbench_ssh_bootstrap_all() { :; }
    workbench_scheduler_install() { :; }
    _wb_cmd_apply --skip-ansible
) </dev/null >"${WORK}/t12.log" 2>&1 || rc=$?
has_stub "${HOME}/.zshrc" && has_stub "${HOME}/.zshenv" \
    && ! grep -q 'TEST: prerequisite install attempted' "${WORK}/t12.log" \
    && ok "wb apply --skip-ansible (the post-core-update path) repairs a host with zsh login shell and no ~/.zshrc" \
    || { fail "wb apply did not write the zsh stubs (rc ${rc})"; ls -la "${HOME}"; cat "${WORK}/t12.log"; }

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
