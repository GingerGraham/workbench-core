#!/usr/bin/env bash
# tests/check-wb-uninstall.sh — docs/decisions-log.md D108.
#
# 'wb uninstall' removes core and only core, runs from the snapshot it deletes,
# leaves modules and their config working, writes notes whose commands really
# do remove what's left, and a reinstall brings the modules back.
#
# Core is a real copy of this checkout under modules/core, as bootstrap.sh
# leaves it, so the self-delete is exercised for real. systemctl and launchctl
# are stubs, and reinstall stubs prerequisites and the scheduler: a test must
# never reach the host's services or package manager.
#
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# SC2016: '$HOME' in expected text is literal.
# SC2329: converge()'s stubs are called by the function under test.
# SC2031: rc is only read after wb(), which sets it in this shell.
# SC2088: ~/ in expected text and messages is literal.
# shellcheck disable=SC2015,SC2016,SC2329,SC2031,SC2088
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
mkdir -p "${HOME}/.ssh" "${WORK}/fake-bin"

export SERVICE_LOG="${WORK}/services.log"
for stub in systemctl launchctl; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "${SERVICE_LOG}"\nexit 0\n' "${stub}" > "${WORK}/fake-bin/${stub}"
    chmod +x "${WORK}/fake-bin/${stub}"
done
export PATH="${WORK}/fake-bin:${PATH}"

MODULES="${XDG_DATA_HOME}/workbench/modules"
BACKUPS="${XDG_DATA_HOME}/workbench/backups"
NOTES="${XDG_DATA_HOME}/workbench/REMOVAL-NOTES.md"
NOTES_LINK="${HOME}/workbench-removal-notes.md"
CORE_SNAP="${MODULES}/core/snapshots/v9.9.9-abcdef0"
WB="${MODULES}/core/current/bin/wb"
OUT="${WORK}/out.log"
ERR="${WORK}/err.log"

wb() {
    rc=0
    bash "${WB}" "$@" >"${OUT}" 2>"${ERR}" </dev/null || rc=$?
}

# What bootstrap.sh leaves on disk.
install_core() {
    mkdir -p "${CORE_SNAP}"
    (cd "${REPO_ROOT}" && tar --exclude=.git -cf - .) | (cd "${CORE_SNAP}" && tar -xf -)
    ln -sfn "${CORE_SNAP}" "${MODULES}/core/current"
    cat > "${MODULES}/core/sync.conf" <<CONF
REPO_URL=https://github.com/GingerGraham/workbench-core.git
PRIVATE=false
TRACK_MODE=tag:v9.9.9
TRACK_REF=v9.9.9
REGISTERED=true
SYNC_ENABLED=false
RESOLVED_SHA=abcdef0
CONF
}

# What 'wb install' does after that. The real function; only what would reach
# the host is stubbed.
converge() {
    (
        # shellcheck source=bin/wb
        source "${WB}"
        workbench_missing_shell_prereqs() { :; }
        workbench_install_shell_prereqs() { echo "TEST: prerequisite install attempted" >&2; return 1; }
        workbench_ssh_bootstrap_all() { :; }
        workbench_scheduler_install() { :; }
        _wb_cmd_apply --skip-ansible
    ) </dev/null >"${WORK}/converge.log" 2>&1
}

new_shell() {
    env HOME="${HOME}" XDG_DATA_HOME="${XDG_DATA_HOME}" XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
        PATH="${PATH}" bash --rcfile "${HOME}/.bashrc" -ic "$1" 2>"${WORK}/shell-err.log" </dev/null
}

