#!/usr/bin/env bash
# tests/check-files-cli.sh — D81: the 'wb files' command group, '--use-files'
# on 'wb add', 'wb remove --restore', and 'wb module reset' as an alias of
# 'wb files use' — all driven through bin/wb as a subprocess, stdin piped
# (never a terminal), against local bare-repo fixture modules.
#
# SC2088: '~/...' is quoted on purpose — the CLI accepts the literal
#         ~/-form dest as well as the expanded path.
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom; ok()
#         only echoes and cannot fail.
# shellcheck disable=SC2088,SC2015
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

BACKUPS="${XDG_DATA_HOME}/workbench/backups"
MODULES="${XDG_DATA_HOME}/workbench/modules"
OUT="${WORK}/out.log"

# wb <args...> — bin/wb as a subprocess, stdin from /dev/null unless the
# caller redirects it; output to ${OUT}, exit code in ${rc}.
wb() {
    rc=0
    bash "${WB}" "$@" >"${OUT}" 2>&1 || rc=$?
}

# new_repo <dir> — a bare repo plus a working clone at <dir>/src
new_repo() {
    git init -q --bare "$1/m.git"
    git clone -q "$1/m.git" "$1/src" 2>/dev/null
    git -C "$1/src" config user.email t@t.com
    git -C "$1/src" config user.name Test
}

# release <dir> <tag> — commit everything in <dir>/src and tag it
release() {
    git -C "$1/src" add -A
    git -C "$1/src" commit -q -m "$2"
    git -C "$1/src" branch -M main
    git -C "$1/src" push -q origin main 2>/dev/null
    git -C "$1/src" tag "$2"
    git -C "$1/src" push -q origin "$2" 2>/dev/null
}

conf_of() { grep "^$2=" "${MODULES}/$1/sync.conf" 2>/dev/null | cut -d= -f2; }

# ── Fixture: a copy-mode module ─────────────────────────────────────────────
CM="${WORK}/cli-mod"
new_repo "${CM}"
mkdir -p "${CM}/src/files/a" "${CM}/src/files/b"
echo "WB TMUX" > "${CM}/src/files/tmux.conf"
echo "WB VIMRC" > "${CM}/src/files/vimrc"
echo "WB STARSHIP" > "${CM}/src/files/starship.toml"
echo "WB A" > "${CM}/src/files/a/x.conf"
echo "WB B" > "${CM}/src/files/b/x.conf"
cat > "${CM}/src/workbench.yml" <<'EOF'
version: 2
deploy:
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    yield_to: [~/.tmux.conf]
  - src: files/vimrc
    dest: ~/.vimrc
  - src: files/starship.toml
    dest: ~/.config/starship.toml
  - src: files/a/x.conf
    dest: ~/.config/cli/a/x.conf
  - src: files/b/x.conf
    dest: ~/.config/cli/b/x.conf
EOF
release "${CM}" v1.0.0

TMUX_DEST="${HOME}/.config/tmux/tmux.conf"
VIMRC="${HOME}/.vimrc"
STARSHIP="${HOME}/.config/starship.toml"
echo "THEIR TMUX" > "${HOME}/.tmux.conf"

# ── 0. --use-files without a terminal and without --yes refuses before
#    registering anything. ────────────────────────────────────────────────
wb add cli-mod "${CM}/m.git" --private --use-files </dev/null
[[ "${rc}" -eq 1 && ! -f "${MODULES}/cli-mod/sync.conf" && ! -e "${TMUX_DEST}" ]] \
    && ok "add --use-files on non-TTY without --yes refuses before registering" || { fail "add --use-files did not refuse (rc ${rc})"; cat "${OUT}"; }

# ── 2. With ~/.tmux.conf present, 'wb add --use-files --yes' writes the
#    module's tmux.conf and moves ~/.tmux.conf into backups. ─────────────
wb add cli-mod "${CM}/m.git" --private --use-files --yes </dev/null
MOVED="$(find "${BACKUPS}" -name 'cli-mod-.tmux.conf.*' 2>/dev/null | head -1)"
[[ "${rc}" -eq 0 && "$(cat "${TMUX_DEST}" 2>/dev/null)" == "WB TMUX" && ! -e "${HOME}/.tmux.conf" \
    && -n "${MOVED}" && "$(cat "${MOVED}")" == "THEIR TMUX" ]] \
    && ok "add --use-files --yes: module tmux.conf written, ~/.tmux.conf moved into backups" || { fail "add --use-files (rc ${rc})"; cat "${OUT}"; }

