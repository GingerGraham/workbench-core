#!/usr/bin/env bash
# tests/check-layers.sh — D82: config layers.
#
# Drives lib/files/layers.sh (through the deploy loop and the D81 'wb files'
# library entry points) against a fake module state root and a scratch HOME.
# Uses the real git and ssh binaries where they're installed to prove
# precedence and validation; those checks skip cleanly when a tool is
# missing.
#
# SC2088: '~/...' is quoted on purpose — ledger keys are the literal ~/-form.
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# shellcheck disable=SC2088,SC2015
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }
skip() { echo "SKIP: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/home/.config"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "${HOME}"

# shellcheck source=bin/wb
source "${REPO_ROOT}/bin/wb" >/dev/null 2>&1
_wb_require core/installers-common.sh files/lifecycle.sh files/layers.sh distribution/snapshot.sh

M=demo
MDIR="$(workbench_module_dir "${M}")"
STAGE="${WORK}/stage"
LOG="${WORK}/run.log"
SNAPN=0

have_git=false; command -v git &>/dev/null && have_git=true
have_ssh=false; command -v ssh &>/dev/null && have_ssh=true

reset_case() {
    rm -rf "${MDIR}" "${HOME}" "${STAGE}" "${XDG_DATA_HOME}/workbench/backups"
    mkdir -p "${HOME}" "${STAGE}/files"
    : > "${LOG}"
}

# manifest — the layers: body on stdin
manifest() {
    { printf 'version: 2\ncore_api: ">=1.6 <2.0"\n'; cat; } > "${STAGE}/workbench.yml"
}

# deploy_snap: freeze the stage into a new snapshot, swap it in, deploy
deploy_snap() {
    SNAPN=$((SNAPN + 1))
    mkdir -p "${MDIR}/snapshots"
    cp -R "${STAGE}" "${MDIR}/snapshots/s${SNAPN}"
    workbench_snapshot_swap "${M}" "${MDIR}/snapshots/s${SNAPN}" >>"${LOG}" 2>&1
    workbench_deploy_module "${M}" >>"${LOG}" 2>&1
}
redeploy() { workbench_deploy_module "${M}" >>"${LOG}" 2>&1; }

line_of()  { workbench_files_targets "${M}" | awk -F'|' -v id="$1" '$7 == "layer" && $1 == id'; }
state_of() { workbench_files_ledger_field "${M}" "$1" 3; }
row_of()   { workbench_files_ledger_get "${M}" "$1"; }
stripped() { _wb_layers_strip_blocks "$1"; }
first_line() { head -n 1 "$1"; }
last_line()  { tail -n 1 "$1"; }

all_adapters() {
    printf 'set number\n' > "${STAGE}/files/vimrc"
    printf 'set -g mouse on\n' > "${STAGE}/files/tmux.conf"
    printf 'HashKnownHosts yes\nServerAliveInterval 60\n' > "${STAGE}/files/ssh"
    printf '[init]\n\tdefaultBranch = main\n[push]\n\tautoSetupRemote = true\n' > "${STAGE}/files/gitconfig"
    printf '[include]\n\tpath = ~/.config/git/project-includes\n' > "${STAGE}/files/contexts"
    printf 'Include ~/.ssh/config.d/*.conf\n' > "${STAGE}/files/confd"
    manifest <<'EOF'
layers:
  - tool: gitconfig
    src: files/gitconfig
  - tool: gitconfig
    src: files/contexts
    position: over
  - tool: ssh_config
    src: files/ssh
  - tool: ssh_config
    src: files/confd
    position: over
  - tool: tmux.conf
    src: files/tmux.conf
  - tool: vimrc
    src: files/vimrc
EOF
}

# ── 1. every adapter, target absent: created, block only ────────────────────
reset_case; all_adapters; deploy_snap
G="${HOME}/.gitconfig"; S="${HOME}/.ssh/config"; V="${HOME}/.vimrc"
for f in "${G}" "${S}" "${V}"; do
    if [[ -f "${f}" && -z "$(stripped "${f}" | tr -d '[:space:]')" ]]; then
        ok "absent target: $(basename "${f}") created holding only workbench blocks"
    else
        fail "absent target: $(basename "${f}") — $(cat "${f}" 2>/dev/null)"
    fi
done
TM="$(_wb_expand_dest "$(workbench_layers_target "${M}" tmux.conf under)")"
[[ -f "${TM}" && -z "$(stripped "${TM}" | tr -d '[:space:]')" ]] \
    && ok "absent target: tmux config created at $(_wb_layers_tilde "${TM}")" || fail "absent target: tmux config missing at ${TM}"
# shellcheck disable=SC2016  # vim's $VIMRUNTIME, literal
grep -qx 'unlet! skip_defaults_vim' "${V}" && grep -qx 'source $VIMRUNTIME/defaults.vim' "${V}" \
    && ok "created vimrc keeps vim's defaults.vim inside the block" || fail "created vimrc lacks the defaults.vim lines"
[[ "$(_wb_files_mode "${S}")" == "600" && "$(_wb_files_mode "${HOME}/.ssh")" == "700" ]] \
    && ok "created ssh config is 600 inside a 700 ~/.ssh" || fail "ssh modes: $(_wb_files_mode "${S}") / $(_wb_files_mode "${HOME}/.ssh")"
[[ "$(workbench_files_ledger_field "${M}" '~/.gitconfig#under' 5)" == "+created" && "$(state_of '~/.gitconfig#under')" == "active" ]] \
    && ok "ledger: created target recorded active, original +created" || fail "ledger row: $(row_of '~/.gitconfig#under')"

# ── 2. existing user files: bytes intact outside blocks, blocks in position ─
reset_case; all_adapters
printf '[user]\n\tname = Fixture\n\temail = fixture@example.invalid\n[init]\n\tdefaultBranch = trunk\n' > "${HOME}/.gitconfig"
mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
printf 'Host *\n  ServerAliveInterval 15\nHost example\n  User fixture\n' > "${HOME}/.ssh/config"; chmod 600 "${HOME}/.ssh/config"
printf 'set -g mouse off\n' > "${HOME}/.tmux.conf"
printf 'set nonumber\n' > "${HOME}/.vimrc"
for f in .gitconfig .ssh/config .tmux.conf .vimrc; do cp "${HOME}/${f}" "${WORK}/orig-$(basename "${f}")"; done
deploy_snap
for f in .gitconfig .ssh/config .tmux.conf .vimrc; do
    stripped "${HOME}/${f}" | cmp -s - "${WORK}/orig-$(basename "${f}")" \
        && ok "existing ${f}: your bytes unchanged outside workbench blocks" || fail "existing ${f}: user content changed"
done
[[ "$(first_line "${G}")" == "# >>> workbench demo/gitconfig under >>>" && "$(last_line "${G}")" == "# <<< workbench demo/gitconfig over <<<" ]] \
    && ok "gitconfig: under block at the top, over block at the bottom" || fail "gitconfig positions: $(first_line "${G}") / $(last_line "${G}")"
[[ "$(first_line "${S}")" == "# >>> workbench demo/ssh_config over >>>" && "$(last_line "${S}")" == "# <<< workbench demo/ssh_config under <<<" ]] \
    && ok "ssh_config: over block at the top, under block at the bottom" || fail "ssh positions: $(first_line "${S}") / $(last_line "${S}")"
[[ "$(first_line "${HOME}/.tmux.conf")" == "# >>> workbench demo/tmux.conf under >>>" && "$(first_line "${V}")" == '" >>> workbench demo/vimrc under >>>' ]] \
    && ok "tmux.conf and vimrc: under block at the top (vim markers use \")" || fail "tmux/vim positions"
[[ ! -e "${HOME}/.config/tmux/tmux.conf" ]] && ok "tmux: the existing ~/.tmux.conf is the target; no second config created" || fail "tmux: created a second config"
grep -q 'unlet! skip_defaults_vim' "${V}" && fail "existing vimrc got the defaults.vim lines" || ok "existing vimrc: no defaults.vim lines (only for a vimrc core creates)"
grep -qx 'Match all' "${S}" && ok "ssh under block re-scopes with 'Match all'" || fail "ssh under block lacks 'Match all'"

# ── 3. precedence, with the real tools ──────────────────────────────────────
if [[ "${have_git}" == "true" ]]; then
    [[ "$(git config --file "${G}" --includes --get init.defaultBranch)" == "trunk" ]] \
        && ok "git: your init.defaultBranch below the under block wins" || fail "git: got $(git config --file "${G}" --includes --get init.defaultBranch)"
    [[ "$(git config --file "${G}" --includes --get push.autoSetupRemote)" == "true" ]] \
        && ok "git: the module's value applies where you set none" || fail "git: module default not applied"
else
    skip "git not installed — precedence checks skipped"
fi
if [[ "${have_ssh}" == "true" ]]; then
    out="$(ssh -F "${S}" -G host.invalid </dev/null 2>/dev/null)"
    printf '%s\n' "${out}" | grep -qx 'serveraliveinterval 15' \
        && ok "ssh: your ServerAliveInterval above the bottom block wins" || fail "ssh: $(printf '%s\n' "${out}" | grep serveraliveinterval)"
    printf '%s\n' "${out}" | grep -qx 'hashknownhosts yes' \
        && ok "ssh: the module's value applies where you set none" || fail "ssh: module default not applied"
else
    skip "ssh not installed — precedence checks skipped"
fi

# ── 4. idempotency ──────────────────────────────────────────────────────────
cp "${G}" "${WORK}/g1"; cp "${S}" "${WORK}/s1"; cp "$(workbench_files_ledger_path "${M}")" "${WORK}/l1"
redeploy
cmp -s "${G}" "${WORK}/g1" && cmp -s "${S}" "${WORK}/s1" && cmp -s "$(workbench_files_ledger_path "${M}")" "${WORK}/l1" \
    && ok "a second apply changes nothing (files and ledger byte-identical)" || fail "second apply changed something"

# ── 5. git config --add include.path lands inside a block → relocated ───────
if [[ "${have_git}" == "true" ]]; then
    git config --global --add include.path /tmp/wb-relocate-me
    redeploy
    found_inside="$(awk '/>>> workbench demo\/gitconfig over >>>/{i=1} i&&/wb-relocate-me/{print "x"} /<<< workbench demo\/gitconfig over <<</{i=0}' "${G}")"
    [[ -z "${found_inside}" ]] && grep -q 'wb-relocate-me' "${G}" \
        && ok "a line git added inside workbench's block is moved out of it" || fail "relocation: $(cat "${G}")"
    git config --file "${G}" --get-all include.path | grep -qx /tmp/wb-relocate-me \
        && ok "the relocated line is still an include.path (its [include] header restated)" || fail "relocated include.path lost"
    [[ "$(last_line "${G}")" == "# <<< workbench demo/gitconfig over <<<" ]] \
        && ok "the over block is back at the end after relocation" || fail "over block not last"
    [[ "$(state_of '~/.gitconfig#over')" == "active" ]] && ok "relocation keeps the layer active" || fail "state after relocation: $(state_of '~/.gitconfig#over')"
fi

# ── 6. a new [user] section appended after the over block → settle ──────────
if [[ "${have_git}" == "true" ]]; then
    reset_case; all_adapters
    printf '[core]\n\teditor = vim\n' > "${HOME}/.gitconfig"
    deploy_snap
    git config --global user.email late@example.invalid
    [[ "$(last_line "${G}")" != "# <<< workbench demo/gitconfig over <<<" ]] \
        && ok "precondition: git appended [user] after the over block" || fail "precondition: git didn't append after the block"
    workbench_layers_settle "${M}" >>"${LOG}" 2>&1
    [[ "$(last_line "${G}")" == "# <<< workbench demo/gitconfig over <<<" ]] \
        && [[ "$(git config --file "${G}" --get user.email)" == "late@example.invalid" ]] \
        && ok "wb files settle moves the over block back to the end, your [user] kept" || fail "settle: $(cat "${G}")"
fi

# ── 7. markers deleted by the user → never re-added ─────────────────────────
reset_case; all_adapters
printf 'set -g mouse off\n' > "${HOME}/.tmux.conf"
deploy_snap
printf 'set -g mouse off\n' > "${HOME}/.tmux.conf"
redeploy; redeploy
[[ "$(cat "${HOME}/.tmux.conf")" == "set -g mouse off" && "$(state_of '~/.tmux.conf#under')" == "removed" ]] \
    && ok "block removed by you: state removed, never re-added" || fail "removed: $(state_of '~/.tmux.conf#under') / $(cat "${HOME}/.tmux.conf")"

# ── 8. include line deleted, markers kept → yours, frozen ───────────────────
reset_case; all_adapters; deploy_snap
grep -v 'source-file' "${TM}" > "${WORK}/t" && cat "${WORK}/t" > "${TM}"
cp "${TM}" "${WORK}/t-edited"
redeploy
[[ "$(state_of "$(workbench_layers_target "${M}" tmux.conf under)#under")" == "user" ]] && cmp -s "${TM}" "${WORK}/t-edited" \
    && ok "block edited by you: state user, not rewritten" || fail "edited block: $(state_of "$(workbench_layers_target "${M}" tmux.conf under)#under")"

# ── 9. symlinked target → linked pending; resolve use writes through it ─────
reset_case; all_adapters
mkdir -p "${HOME}/dotfiles"; printf 'set nonumber\n' > "${HOME}/dotfiles/vimrc"
ln -s dotfiles/vimrc "${HOME}/.vimrc"
deploy_snap
[[ "$(cat "${HOME}/dotfiles/vimrc")" == "set nonumber" ]] && grep -q '#under|linked' "$(workbench_files_pending_path "${M}")" \
    && ok "symlinked target: not written, listed as linked in files.pending" || fail "symlinked: $(cat "$(workbench_files_pending_path "${M}")" 2>/dev/null)"
workbench_files_resolve "${M}" "$(line_of vimrc)" use >>"${LOG}" 2>&1
[[ -L "${HOME}/.vimrc" ]] && grep -q '>>> workbench demo/vimrc under >>>' "${HOME}/dotfiles/vimrc" \
    && grep -qx 'set nonumber' "${HOME}/dotfiles/vimrc" \
    && ok "resolve use: block written through the link, the link still a link" || fail "resolve use: $(cat "${HOME}/dotfiles/vimrc")"
[[ "$(workbench_files_policy_get "${M}" vimrc)" == "managed" && ! -s "$(workbench_files_pending_path "${M}")" ]] \
    && ok "resolve use: policy managed, nothing pending" || fail "resolve use: policy '$(workbench_files_policy_get "${M}" vimrc)'"

# ── 10. skip removes an active block; managed puts it back ──────────────────
reset_case; all_adapters
printf 'set -g mouse off\n' > "${HOME}/.tmux.conf"
deploy_snap
_wb_files_policy_set_layer "${M}" "$(line_of tmux.conf)" skip >>"${LOG}" 2>&1
[[ "$(cat "${HOME}/.tmux.conf")" == "set -g mouse off" ]] && ok "policy skip: block removed now" || fail "skip: $(cat "${HOME}/.tmux.conf")"
redeploy
grep -q 'workbench demo/tmux.conf' "${HOME}/.tmux.conf" && fail "skip: block came back on the next sync" || ok "policy skip: not re-added on the next sync"
_wb_files_policy_set_layer "${M}" "$(line_of tmux.conf)" managed >>"${LOG}" 2>&1
[[ "$(first_line "${HOME}/.tmux.conf")" == "# >>> workbench demo/tmux.conf under >>>" && "$(state_of '~/.tmux.conf#under')" == "active" ]] \
    && ok "policy managed: block back, active" || fail "managed: $(state_of '~/.tmux.conf#under')"
_wb_files_policy_set_layer "${M}" "$(line_of tmux.conf)" follow >>"${LOG}" 2>&1 \
    && fail "policy follow accepted for a layer" || ok "policy seed/follow rejected for a layer"

# ── 11. validator: roll back what broke a valid file; warn on a broken one ──
if [[ "${have_ssh}" == "true" ]]; then
    reset_case
    printf 'BogusDirective yes\n' > "${STAGE}/files/ssh"
    manifest <<'EOF'
layers:
  - tool: ssh_config
    src: files/ssh
EOF
    mkdir -p "${HOME}/.ssh"; printf 'Host *\n  ServerAliveInterval 15\n' > "${HOME}/.ssh/config"
    cp "${HOME}/.ssh/config" "${WORK}/ssh-orig"
    deploy_snap
    cmp -s "${HOME}/.ssh/config" "${WORK}/ssh-orig" && grep -q 'rejects the file' "${LOG}" \
        && ok "ssh validator: a module file ssh rejects → your config put back, error logged" || fail "ssh rollback: $(cat "${HOME}/.ssh/config")"
    [[ -z "$(row_of '~/.ssh/config#under')" ]] && ok "ssh validator: ledger unchanged after a rollback" || fail "ledger written after rollback"

    reset_case
    printf 'HashKnownHosts yes\n' > "${STAGE}/files/ssh"
    manifest <<'EOF'
layers:
  - tool: ssh_config
    src: files/ssh
EOF
    mkdir -p "${HOME}/.ssh"; printf 'AlreadyBroken yes\n' > "${HOME}/.ssh/config"
    deploy_snap
    grep -q 'workbench demo/ssh_config' "${HOME}/.ssh/config" && grep -q 'already reported errors' "${LOG}" \
        && ok "ssh validator: a config already broken before → written, with a warning" || fail "pre-broken: $(cat "${LOG}")"
else
    skip "ssh not installed — validator checks skipped"
fi

# ── 12. restore ─────────────────────────────────────────────────────────────
reset_case; all_adapters; deploy_snap
workbench_files_restore "${M}" '~/.vimrc#under' >>"${LOG}" 2>&1
[[ ! -e "${HOME}/.vimrc" && "$(state_of '~/.vimrc#under')" == "restored" && "$(workbench_files_policy_get "${M}" vimrc)" == "skip" ]] \
    && ok "restore: a file workbench created is deleted once only its block was in it" || fail "restore created: $(state_of '~/.vimrc#under')"
redeploy
[[ ! -e "${HOME}/.vimrc" ]] && ok "restore: not re-created on the next sync" || fail "restore: vimrc came back"

reset_case; all_adapters
printf 'set -g mouse off\n# mine\n' > "${HOME}/.tmux.conf"; cp "${HOME}/.tmux.conf" "${WORK}/tmux-orig"
deploy_snap
workbench_files_use "${M}" "$(line_of tmux.conf)" >>"${LOG}" 2>&1
[[ -z "$(stripped "${HOME}/.tmux.conf" | tr -d '[:space:]')" ]] && grep -q 'workbench demo/tmux.conf under' "${HOME}/.tmux.conf" \
    && ok "use: the file holds only workbench's block" || fail "use: $(cat "${HOME}/.tmux.conf")"
workbench_files_restore "${M}" '~/.tmux.conf#under' >>"${LOG}" 2>&1
cmp -s "${HOME}/.tmux.conf" "${WORK}/tmux-orig" && ok "restore after use: your original back, byte-identical" || fail "restore after use: $(cat "${HOME}/.tmux.conf")"

reset_case; all_adapters
printf 'set -g mouse off\n' > "${HOME}/.tmux.conf"; cp "${HOME}/.tmux.conf" "${WORK}/tmux-orig"
deploy_snap
workbench_files_restore "${M}" '~/.tmux.conf#under' >>"${LOG}" 2>&1
cmp -s "${HOME}/.tmux.conf" "${WORK}/tmux-orig" && ok "restore: block removed from your file, your lines untouched" || fail "restore existing: $(cat "${HOME}/.tmux.conf")"

# ── 13. adopt ───────────────────────────────────────────────────────────────
if [[ "${have_git}" == "true" ]]; then
    reset_case
    printf '[init]\n\tdefaultBranch = main\n' > "${STAGE}/files/gitconfig"
    mkdir -p "${STAGE}/files/legacy"
    printf 'core.excludesfile ~/.local/share/x/ignore\ninclude.path ~/.config/git/project-includes\n' > "${STAGE}/files/legacy/git"
    manifest <<'EOF'
layers:
  - tool: gitconfig
    src: files/gitconfig
    adopt: [files/legacy/git]
EOF
    printf '[user]\n\tname = Fixture\n[core]\n\texcludesfile = %s/.local/share/x/ignore\n\teditor = vim\n[include]\n\tpath = ~/.config/git/project-includes\n' "${HOME}" > "${HOME}/.gitconfig"
    deploy_snap
    ! git config --file "${G}" --get core.excludesfile >/dev/null && ! git config --file "${G}" --get-all include.path | grep -q project-includes \
        && [[ "$(git config --file "${G}" --get core.editor)" == "vim" && "$(git config --file "${G}" --get user.name)" == "Fixture" ]] \
        && ok "adopt gitconfig: old hook lines removed in \$HOME/ and ~/ form; your other settings kept" || fail "adopt git: $(cat "${G}")"
    ls "${XDG_DATA_HOME}/workbench/backups"/*/*/demo-.gitconfig.* >/dev/null 2>&1 \
        && ok "adopt: the whole target backed up first" || fail "adopt: no backup"
fi

reset_case
printf 'HashKnownHosts yes\n' > "${STAGE}/files/ssh"
mkdir -p "${STAGE}/files/legacy"
printf '# workbench-ssh defaults: keep last so your own settings above win.\nMatch all\nInclude ~/.ssh/workbench-defaults.conf\n' > "${STAGE}/files/legacy/ssh"
manifest <<'EOF'
layers:
  - tool: ssh_config
    src: files/ssh
    adopt: [files/legacy/ssh]
EOF
mkdir -p "${HOME}/.ssh"
printf 'Host *\n  ServerAliveInterval 15\n\n# workbench-ssh defaults: keep last so your own settings above win.\nMatch all\nInclude %s/.ssh/workbench-defaults.conf\n' "${HOME}" > "${HOME}/.ssh/config"
deploy_snap
[[ "$(stripped "${S}")" == "$(printf 'Host *\n  ServerAliveInterval 15')" ]] \
    && ok "adopt ssh: old block and the blank line above it removed (\$HOME/ matched as ~/)" || fail "adopt ssh: $(cat "${S}")"

reset_case
printf 'HashKnownHosts yes\n' > "${STAGE}/files/ssh"
mkdir -p "${STAGE}/files/legacy"
printf 'Match all\nInclude ~/.ssh/workbench-defaults.conf\n' > "${STAGE}/files/legacy/ssh"
manifest <<'EOF'
layers:
  - tool: ssh_config
    src: files/ssh
    adopt: [files/legacy/ssh]
EOF
mkdir -p "${HOME}/.ssh"; printf 'Match all\n  User x\nInclude ~/.ssh/workbench-defaults.conf\n' > "${HOME}/.ssh/config"
deploy_snap
grep -q "still has 'Include ~/.ssh/workbench-defaults.conf'" "${LOG}" && grep -qx 'Include ~/.ssh/workbench-defaults.conf' "${S}" \
    && ok "adopt: a block that doesn't match exactly is left, with a warning naming the line" || fail "adopt leftover: $(cat "${LOG}")"

# ── 14. A.5: a D81 copy at a layer's target becomes a layer ─────────────────
reset_case; all_adapters
mkdir -p "${HOME}/.config/tmux"
printf 'set -g mouse on\n' > "${HOME}/.config/tmux/tmux.conf"
workbench_files_ledger_set "${M}" '~/.config/tmux/tmux.conf' deploy active "$(_wb_sha256 "${HOME}/.config/tmux/tmux.conf")" -
printf 'set number\n" mine\n' > "${HOME}/.vimrc"
workbench_files_ledger_set "${M}" '~/.vimrc' deploy active "$(_wb_sha256 "${STAGE}/files/vimrc")" -
deploy_snap
T2="${HOME}/.config/tmux/tmux.conf"
[[ -z "$(stripped "${T2}" | tr -d '[:space:]')" && -z "$(row_of '~/.config/tmux/tmux.conf')" \
    && "$(workbench_files_ledger_field "${M}" '~/.config/tmux/tmux.conf#under' 5)" == "+created" ]] \
    && ok "A.5: core's unedited copy → a block-only file, deploy row gone" || fail "A.5 active: $(cat "${T2}")"
[[ "$(first_line "${V}")" == '" >>> workbench demo/vimrc under >>>' ]] && grep -qx '" mine' "${V}" && [[ -z "$(row_of '~/.vimrc')" ]] \
    && grep -q 'still contains an older copy' "${LOG}" \
    && ok "A.5: an edited copy keeps your content, block added on top, logged once" || fail "A.5 edited: $(cat "${V}")"

# ── 15. an adapter this core doesn't know → warned, skipped, rest syncs ─────
reset_case
printf 'set -g mouse on\n' > "${STAGE}/files/tmux.conf"
manifest <<'EOF'
layers:
  - tool: fishconfig
    src: files/tmux.conf
  - tool: tmux.conf
    src: files/tmux.conf
EOF
deploy_snap
grep -q "unknown adapter 'fishconfig'" "${LOG}" && [[ -n "$(line_of tmux.conf)" ]] && grep -q 'workbench demo/tmux.conf' "${TM}" \
    && ok "unknown adapter: warned and skipped; the module's other layers still apply" || fail "unknown adapter: $(cat "${LOG}")"

# ── 16. a path a block can't quote safely → refused ─────────────────────────
reset_case
mkdir -p "${STAGE}/files/it's"
printf 'set -g mouse on\n' > "${STAGE}/files/it's/tmux.conf"
manifest <<'EOF'
layers:
  - tool: tmux.conf
    src: "files/it's/tmux.conf"
EOF
deploy_snap
[[ ! -e "${TM}" ]] && grep -q 'contains a quote' "${LOG}" \
    && ok "a layer path containing a quote is refused" || fail "quote path: $(cat "${LOG}")"

# ── extra: physical check — a target symlinked into workbench's state ───────
reset_case; all_adapters
mkdir -p "${XDG_DATA_HOME}/workbench"
ln -s "${XDG_DATA_HOME}/workbench/evil" "${HOME}/.tmux.conf"
workbench_files_policy_set "${M}" tmux.conf managed
deploy_snap
[[ ! -e "${XDG_DATA_HOME}/workbench/evil" ]] \
    && ok "a target resolving into workbench's own state is never written, even with consent" || fail "wrote through into workbench state"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