# ── Fixture: the user's own config, and a module that touches it ───────────
# Two blank lines in a row: stripping the loader line keeps them.
printf '# my bashrc\n\n\nalias ll="ls -l"\n' > "${HOME}/.bashrc"
BASHRC_BEFORE="$(cksum < "${HOME}/.bashrc")"
printf '# my zshrc\n' > "${WORK}/real-zshrc"
ln -s "${WORK}/real-zshrc" "${HOME}/.zshrc"
printf '[user]\n\tname = Mine\n' > "${HOME}/.gitconfig"
printf 'THEIR CONF\n' > "${HOME}/.demo.conf"
# SSH as lib/ssh/bootstrap.sh leaves it (the bootstrap itself is stubbed), with
# a file of the user's in config.d and a second private module's entry.
printf 'Include ~/.ssh/config.d/*.conf\n\nHost example\n  User me\n' > "${HOME}/.ssh/config"
mkdir -p "${HOME}/.ssh/config.d"
printf '# workbench-core private-module deploy keys\n\nHost workbench-demo\n    HostName github.com\n    User git\n\nHost workbench-other\n    HostName github.com\n    User git\n' > "${HOME}/.ssh/config.d/10-workbench.conf"
printf 'Host mine\n  User me\n' > "${HOME}/.ssh/config.d/20-mine.conf"
SSH_BEFORE="$(cksum < "${HOME}/.ssh/config")"
mkdir -p "${XDG_CONFIG_HOME}/workbench/local"
printf 'MY_OVERRIDE=1\n' > "${XDG_CONFIG_HOME}/workbench/local/mine.sh"

SRC="${WORK}/src"
BARE="${WORK}/bare.git"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}" 2>/dev/null
git -C "${SRC}" config user.email t@t.com
git -C "${SRC}" config user.name Test
mkdir -p "${SRC}/files" "${SRC}/shell"
printf 'copied\n' > "${SRC}/files/copied"
printf 'edited\n' > "${SRC}/files/edited"
printf 'linked\n' > "${SRC}/files/linked"
printf 'MODULE CONF\n' > "${SRC}/files/demo.conf"
printf '[demo]\n\tsetting = from-module\n' > "${SRC}/files/gitconfig"
printf '[demo]\n\tlast = from-module\n' > "${SRC}/files/gitconfig-last"
printf 'demo_fn() { echo demo-fn-ran; }\n' > "${SRC}/shell/demo.sh"
cat > "${SRC}/shell/installers.sh" <<'SH'
install-present-tool() { :; }
installed-present-tool() { return 0; }
install-absent-tool() { :; }
installed-absent-tool() { return 1; }
SH
cat > "${SRC}/workbench.yml" <<'YAML'
version: 2
core_api: ">=1.0 <99.0"
deploy:
  - src: files/copied
    dest: ~/.config/demo/copied
  - src: files/edited
    dest: ~/.config/demo/edited
  - src: files/linked
    dest: ~/.config/demo/linked
    mode: link
  - src: files/demo.conf
    dest: ~/.demo.conf
register:
  shell:
    - src: shell/demo.sh
      tier: tools
  installers:
    - src: shell/installers.sh
  getters:
    - name: demo
      function: get-demo-functions
      label: "Demo helper functions"
layers:
  - tool: gitconfig
    src: files/gitconfig
  - tool: gitconfig
    src: files/gitconfig-last
    position: over
YAML
git -C "${SRC}" add -A
git -C "${SRC}" commit -q -m v1
git -C "${SRC}" branch -qM main
git -C "${SRC}" tag v1.0.0
git -C "${SRC}" push -q origin main v1.0.0

mkdir -p "${MODULES}/core"
install_core
converge
grep -qF '# workbench-core loader' "${HOME}/.bashrc" \
    && grep -qF '# workbench-core loader' "${WORK}/real-zshrc" \
    && [[ -L "${HOME}/.local/bin/wb" ]] \
    && ok "fixture: loader lines and the wb link are in place" \
    || { fail "fixture convergence"; cat "${WORK}/converge.log"; }

wb add demo "${BARE}" --private --use-files --yes
[[ "${rc}" -eq 0 && -f "${MODULES}/demo/sync.conf" ]] \
    && [[ "$(cat "${HOME}/.demo.conf")" == "MODULE CONF" ]] \
    && ok "fixture: module added, replacing a file of the user's" \
    || { fail "wb add (rc ${rc})"; cat "${OUT}" "${ERR}"; }
printf 'my edit\n' >> "${HOME}/.config/demo/edited"
touch "${HOME}/.ssh/workbench-demo" "${HOME}/.ssh/workbench-demo.pub"