# ── 1. status: an untouched file is "workbench default", an edited one
#    "your edits". ───────────────────────────────────────────────────────
echo "MY STARSHIP" > "${STARSHIP}"
wb files status cli-mod
grep -E '~/\.vimrc +copy +managed +workbench default' "${OUT}" >/dev/null \
    && grep -E '~/\.config/starship\.toml +copy +managed +your edits' "${OUT}" >/dev/null \
    && [[ "${rc}" -eq 0 ]] \
    && ok "files status: seeded file is 'workbench default', hand-edited one is 'your edits'" || { fail "files status rows"; cat "${OUT}"; }
grep -q "Host default: managed" "${OUT}" \
    && ok "files status names the host default" || fail "files status: no host-default line"

# ── 8. diff exits 0 and shows both labels for a copy target. ───────────────
wb files diff cli-mod starship.toml
[[ "${rc}" -eq 0 ]] && grep -q -- "--- yours: ~/.config/starship.toml" "${OUT}" && grep -q -- "+++ cli-mod default" "${OUT}" \
    && ok "files diff: exit 0, labelled 'yours' and '<module> default'" || { fail "files diff (rc ${rc})"; cat "${OUT}"; }

# ── 4. policy follow without --yes on non-TTY refuses; file and policy
#    unchanged. ────────────────────────────────────────────────────────────
wb files policy cli-mod starship.toml follow </dev/null
[[ "${rc}" -eq 1 && "$(cat "${STARSHIP}")" == "MY STARSHIP" ]] \
    && ! grep -q 'starship' "${MODULES}/cli-mod/files.policy" 2>/dev/null \
    && ok "policy follow on non-TTY without --yes refuses; file and policy unchanged" || { fail "policy refusal (rc ${rc})"; cat "${OUT}"; }

# ── 3. policy follow --yes on an edited file replaces it; backup exists. ───
wb files policy cli-mod starship.toml follow --yes </dev/null
SBACK="$(find "${BACKUPS}" -name 'cli-mod-starship.toml.*' 2>/dev/null | head -1)"
[[ "${rc}" -eq 0 && "$(cat "${STARSHIP}")" == "WB STARSHIP" && -n "${SBACK}" && "$(cat "${SBACK}")" == "MY STARSHIP" ]] \
    && grep -qx '~/.config/starship.toml|follow' "${MODULES}/cli-mod/files.policy" \
    && ok "policy follow --yes: edited file backed up and replaced now, policy recorded" || { fail "policy follow --yes (rc ${rc})"; cat "${OUT}"; }
wb files status cli-mod
grep -E '~/\.config/starship\.toml +copy +follow\*' "${OUT}" >/dev/null \
    && ok "files status marks a per-file policy with '*'" || { fail "status per-file policy marker"; cat "${OUT}"; }

# ── 2b. restore reverses 'use': module file removed, ~/.tmux.conf back. ────
wb files restore cli-mod tmux.conf --yes </dev/null
[[ "${rc}" -eq 0 && ! -e "${TMUX_DEST}" && "$(cat "${HOME}/.tmux.conf" 2>/dev/null)" == "THEIR TMUX" ]] \
    && ok "files restore: module's tmux.conf removed, ~/.tmux.conf put back" || { fail "files restore (rc ${rc})"; cat "${OUT}"; }
wb files restore cli-mod tmux.conf --yes </dev/null
[[ "${rc}" -eq 0 ]] && grep -q "nothing of workbench's to restore" "${OUT}" \
    && ok "files restore twice: second run reports nothing to restore, exit 0" || { fail "second restore (rc ${rc})"; cat "${OUT}"; }

# ── 9. Basename collision: lists both dests; passing the dest resolves. ────
echo "MINE A" > "${HOME}/.config/cli/a/x.conf"
wb files use cli-mod x.conf --yes </dev/null
[[ "${rc}" -eq 1 ]] && grep -q "matches more than one" "${OUT}" \
    && grep -q "~/.config/cli/a/x.conf" "${OUT}" && grep -q "~/.config/cli/b/x.conf" "${OUT}" \
    && ok "basename collision: error lists both dests" || { fail "collision listing (rc ${rc})"; cat "${OUT}"; }
wb files use cli-mod "~/.config/cli/a/x.conf" --yes </dev/null
[[ "${rc}" -eq 0 && "$(cat "${HOME}/.config/cli/a/x.conf")" == "WB A" ]] \
    && ok "basename collision: the ~/-form dest resolves it" || { fail "collision by dest (rc ${rc})"; cat "${OUT}"; }
