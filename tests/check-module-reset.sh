#!/usr/bin/env bash
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
mkdir -p "${HOME}"

# shellcheck source=bin/wb
source "${WB}" >/tmp/wb-module-reset-source.log 2>&1

# ── 0. workbench_deploy_copy_file symlink-safety fix, in isolation ────────
SNAP="${WORK}/snap-test"
mkdir -p "${SNAP}"
echo "ORIGINAL SNAPSHOT CONTENT" > "${SNAP}/tmux.conf"
mkdir -p "${WORK}/home-test"
ln -s "${SNAP}/tmux.conf" "${WORK}/home-test/tmux.conf"
echo "NEW SOURCE CONTENT" > "${WORK}/new-src.conf"
workbench_deploy_copy_file "${WORK}/new-src.conf" "${WORK}/home-test/tmux.conf" "true"
if [[ "$(cat "${SNAP}/tmux.conf")" == "ORIGINAL SNAPSHOT CONTENT" ]]; then
    ok "workbench_deploy_copy_file no longer corrupts a symlink's target on force copy"
else
    fail "workbench_deploy_copy_file still corrupted the symlink target: $(cat "${SNAP}/tmux.conf")"
fi
if [[ ! -L "${WORK}/home-test/tmux.conf" ]] && [[ "$(cat "${WORK}/home-test/tmux.conf")" == "NEW SOURCE CONTENT" ]]; then
    ok "workbench_deploy_copy_file leaves a real, detached file after force-copying over a stale symlink"
else
    fail "dest is still a symlink or has wrong content after force copy"
fi

# ── Fixture module: copy-mode tmux.conf/vimrc, one link-mode file. ─────────
SRC="${WORK}/src-mod"
BARE="${WORK}/mod.git"
mkdir -p "${SRC}"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}" 2>/dev/null
(
    cd "${SRC}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p files
    echo "WORKBENCH DEFAULT TMUX CONF" > files/tmux.conf
    echo "WORKBENCH DEFAULT VIMRC" > files/vimrc
    echo "LINK MODE FILE" > files/synced.conf
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main

deploy:
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    mode: copy
  - src: files/vimrc
    dest: ~/.vimrc
    mode: copy
  - src: files/synced.conf
    dest: ~/.config/synced.conf
    mode: link
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)
workbench_cmd_add reset-mod "${BARE}" --private >/tmp/wb-module-reset-add.log 2>&1

TMUX_DEST="${HOME}/.config/tmux/tmux.conf"
VIMRC_DEST="${HOME}/.vimrc"

if [[ "$(cat "${TMUX_DEST}" 2>/dev/null)" == "WORKBENCH DEFAULT TMUX CONF" ]]; then
    ok "fixture module's first sync deployed tmux.conf correctly"
else
    fail "fixture module's first sync did not deploy tmux.conf as expected"
    cat /tmp/wb-module-reset-add.log
fi

# ── 1. Usage errors ─────────────────────────────────────────────────────────
_wb_cmd_module_reset >/dev/null 2>&1; rc=$?
# shellcheck disable=SC2015
[[ "${rc}" -eq 2 ]] && ok "'wb module reset' with no args exits 2" || fail "expected exit 2, got ${rc}"

_wb_cmd_module_reset reset-mod >/dev/null 2>&1; rc=$?
# shellcheck disable=SC2015
[[ "${rc}" -eq 2 ]] && ok "'wb module reset <module>' with no target exits 2" || fail "expected exit 2, got ${rc}"

_wb_cmd_module_reset nonexistent-module tmux.conf >/tmp/wb-mr-unreg.log 2>&1; rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q "is not registered" /tmp/wb-mr-unreg.log; then
    ok "'wb module reset' on an unregistered module errors with the standard wording"
else
    fail "unregistered-module case did not behave as expected"
    cat /tmp/wb-mr-unreg.log
fi

# ── 2. Simulate a ruined tmux.conf, decline the reset — file stays ruined. ──
echo "USER RUINED THIS FILE" > "${TMUX_DEST}"
echo "n" | _wb_cmd_module_reset reset-mod tmux.conf >/tmp/wb-mr-decline.log 2>&1
if [[ "$(cat "${TMUX_DEST}")" == "USER RUINED THIS FILE" ]]; then
    ok "declining the confirmation leaves the ruined file untouched"
else
    fail "file was reset despite declining confirmation"
    cat /tmp/wb-mr-decline.log
fi

# ── 3. Confirm the reset — file restored to the workbench default. ─────────
echo "y" | _wb_cmd_module_reset reset-mod tmux.conf >/tmp/wb-mr-confirm.log 2>&1
if [[ "$(cat "${TMUX_DEST}")" == "WORKBENCH DEFAULT TMUX CONF" ]]; then
    ok "confirming the reset restores the workbench default content"
else
    fail "confirmed reset did not restore the default content"
    cat /tmp/wb-mr-confirm.log
fi

# ── 4. 'all' resets every copy-mode file, confirmation covers all of them. ──
echo "USER RUINED THIS FILE TOO" > "${TMUX_DEST}"
echo "USER RUINED VIMRC" > "${VIMRC_DEST}"
echo "y" | _wb_cmd_module_reset reset-mod all >/tmp/wb-mr-all.log 2>&1
if [[ "$(cat "${TMUX_DEST}")" == "WORKBENCH DEFAULT TMUX CONF" && "$(cat "${VIMRC_DEST}")" == "WORKBENCH DEFAULT VIMRC" ]]; then
    ok "'wb module reset <module> all' resets every copy-mode deploy file"
else
    fail "'all' did not reset every copy-mode file as expected"
    cat /tmp/wb-mr-all.log