[[ "$(new_shell 'demo_fn')" == *demo-fn-ran* ]] \
    && ok "fixture: the module's function runs in a new shell" \
    || { fail "fixture: demo_fn not loaded"; cat "${WORK}/shell-err.log"; }

# The timer, as 'wb scheduler enable' leaves it on this OS: a launchd agent on
# macOS, systemd user units elsewhere.
if [[ "$(uname -s)" == "Darwin" ]]; then
    TIMER_FILES="${HOME}/Library/LaunchAgents/com.workbench.sync.plist"
    mkdir -p "${HOME}/Library/LaunchAgents"
else
    UNIT_DIR="${XDG_CONFIG_HOME}/systemd/user"
    TIMER_FILES="${UNIT_DIR}/workbench-sync.timer ${UNIT_DIR}/workbench-sync.service"
    mkdir -p "${UNIT_DIR}"
fi
for timer_file in ${TIMER_FILES}; do
    touch "${timer_file}"
done

# ── wb remove core refuses ─────────────────────────────────────────────────
wb remove core
[[ "${rc}" -ne 0 ]] && grep -q 'wb uninstall' "${ERR}" && [[ "$(grep '^REGISTERED=' "${MODULES}/core/sync.conf")" == "REGISTERED=true" ]] \
    && ok "'wb remove core' refuses and points to 'wb uninstall'" \
    || { fail "'wb remove core' (rc ${rc})"; cat "${OUT}" "${ERR}"; }

# ── Refuses without a terminal or --yes ────────────────────────────────────
wb uninstall
[[ "${rc}" -ne 0 && -d "${MODULES}/core" && ! -e "${NOTES}" ]] \
    && ok "no terminal and no --yes: refuses, nothing changed" \
    || { fail "uninstall without --yes (rc ${rc})"; cat "${OUT}" "${ERR}"; }

# ── --dry-run ──────────────────────────────────────────────────────────────
wb uninstall --dry-run
[[ "${rc}" -eq 0 && -d "${MODULES}/core" && ! -e "${NOTES}" && ! -L "${NOTES_LINK}" ]] \
    && grep -qF '# workbench-core loader' "${HOME}/.bashrc" \
    && grep -q '### demo' "${OUT}" \
    && ok "--dry-run shows the notes and changes nothing" \
    || { fail "--dry-run (rc ${rc})"; cat "${OUT}" "${ERR}"; }
grep -q 'wb remove demo --restore' "${OUT}" \
    && ok "the preview offers 'wb remove <name> --restore' while it still exists" \
    || { fail "preview doesn't mention --restore"; cat "${OUT}"; }

# A module the user had already removed with 'wb remove': deregistered, but its
# state, installers.list and installed tool are still there.
mkdir -p "${MODULES}/gone/snapshots/v1.0.0-1234567"
ln -sfn "${MODULES}/gone/snapshots/v1.0.0-1234567" "${MODULES}/gone/current"
printf 'installed-gone-tool() { return 0; }\n' > "${MODULES}/gone/snapshots/v1.0.0-1234567/installers.sh"
printf '%s|install-gone-tool|gone-tool\n' "${MODULES}/gone/current/installers.sh" > "${MODULES}/gone/installers.list"
printf 'REPO_URL=https://example.com/gone.git\nTRACK_MODE=latest\nTRACK_REF=v1.0.0\nREGISTERED=false\n' > "${MODULES}/gone/sync.conf"

# ── The real thing, from inside the snapshot it deletes ────────────────────
: > "${SERVICE_LOG}"
wb uninstall --yes
[[ "${rc}" -eq 0 ]] && [[ ! -s "${ERR}" ]] \
    && ok "runs to the end with no errors, though it deleted its own script" \
    || { fail "uninstall (rc ${rc})"; cat "${OUT}" "${ERR}"; }
grep -q 'demo' "${OUT}" && grep -q 'left behind on purpose' "${OUT}" && grep -qF '~/workbench-removal-notes.md' "${OUT}" && grep -q 'new terminal' "${OUT}" \
    && ok "the closing message names the modules, says what was left on purpose, points to the notes and the next step" \
    || { fail "closing message"; cat "${OUT}"; }