echo "MINE B" > "${HOME}/.config/cli/b/x.conf"
wb files use cli-mod "${HOME}/.config/cli/b/x.conf" --yes </dev/null
[[ "${rc}" -eq 0 && "$(cat "${HOME}/.config/cli/b/x.conf")" == "WB B" ]] \
    && ok "basename collision: the expanded dest (as the shell passes ~/x) resolves it" || { fail "collision by abs dest (rc ${rc})"; cat "${OUT}"; }
wb files use cli-mod nope.conf --yes </dev/null
[[ "${rc}" -eq 1 ]] && grep -q "doesn't match any" "${OUT}" && grep -q "vimrc" "${OUT}" \
    && ok "an unknown file name lists the available basenames" || { fail "unknown file (rc ${rc})"; cat "${OUT}"; }

# ── 10. 'wb module reset' still works — it delegates to 'wb files use'. ────
echo "MY VIMRC" > "${VIMRC}"
wb module reset cli-mod .vimrc --yes </dev/null
[[ "${rc}" -eq 0 && "$(cat "${VIMRC}")" == "WB VIMRC" ]] \
    && find "${BACKUPS}" -name 'cli-mod-.vimrc.*' -exec cat {} \; | grep -qx "MY VIMRC" \
    && ok "module reset delegates to files use: default back, yours backed up" || { fail "module reset (rc ${rc})"; cat "${OUT}"; }

# ── 7. 'wb remove --restore' answered 'n' leaves it registered and files
#    untouched (non-TTY: refused before anything changes). ────────────────
echo "n" | bash "${WB}" remove cli-mod --restore >"${OUT}" 2>&1; rc=$?
[[ "$(conf_of cli-mod REGISTERED)" == "true" && "$(cat "${VIMRC}")" == "WB VIMRC" && "$(cat "${STARSHIP}")" == "WB STARSHIP" ]] \
    && ok "remove --restore answered 'n': still registered, files untouched" || { fail "remove --restore 'n' (rc ${rc})"; cat "${OUT}"; }

# ── 7b. 'wb remove --restore --yes' puts files back, then deregisters. ─────
wb remove cli-mod --restore --yes </dev/null
[[ "${rc}" -eq 0 && "$(conf_of cli-mod REGISTERED)" == "false" && ! -e "${VIMRC}" && ! -e "${STARSHIP}" ]] \
    && ok "remove --restore --yes: workbench's files removed, module deregistered" || { fail "remove --restore --yes (rc ${rc})"; cat "${OUT}"; }
wb remove cli-mod </dev/null
grep -q "is not registered" "${OUT}" && ok "remove after remove --restore is a no-op" || fail "second remove"

# ── Fixture: a link_tree module (nvim-config's shape) ──────────────────────
NV="${WORK}/cli-nvim"
new_repo "${NV}"
printf 'version: 1\nbranch: main\ndeploy:\n  - src: .\n    dest: ~/.config/nvim\n    mode: link_tree\n' > "${NV}/src/.dotfiles-sync.yml"
echo "init1" > "${NV}/src/init.lua"
echo "lock1" > "${NV}/src/lazy-lock.json"
release "${NV}" v1.0.0
wb add cli-nvim "${NV}/m.git" --private </dev/null
NREAL="${HOME}/.config/nvim"
[[ -L "${NREAL}" && "$(readlink "${NREAL}")" == "${MODULES}/cli-nvim/current" ]] \
    && ok "link_tree: ~/.config/nvim is a symlink into the module's current" || { fail "link_tree add (rc ${rc})"; cat "${OUT}"; }
wb files status cli-nvim
grep -E '~/\.config/nvim +link_tree +managed +linked +follows' "${OUT}" >/dev/null \
    && ok "files status: a linked entry shows 'linked' / 'follows'" || { fail "status linked row"; cat "${OUT}"; }

# ── 5. A change through the link, then a new tag: 'wb update' on non-TTY
#    holds it; 'wb status' counts it. ──────────────────────────────────────
echo "lock-local" > "${NREAL}/lazy-lock.json"
echo "init2" > "${NV}/src/init.lua"
release "${NV}" v1.1.0
wb update cli-nvim </dev/null
[[ "$(awk -F'|' '$1 == "~/.config/nvim" { print $3 }' "${MODULES}/cli-nvim/files.list")" == "held" \
    && "$(cat "${NREAL}/lazy-lock.json")" == "lock-local" ]] \
    && ok "update on non-TTY: a change through link_tree is held, the change still live" || { fail "hold via wb update (rc ${rc})"; cat "${OUT}"; }