fi

# ── 5. An unknown target name errors and lists what's available, untouched. ─
echo "y" | _wb_cmd_module_reset reset-mod nope.conf >/tmp/wb-mr-unknown.log 2>&1; rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q "tmux.conf" /tmp/wb-mr-unknown.log && grep -q "vimrc" /tmp/wb-mr-unknown.log; then
    ok "an unrecognised target name errors and lists the available names"
else
    fail "unknown-target case did not list available names as expected"
    cat /tmp/wb-mr-unknown.log
fi

# ── 6. A mode: link destination's basename is not offered as a reset
#    target — link-mode files stay out of scope for this command. ─────────
echo "y" | _wb_cmd_module_reset reset-mod synced.conf >/tmp/wb-mr-linkmode.log 2>&1; rc=$?
if [[ "${rc}" -ne 0 ]] && ! grep -qx "    synced.conf" /tmp/wb-mr-linkmode.log; then
    ok "a mode: link deploy file is correctly excluded from reset targets"
else
    fail "mode: link file was unexpectedly offered/accepted as a reset target"
    cat /tmp/wb-mr-linkmode.log
fi

# ── Second fixture module: two deploy[] entries sharing a basename, to
#    exercise the full-src-path disambiguation path. ───────────────────────
SRC2="${WORK}/src-mod2"
BARE2="${WORK}/mod2.git"
mkdir -p "${SRC2}"
git init -q --bare "${BARE2}"
git clone -q "${BARE2}" "${SRC2}" 2>/dev/null
(
    cd "${SRC2}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p files files/other
    echo "WORKBENCH DEFAULT TMUX CONF (primary)" > files/tmux.conf
    echo "WORKBENCH DEFAULT TMUX CONF (other)" > files/other/tmux.conf
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main

deploy:
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    mode: copy
  - src: files/other/tmux.conf
    dest: ~/.config/tmux/other/tmux.conf
    mode: copy
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)
workbench_cmd_add reset-mod2 "${BARE2}" --private >/tmp/wb-module-reset-add2.log 2>&1

PRIMARY_DEST="${HOME}/.config/tmux/tmux.conf"
OTHER_DEST="${HOME}/.config/tmux/other/tmux.conf"

# ── 7. A basename collision across two deploy[] entries is ambiguous and
#    names the full-src-path escape hatch instead of picking one. ─────────
echo "y" | _wb_cmd_module_reset reset-mod2 tmux.conf >/tmp/wb-mr-collision.log 2>&1; rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q "matches more than one" /tmp/wb-mr-collision.log \
    && grep -q "files/tmux.conf" /tmp/wb-mr-collision.log && grep -q "files/other/tmux.conf" /tmp/wb-mr-collision.log; then
    ok "a basename collision is reported as ambiguous and lists both full src paths"
else
    fail "basename collision did not report ambiguity with both src paths as expected"
    cat /tmp/wb-mr-collision.log
fi

# ── 8. Naming the full src path resolves a basename collision — this is
#    the path check 7 says to use, and it must actually work (it didn't,
#    prior to this fix: the fallback compared the typed target against
#    entries already filtered by basename equality, which a full src path
#    can never satisfy). ────────────────────────────────────────────────
echo "USER RUINED PRIMARY" > "${PRIMARY_DEST}"
echo "USER RUINED OTHER" > "${OTHER_DEST}"
echo "y" | _wb_cmd_module_reset reset-mod2 files/tmux.conf >/tmp/wb-mr-srcpath1.log 2>&1
if [[ "$(cat "${PRIMARY_DEST}")" == "WORKBENCH DEFAULT TMUX CONF (primary)" && "$(cat "${OTHER_DEST}")" == "USER RUINED OTHER" ]]; then
    ok "naming the full src path resolves a basename collision and resets only that one file"
else
    fail "full-src-path disambiguation did not reset exactly the targeted file"
    cat /tmp/wb-mr-srcpath1.log
fi

echo "y" | _wb_cmd_module_reset reset-mod2 files/other/tmux.conf >/tmp/wb-mr-srcpath2.log 2>&1
if [[ "$(cat "${OTHER_DEST}")" == "WORKBENCH DEFAULT TMUX CONF (other)" ]]; then
    ok "the second colliding entry's full src path resolves independently"
else
    fail "the second colliding entry's full src path did not reset as expected"
    cat /tmp/wb-mr-srcpath2.log
fi

# ── 9. A partial failure across a multi-file reset is reported, not
#    swallowed as success — one entry's snapshot src is removed so its
#    cp genuinely fails (root in this sandbox defeats a permissions-based
#    failure, so this is a real, privilege-independent one instead). ─────
CURRENT_DIR2="$(workbench_module_current_dir reset-mod2)"
rm -f "${CURRENT_DIR2}/files/tmux.conf"
echo "USER RUINED PRIMARY AGAIN" > "${PRIMARY_DEST}"
echo "USER RUINED OTHER AGAIN" > "${OTHER_DEST}"
echo "y" | _wb_cmd_module_reset reset-mod2 all >/tmp/wb-mr-partial.log 2>&1; rc=$?
if [[ "${rc}" -ne 0 ]] && [[ "$(cat "${OTHER_DEST}")" == "WORKBENCH DEFAULT TMUX CONF (other)" ]] \
    && [[ "$(cat "${PRIMARY_DEST}")" == "USER RUINED PRIMARY AGAIN" ]]; then
    ok "a partial failure across a multi-file reset is reported with a non-zero exit, not silently swallowed"
else
    fail "partial failure was not reported correctly (exit ${rc})"
    cat /tmp/wb-mr-partial.log
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