[[ -L "${NOTES_LINK}" && "$(readlink "${NOTES_LINK}")" == "${NOTES}" && -f "${NOTES}" ]] \
    && ok "the notes are one file in workbench's data directory, linked from ~/workbench-removal-notes.md" \
    || { fail "notes link"; ls -la "${NOTES_LINK}" "${NOTES}" 2>&1; }

[[ ! -e "${MODULES}/core" && ! -e "${HOME}/.local/bin/wb" && ! -e "${XDG_CONFIG_HOME}/workbench/core" && ! -e "${XDG_CACHE_HOME}/workbench" ]] \
    && ok "core's directory, the wb link, core's config and the cache are gone" \
    || { fail "core leftovers"; ls -la "${MODULES}" "${HOME}/.local/bin" 2>&1; }
[[ "$(cksum < "${HOME}/.bashrc")" == "${BASHRC_BEFORE}" ]] \
    && ok "~/.bashrc is back to exactly what it was" \
    || { fail "~/.bashrc differs"; cat "${HOME}/.bashrc"; }
[[ -L "${HOME}/.zshrc" ]] && [[ "$(cat "${WORK}/real-zshrc")" == "# my zshrc" ]] \
    && ok "a symlinked ~/.zshrc stays a symlink, with the loader line gone" \
    || { fail "~/.zshrc"; ls -la "${HOME}/.zshrc"; cat "${WORK}/real-zshrc"; }
timer_left=""
for timer_file in ${TIMER_FILES}; do
    [[ -e "${timer_file}" ]] && timer_left="${timer_left} ${timer_file}"
done
[[ -z "${timer_left}" ]] \
    && ok "the timer is gone" \
    || { fail "timer files left:${timer_left}"; cat "${SERVICE_LOG}"; }
if [[ "$(uname -s)" != "Darwin" ]]; then
    grep -q 'stop workbench-sync.service' "${SERVICE_LOG}" \
        && ok "a sync already running is stopped" \
        || { fail "service not stopped"; cat "${SERVICE_LOG}"; }
else
    grep -q 'launchctl unload' "${SERVICE_LOG}" \
        && ok "the launchd agent is unloaded before its file is removed" \
        || { fail "launchd agent not unloaded"; cat "${SERVICE_LOG}"; }
fi

# ── What stayed ────────────────────────────────────────────────────────────
[[ -f "${MODULES}/demo/sync.conf" && -d "${BACKUPS}" && -f "${XDG_CONFIG_HOME}/workbench/local/mine.sh" ]] \
    && [[ "$(cksum < "${HOME}/.ssh/config")" == "${SSH_BEFORE}" ]] \
    && ok "the module, backups, the user's overrides and SSH config are untouched" \
    || fail "something that should have stayed didn't"
[[ "$(git config --global --includes --get demo.setting)" == "from-module" ]] \
    && [[ "$(cat "${HOME}/.config/demo/linked")" == "linked" ]] \
    && [[ "$(cat "${HOME}/.config/demo/copied")" == "copied" ]] \
    && ok "the module's config block, link and copied file still work" \
    || fail "module config stopped working"
out="$(new_shell 'type demo_fn >/dev/null 2>&1 && echo present || echo absent')"
[[ "${out}" == *absent* ]] && ! grep -qi 'workbench\|no such file' "${WORK}/shell-err.log" \
    && ok "a new shell starts clean, without the module's function" \
    || { fail "new shell: ${out}"; cat "${WORK}/shell-err.log"; }

# ── The notes ──────────────────────────────────────────────────────────────
note_has() {
    grep -qF -- "$1" "${NOTES}" \
        && ok "notes: $2" \
        || { fail "notes missing: $2 ($1)"; cat "${NOTES}"; }
}
note_has '### demo' "a section for the module"
note_has 'Version: v1.0.0' "its version"
note_has 'demo.sh' "the shell file that stopped"
note_has 'Demo helper functions' "what that shell content was for"
note_has '`~/.gitconfig`: a marked workbench block. Your own settings in that file win over it.' "the block the user's settings override"
note_has '`~/.gitconfig`: a marked workbench block, placed so it wins' "the block that overrides the user's settings"
note_has '`~/.ssh/workbench-demo`' "the deploy key"
note_has '`~/.config/demo/linked`: a link' "the link still applying"
note_has '`~/.config/demo/copied`: a copied file.' "the copied file"
note_has "\`~/.config/demo/edited\`: a copied file you've changed" "the file the user edited"
note_has '`~/.demo.conf`, as it was before' "where the user's original is"
note_has 'present-tool' "software found on the machine"
grep -q 'absent-tool' "${NOTES}" \
    && fail "notes list a tool that isn't installed" \
    || ok "notes: leave out software that isn't there"