wb status
grep -q "Files waiting on you: 1 — run 'wb files status'" "${OUT}" \
    && ok "wb status shows the waiting count" || { fail "wb status waiting count"; cat "${OUT}"; }
wb files status
grep -q "^Waiting on you:" "${OUT}" && grep -E 'cli-nvim +~/\.config/nvim +changed locally; update held +wb files resolve cli-nvim nvim' "${OUT}" >/dev/null \
    && ok "files status: the held entry is listed under 'Waiting on you'" || { fail "files status waiting block"; cat "${OUT}"; }

# ── 8b. diff on a held link lists the local changes. ──────────────────────
wb files diff cli-nvim nvim
[[ "${rc}" -eq 0 ]] && grep -q "Changed locally" "${OUT}" && grep -q "M lazy-lock.json" "${OUT}" \
    && ok "files diff on a held link: exit 0, lists what changed locally" || { fail "held diff (rc ${rc})"; cat "${OUT}"; }

# ── 6. resolve with no choice on non-TTY is a usage error. ─────────────────
wb files resolve cli-nvim nvim </dev/null
[[ "${rc}" -eq 2 ]] && grep -q "keep|manage|use" "${OUT}" \
    && ok "resolve with no choice on non-TTY exits 2 and names the choices" || { fail "resolve no-choice (rc ${rc})"; cat "${OUT}"; }
wb files resolve cli-nvim nvim manage --follow --yes </dev/null
[[ "${rc}" -eq 2 ]] && ok "resolve: --follow is only valid with 'use'" || fail "resolve --follow without use (rc ${rc})"

# ── 5b. resolve manage --yes clears it: managed copies, your lock kept. ────
wb files resolve cli-nvim nvim manage --yes </dev/null
[[ "${rc}" -eq 0 && ! -e "${MODULES}/cli-nvim/files.pending" && -d "${NREAL}" && ! -L "${NREAL}" \
    && "$(cat "${NREAL}/lazy-lock.json")" == "lock-local" && "$(cat "${NREAL}/init.lua")" == "init2" ]] \
    && ok "resolve manage --yes: no longer pending; your lock kept, the rest current" || { fail "resolve manage (rc ${rc})"; cat "${OUT}"; }
wb status
grep -q "Files waiting on you" "${OUT}" \
    && { fail "wb status still reports waiting files"; cat "${OUT}"; } || ok "wb status: nothing waiting after resolve"
wb files resolve cli-nvim nvim keep --yes </dev/null
[[ "${rc}" -eq 0 ]] && grep -q "nothing to resolve" "${OUT}" \
    && ok "resolve on something not waiting: 'nothing to resolve', exit 0" || { fail "resolve nothing (rc ${rc})"; cat "${OUT}"; }

# ── policy: no args lists the default and per-file rows; --default ─────────
wb files policy
[[ "${rc}" -eq 0 ]] && grep -q "Host default: managed" "${OUT}" \
    && ok "policy with no args prints the host default" || { fail "policy list (rc ${rc})"; cat "${OUT}"; }
wb files policy --default sometimes </dev/null
[[ "${rc}" -eq 2 ]] && ok "policy --default rejects anything but managed|follow" || fail "bad --default accepted (rc ${rc})"
wb files policy --default follow --yes </dev/null
[[ "${rc}" -eq 0 ]] && grep -qx 'DEFAULT_POLICY=follow' "${XDG_DATA_HOME}/workbench/files.conf" \
    && ok "policy --default follow --yes writes files.conf" || { fail "policy --default (rc ${rc})"; cat "${OUT}"; }
wb files policy --default managed --yes </dev/null

# ── usage errors ────────────────────────────────────────────────────────────
wb files
[[ "${rc}" -eq 2 ]] && ok "'wb files' with no subcommand exits 2" || fail "'wb files' rc ${rc}"
wb files use cli-nvim
[[ "${rc}" -eq 2 ]] && ok "'wb files use <module>' with no file exits 2" || fail "'wb files use' rc ${rc}"
wb files status not-a-module
[[ "${rc}" -ne 0 ]] && grep -q "is not registered" "${OUT}" \
    && ok "files status on an unregistered module errors" || { fail "status unregistered (rc ${rc})"; cat "${OUT}"; }

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