note_has 'bootstrap.sh' "how to come back"
note_has 'Removing everything' "how to remove everything"
note_has '## Left behind on purpose' "a section for what was left on purpose"
note_has "**Why it was left:** your tools may be relying on it right now" "why module config was left"
note_has "**Why it was left:** it holds your own files" "why backups were left"
note_has "**Why it was left:** it holds your overrides" "why workbench settings were left"
note_has '### SSH configuration' "the SSH config left behind"
note_has "**Why it was left:** SSH reads the whole of" "why SSH config was left"
note_has '`20-mine.conf`' "the user's own file in ~/.ssh/config.d"
note_has '### Software installed through workbench' "the software left behind"
note_has 'present-tool (demo)' "which module the software came with"
note_has 'gone-tool (gone)' "software of a module the user had already removed"
note_has "You had already deregistered this module with 'wb remove'." "a module the user had already removed"
note_has "**If you don't want it:**" "how to remove what was left"
note_has '~/workbench-removal-notes.md' "where the link to the notes is"
! grep -q 'curl[^|]*|[[:space:]]*bash' "${NOTES}" \
    && ok "notes: bootstrap is download-then-run" \
    || fail "notes pipe curl into bash"

# ── Coming back ────────────────────────────────────────────────────────────
install_core
converge
out="$(new_shell 'demo_fn')"
[[ "${out}" == *demo-fn-ran* ]] && [[ ! -e "${NOTES}" && ! -L "${NOTES_LINK}" ]] && [[ -L "${HOME}/.local/bin/wb" ]] \
    && ok "reinstalling brings the module back on the same state, and clears the notes and their link" \
    || { fail "reinstall: ${out}"; cat "${WORK}/converge.log" "${WORK}/shell-err.log"; }

# ── The notes' own commands really remove what's left ──────────────────────
# Through the wb() shell wrapper this time, as a person runs it.
out="$(new_shell 'wb uninstall --yes; echo "rc=$?"')"
[[ "${out}" == *rc=0* ]] && ! grep -q 'failed to reload\|No such file' "${WORK}/shell-err.log" && [[ -f "${NOTES}" ]] \
    && ok "from a shell with workbench loaded: the wrapper doesn't try to reload what's gone" \
    || { fail "uninstall through the wrapper: ${out}"; cat "${WORK}/shell-err.log"; }
awk '/^### demo/ { in_module = 1 } in_module && /^```sh/ { in_code = 1; next } in_code && /^```/ { exit } in_code { print }' \
    "${NOTES}" > "${WORK}/demo-cleanup.sh"
bash -eu "${WORK}/demo-cleanup.sh" >"${WORK}/cleanup.log" 2>&1 \
    && ok "the module's cleanup commands run without error" \
    || { fail "cleanup commands"; cat "${WORK}/demo-cleanup.sh" "${WORK}/cleanup.log"; }
! grep -q 'workbench' "${HOME}/.gitconfig" && [[ "$(git config --global --get user.name)" == "Mine" ]] \
    && ok "cleanup: the block is gone from ~/.gitconfig and the user's settings remain" \
    || { fail "cleanup: ~/.gitconfig"; cat "${HOME}/.gitconfig"; }
[[ "$(cat "${HOME}/.demo.conf")" == "THEIR CONF" ]] \
    && ok "cleanup: the user's original file is back" \
    || { fail "cleanup: original"; cat "${HOME}/.demo.conf"; }
[[ ! -e "${HOME}/.config/demo/copied" && ! -L "${HOME}/.config/demo/linked" && ! -e "${MODULES}/demo" && ! -e "${HOME}/.ssh/workbench-demo" ]] \
    && ok "cleanup: the module's files, link, directory and deploy key are gone" \
    || { fail "cleanup leftovers"; ls -la "${HOME}/.config/demo" "${MODULES}" 2>&1; }
! grep -q 'workbench-demo' "${HOME}/.ssh/config.d/10-workbench.conf" && grep -qx 'Host workbench-other' "${HOME}/.ssh/config.d/10-workbench.conf" \
    && ok "cleanup: the module's SSH host entry is gone, another module's stays" \
    || { fail "cleanup: SSH host entry"; cat "${HOME}/.ssh/config.d/10-workbench.conf"; }

# The SSH commands, as a person would run them: once with a file of the user's
# still in ~/.ssh/config.d, then again after they've moved it.
awk '/^### SSH configuration/ { in_ssh = 1 } in_ssh && /^```sh/ { in_code = 1; next } in_code && /^```/ { exit } in_code { print }' \
    "${NOTES}" > "${WORK}/ssh-cleanup.sh"
bash -eu "${WORK}/ssh-cleanup.sh" >"${WORK}/cleanup.log" 2>&1 \
    && [[ ! -e "${HOME}/.ssh/config.d/10-workbench.conf" && -f "${HOME}/.ssh/config.d/20-mine.conf" ]] \
    && grep -qxF 'Include ~/.ssh/config.d/*.conf' "${HOME}/.ssh/config" && grep -q 'still has other files' "${WORK}/cleanup.log" \
    && ok "SSH cleanup: workbench's file goes; the folder and Include line stay while the user has a file there" \
    || { fail "SSH cleanup with the user's file present"; cat "${WORK}/ssh-cleanup.sh" "${WORK}/cleanup.log"; ls -la "${HOME}/.ssh/config.d"; cat "${HOME}/.ssh/config"; }
rm -f "${HOME}/.ssh/config.d/20-mine.conf"
bash -eu "${WORK}/ssh-cleanup.sh" >"${WORK}/cleanup.log" 2>&1 \
    && [[ ! -e "${HOME}/.ssh/config.d" ]] && ! grep -q 'config.d' "${HOME}/.ssh/config" \
    && grep -qx 'Host example' "${HOME}/.ssh/config" \
    && ok "SSH cleanup: with the folder empty, it and the Include line go, and the rest of ~/.ssh/config stays" \
    || { fail "SSH cleanup with the folder empty"; cat "${WORK}/cleanup.log"; cat "${HOME}/.ssh/config"; }
out="$(new_shell 'echo clean')"
[[ "${out}" == *clean* ]] && ! grep -qi 'workbench\|no such file' "${WORK}/shell-err.log" \
    && ok "cleanup: a new shell still starts clean" \
    || { fail "shell after cleanup"; cat "${WORK}/shell-err.log"; }

# ── Someone else's ~/.local/bin/wb and ~/workbench-removal-notes.md ────────
install_core
converge
rm -f "${HOME}/.local/bin/wb"
ln -s /bin/true "${HOME}/.local/bin/wb"
printf 'my own notes\n' > "${NOTES_LINK}"
wb uninstall --yes
[[ -L "${HOME}/.local/bin/wb" && "$(readlink "${HOME}/.local/bin/wb")" == "/bin/true" ]] \
    && ok "a ~/.local/bin/wb that isn't core's is left alone" \
    || fail "removed someone else's ~/.local/bin/wb"
[[ ! -L "${NOTES_LINK}" && "$(cat "${NOTES_LINK}")" == "my own notes" && -f "${NOTES}" ]] \
    && grep -q 'REMOVAL-NOTES.md' "${OUT}" \
    && ok "a file of the user's at ~/workbench-removal-notes.md is left alone, and the message points to the notes themselves" \
    || { fail "user's ~/workbench-removal-notes.md"; cat "${OUT}" "${ERR}"; ls -la "${NOTES_LINK}"; }
install_core
converge
[[ -f "${NOTES_LINK}" && ! -e "${NOTES}" ]] \
    && ok "reinstalling leaves a file of the user's at that path alone" \
    || fail "reinstall removed the user's ~/workbench-removal-notes.md"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
