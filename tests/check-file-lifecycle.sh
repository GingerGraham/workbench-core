#!/usr/bin/env bash
# tests/check-file-lifecycle.sh — D81: core-owned file lifecycle.
#
# Drives lib/files/lifecycle.sh against a fake module state root. Updates
# are simulated in the same order the sync engine runs them (record sums →
# before_swap → swap → prune → deploy), with no network.
#
# SC2088: '~/...' is quoted on purpose — ledger, policy and target keys are
#         the literal ~/-form path, expanded only by _wb_expand_dest.
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom; ok()
#         only echoes and cannot fail.
# shellcheck disable=SC2088,SC2015
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

# shellcheck source=bin/wb
source "${REPO_ROOT}/bin/wb" >/dev/null 2>&1
_wb_require core/installers-common.sh files/lifecycle.sh distribution/snapshot.sh

M=demo
MDIR="$(workbench_module_dir "${M}")"
STAGE="${WORK}/stage"
LOG="${WORK}/run.log"
BACKUPS="${XDG_DATA_HOME}/workbench/backups"

reset_case() {
    rm -rf "${MDIR}" "${HOME}" "${STAGE}" "${BACKUPS}" "$(workbench_files_conf_path)"
    SNAPN=0
    mkdir -p "${HOME}" "${STAGE}/files"
    : > "${LOG}"
}

# manifest <yaml body for deploy:> — written into the stage
manifest() {
    { printf 'version: 2\n'; cat; } > "${STAGE}/workbench.yml"
}

# snap <name>: freeze the stage into snapshots/<name>
snap() {
    mkdir -p "${MDIR}/snapshots"
    rm -rf "${MDIR}/snapshots/$1"
    cp -R "${STAGE}" "${MDIR}/snapshots/$1"
    # prune orders snapshots by mtime: give each a distinct, increasing one
    # (touch -t works on GNU and BSD alike; no sleeping)
    SNAPN=$((SNAPN + 1))
    touch -t "202601010000.$(printf '%02d' "${SNAPN}")" "${MDIR}/snapshots/$1"
}

# update_to <name>: the engine's order, for a snapshot already on disk
update_to() {
    local new="${MDIR}/snapshots/$1"
    workbench_files_record_sums "${M}" "${new}"
    workbench_files_before_swap "${M}" >>"${LOG}" 2>&1
    workbench_snapshot_swap "${M}" "${new}"
    workbench_snapshot_prune "${M}" "${KEEP:-3}" >>"${LOG}" 2>&1
    workbench_deploy_module "${M}" >>"${LOG}" 2>&1
}

target_line() { workbench_files_targets "${M}" | awk -F'|' -v d="$1" '$3 == d'; }
state_of()    { workbench_files_ledger_field "${M}" "$1" 3; }
content()     { cat "$(_wb_expand_dest "$1")" 2>/dev/null; }
pending()     { cat "$(workbench_files_pending_path "${M}")" 2>/dev/null; }
backed_up()   { grep -rqx -- "$1" "${BACKUPS}" 2>/dev/null; }

T='~/.config/tmux/tmux.conf'
TREAL="${HOME}/.config/tmux/tmux.conf"

tmux_manifest() {
    manifest <<'EOF'
deploy:
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    yield_to: [~/.tmux.conf]
EOF
}

# ═════════════════════════════ copy mode ════════════════════════════════════

# ── new / clean+moved / seed ────────────────────────────────────────────────
reset_case; tmux_manifest
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
[[ "$(content "${T}")" == "v1" && "$(state_of "${T}")" == "active" ]] \
    && ok "copy new: written and recorded active" || fail "copy new: '$(content "${T}")'/'$(state_of "${T}")'"

echo v2 > "${STAGE}/files/tmux.conf"; snap s2; update_to s2
[[ "$(content "${T}")" == "v2" ]] && ok "copy clean+moved (managed): refreshed" || fail "copy clean+moved: '$(content "${T}")'"

workbench_files_policy_set "${M}" "${T}" seed
echo v3 > "${STAGE}/files/tmux.conf"; snap s3; update_to s3
[[ "$(content "${T}")" == "v2" ]] && ok "copy clean+moved (seed): untouched" || fail "copy seed: '$(content "${T}")'"
workbench_files_policy_set "${M}" "${T}" default

# ── edited + moved: untouched, pending; resolve manage / keep ───────────────
echo mine > "${TREAL}"
echo v4 > "${STAGE}/files/tmux.conf"; snap s4; update_to s4
[[ "$(content "${T}")" == "mine" && "$(pending)" == "${T}|moved" ]] \
    && ok "copy edited+moved (managed): untouched, listed as pending" || fail "copy edited+moved: '$(content "${T}")', pending '$(pending)'"

workbench_files_resolve "${M}" "$(target_line "${T}")" manage >>"${LOG}" 2>&1
[[ "$(content "${T}")" == "mine" && -z "$(pending)" ]] \
    && ok "resolve manage (copy): keeps yours, clears the notice" || fail "resolve manage: pending '$(pending)'"

echo v5 > "${STAGE}/files/tmux.conf"; snap s5; update_to s5
[[ "$(pending)" == "${T}|moved" ]] \
    && ok "resolve manage (copy): a further upstream change raises it again" || fail "manage re-notify: '$(pending)'"

workbench_files_resolve "${M}" "$(target_line "${T}")" keep >>"${LOG}" 2>&1
echo v6 > "${STAGE}/files/tmux.conf"; snap s6; update_to s6
[[ "$(content "${T}")" == "mine" && -z "$(pending)" && "$(workbench_files_policy_get "${M}" "${T}")" == "seed" ]] \
    && ok "resolve keep (copy): yours, policy seed, no further notices" || fail "resolve keep: pending '$(pending)'"

# ── edited, follow → backed up, refreshed; not recorded as original ─────────
workbench_files_policy_set "${M}" "${T}" follow
echo v7 > "${STAGE}/files/tmux.conf"; snap s7; update_to s7
[[ "$(content "${T}")" == "v7" ]] && backed_up mine \
    && ok "copy edited (follow): backed up, then refreshed" || fail "copy follow: '$(content "${T}")'"
[[ "$(workbench_files_ledger_field "${M}" "${T}" 5)" == "-" ]] \
    && ok "copy edited (follow): a routine backup is not the original" || fail "copy follow: original was set"

# ── gone → removed, not recreated; use brings it back ───────────────────────
workbench_files_policy_set "${M}" "${T}" default
rm -f "${TREAL}"
echo v8 > "${STAGE}/files/tmux.conf"; snap s8; update_to s8
[[ ! -e "${TREAL}" && "$(state_of "${T}")" == "removed" ]] \
    && ok "copy gone: marked removed, not recreated" || fail "copy gone: '$(state_of "${T}")'"
workbench_files_use "${M}" "$(target_line "${T}")" >>"${LOG}" 2>&1
[[ "$(content "${T}")" == "v8" && "$(state_of "${T}")" == "active" ]] \
    && ok "use: default back, entry active" || fail "use after removed: '$(content "${T}")'"

# ── foreign: managed leaves it; follow records the original; restore ────────
reset_case; tmux_manifest
mkdir -p "$(dirname "${TREAL}")"; echo theirs > "${TREAL}"
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
echo v2 > "${STAGE}/files/tmux.conf"; snap s2; update_to s2
[[ "$(content "${T}")" == "theirs" && -z "$(state_of "${T}")" ]] \
    && ok "copy foreign (managed): left alone across updates, no record (re-evaluated each time)" || fail "copy foreign: '$(content "${T}")'/'$(state_of "${T}")'"

reset_case; tmux_manifest
mkdir -p "$(dirname "${TREAL}")"; echo theirs > "${TREAL}"
workbench_files_default_policy_set follow
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
orig="$(workbench_files_ledger_field "${M}" "${T}" 5)"
[[ "$(content "${T}")" == "v1" && "$(cat "${orig}" 2>/dev/null)" == "theirs" ]] \
    && ok "copy foreign (host follow): written, pre-workbench file kept as original" || fail "copy foreign follow: original '${orig}'"
workbench_files_restore "${M}" "${T}" >>"${LOG}" 2>&1
echo v2 > "${STAGE}/files/tmux.conf"; snap s2; update_to s2
[[ "$(content "${T}")" == "theirs" && "$(workbench_files_policy_get "${M}" "${T}")" == "skip" ]] \
    && ok "restore: original back, policy skip, not rewritten" || fail "restore: '$(content "${T}")'"

# ── restore of a file workbench created; restore never removes a user link ──
reset_case; tmux_manifest
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
workbench_files_restore "${M}" "${T}" >>"${LOG}" 2>&1
[[ ! -e "${TREAL}" && "$(state_of "${T}")" == "restored" ]] \
    && ok "restore (no original): removed, entry restored" || fail "restore no original"

reset_case; tmux_manifest
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
echo stowed > "${WORK}/stow-tmux.conf"; rm -f "${TREAL}"; ln -s "${WORK}/stow-tmux.conf" "${TREAL}"
rc=0; workbench_files_restore "${M}" "${T}" >>"${LOG}" 2>&1 || rc=$?
[[ "${rc}" -eq 4 && -L "${TREAL}" ]] && ok "restore: a user's symlink is left in place (rc 4)" || fail "restore symlink rc=${rc}"

# ── adoptable ───────────────────────────────────────────────────────────────
reset_case; tmux_manifest
echo v1 > "${STAGE}/files/tmux.conf"; snap s1
echo v2 > "${STAGE}/files/tmux.conf"; snap s2
mkdir -p "$(dirname "${TREAL}")"; echo v1 > "${TREAL}"
update_to s2
[[ "$(content "${T}")" == "v2" && "$(state_of "${T}")" == "active" ]] \
    && ok "copy adoptable (managed): unedited old default refreshed" || fail "adoptable managed: '$(content "${T}")'"

reset_case; tmux_manifest
echo v1 > "${STAGE}/files/tmux.conf"; snap s1
mkdir -p "$(dirname "${TREAL}")"; ln -s "${MDIR}/current/files/tmux.conf" "${TREAL}"
workbench_files_policy_set "${M}" "${T}" seed
update_to s1
[[ ! -L "${TREAL}" && "$(content "${T}")" == "v1" && "$(cat "${MDIR}/snapshots/s1/files/tmux.conf")" == "v1" ]] \
    && ok "copy legacy symlink: replaced by a real file, snapshot untouched" || fail "legacy symlink"

# ── yielded; use moves the competitor aside; restore puts it back ───────────
reset_case; tmux_manifest
echo theirs > "${HOME}/.tmux.conf"
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
[[ ! -e "${TREAL}" && -z "$(state_of "${T}")" ]] && grep -q "found your own config at ~/.tmux.conf" "${LOG}" \
    && ok "copy yielded (managed): not created, the user's ~/.tmux.conf named" || fail "yielded managed"

workbench_files_use "${M}" "$(target_line "${T}")" >>"${LOG}" 2>&1
[[ "$(content "${T}")" == "v1" && ! -e "${HOME}/.tmux.conf" ]] && backed_up theirs \
    && ok "use: writes the module's version and moves ~/.tmux.conf aside" || fail "use yielded: ~/.tmux.conf exists=$([[ -e "${HOME}/.tmux.conf" ]] && echo y)"
workbench_files_restore "${M}" "${T}" >>"${LOG}" 2>&1
[[ ! -e "${TREAL}" && "$(cat "${HOME}/.tmux.conf" 2>/dev/null)" == "theirs" ]] \
    && ok "restore: removes the module's file and puts ~/.tmux.conf back" || fail "restore after use"

reset_case; tmux_manifest
echo theirs > "${HOME}/.tmux.conf"
workbench_files_default_policy_set follow
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
[[ ! -e "${TREAL}" && -e "${HOME}/.tmux.conf" ]] \
    && ok "copy yielded (host follow): no second config created beside yours" || fail "yielded host follow created a second config"
workbench_files_policy_set "${M}" "${T}" follow
echo v2 > "${STAGE}/files/tmux.conf"; snap s2; update_to s2
[[ "$(content "${T}")" == "v2" && -e "${HOME}/.tmux.conf" ]] \
    && ok "copy yielded (per-file follow): written with a warning, competitor untouched by sync" || fail "yielded per-file follow"

reset_case; tmux_manifest
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
workbench_files_use "${M}" "$(target_line "${T}")" follow >>"${LOG}" 2>&1
[[ "$(workbench_files_policy_get "${M}" "${T}")" == "follow" ]] \
    && ok "use follow: sets per-entry follow" || fail "use follow"

# ── skip; policy resolution ─────────────────────────────────────────────────
reset_case; tmux_manifest
workbench_files_policy_set "${M}" "${T}" skip
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
[[ ! -e "${TREAL}" && -z "$(state_of "${T}")" ]] && ok "skip: nothing written, nothing recorded" || fail "skip"

workbench_files_default_policy_set follow
[[ "$(workbench_files_effective_policy "${M}" '~/x' seed)" == "seed" ]] \
    && ok "host default follow does not apply to lifecycle seed" || fail "seed widened"
workbench_files_default_policy_set managed
[[ "$(workbench_files_effective_policy "${M}" '~/x' generated)" == "follow" ]] \
    && ok "lifecycle generated resolves to follow" || fail "generated"

# ── a directory where a copy-mode file belongs is never written into ────────
reset_case; tmux_manifest
mkdir -p "${TREAL}/inner"
workbench_files_default_policy_set follow
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
[[ -d "${TREAL}/inner" && -z "$(find "${TREAL}" -type f)" ]] \
    && ok "copy: a directory at dest is never written into, even under follow" || fail "dir at dest written into"

# ── atomic writes; '|' refused ──────────────────────────────────────────────
reset_case; tmux_manifest
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
[[ -z "$(find "$(dirname "${TREAL}")" -name '*.wb.*')" ]] && ok "write: no temp files left" || fail "temp files left"
rc=0; workbench_files_apply "${M}" '~/bad|name' "${STAGE}/files/tmux.conf" files/tmux.conf deploy managed >>"${LOG}" 2>&1 || rc=$?
[[ "${rc}" -ne 0 && -z "$(workbench_files_ledger_get "${M}" '~/bad|name')" ]] && ok "apply: dest containing '|' refused" || fail "'|' accepted"

# ── _wb_files_decide: every documented cell ─────────────────────────────────
decide_failed=0
while read -r p c mv sl ex want; do
    [[ -z "${p}" ]] && continue
    got="$(_wb_files_decide "${p}" "${c}" "${mv}" "${sl}" "${ex}")"
    [[ "${got}" == "${want}" ]] || { fail "decide ${p}/${c}/moved=${mv}/symlink=${sl}/explicit=${ex}: want ${want}, got ${got}"; decide_failed=1; }
done <<'EOF'
skip    new       false false true  none
seed    new       false false false write
seed    yielded   false false false leave
seed    adoptable false false false adopt
seed    adoptable false true  false write
seed    foreign   false false false leave
seed    clean     true  false false none
seed    edited    true  false false none
seed    gone      false false false mark-removed
managed new       false false false write
managed yielded   false false false leave
managed adoptable false false false write
managed foreign   false false false leave
managed clean     false false false none
managed clean     true  false false write
managed edited    false false false none
managed edited    true  false false notify
managed gone      false false false mark-removed
follow  yielded   false false false leave
follow  yielded   false false true  write-warn
follow  foreign   false false false write-original
follow  clean     true  false false write
follow  edited    false false false write-backup
follow  user      false false true  none
follow  held      true  false true  none
managed removed   true  false false none
managed restored  true  false false none
EOF
[[ "${decide_failed}" -eq 0 ]] && ok "decide: every matrix cell resolves as documented"

# ═════════════════════════════ linked entries ═══════════════════════════════

N='~/.config/nvim'
NREAL="${HOME}/.config/nvim"

nvim_manifest() {
    manifest <<'EOF'
deploy:
  - src: .
    dest: ~/.config/nvim
    mode: link_tree
EOF
}

nvim_stage() {   # <init content> <lock content>
    rm -rf "${STAGE}"; mkdir -p "${STAGE}/lua"
    nvim_manifest
    echo "$1" > "${STAGE}/init.lua"
    echo "$2" > "${STAGE}/lazy-lock.json"
    echo "opts" > "${STAGE}/lua/options.lua"
}

# ── link_tree: one symlink to current, follows updates ──────────────────────
reset_case; nvim_stage init1 lock1; snap s1; update_to s1
[[ -L "${NREAL}" && "$(readlink "${NREAL}")" == "${MDIR}/current" && "$(cat "${NREAL}/init.lua")" == "init1" ]] \
    && ok "link_tree: dest is one symlink to <module>/current" || fail "link_tree new: $(readlink "${NREAL}")"
nvim_stage init2 lock1; snap s2; update_to s2
[[ "$(cat "${NREAL}/init.lua")" == "init2" && -z "$(pending)" ]] \
    && ok "link_tree: follows an update when nothing was changed through it" || fail "link_tree follow"

# ── a change through the link: held, pinned, survives prune ─────────────────
echo lock-local > "${NREAL}/lazy-lock.json"
nvim_stage init3 lock3; snap s3
KEEP=1 update_to s3
[[ "$(state_of "${N}")" == "held" && "$(readlink "${NREAL}")" == "${MDIR}/snapshots/s2" \
    && "$(cat "${NREAL}/lazy-lock.json")" == "lock-local" && "$(pending)" == "${N}|held" ]] \
    && ok "link_tree drift: held at its snapshot, your change still live, pending" || fail "drift hold: state '$(state_of "${N}")', link '$(readlink "${NREAL}")'"
[[ -d "${MDIR}/snapshots/s2" && "$(readlink "${MDIR}/current")" == "${MDIR}/snapshots/s3" ]] \
    && ok "link_tree drift: the rest of the module updated; the pinned snapshot survived prune" || fail "pinned snapshot pruned"

# ── resolve manage: managed copies — your lock kept, the rest tracked ───────
workbench_files_resolve "${M}" "$(target_line "${N}")" manage >>"${LOG}" 2>&1
[[ -d "${NREAL}" && ! -L "${NREAL}" && "$(cat "${NREAL}/lazy-lock.json")" == "lock-local" \
    && "$(cat "${NREAL}/init.lua")" == "init3" && "$(pending)" == "${N}/lazy-lock.json|moved" ]] \
    && ok "resolve manage (link_tree): real dir, your lock kept (its newer default pending), everything else current" || fail "resolve manage: pending '$(pending)'"
[[ ! -d "${MDIR}/snapshots/s2" ]] || KEEP=1 workbench_snapshot_prune "${M}" 1 >>"${LOG}" 2>&1
[[ ! -d "${MDIR}/snapshots/s2" ]] && ok "resolve manage: snapshot unpinned and prunable" || fail "s2 still pinned"
nvim_stage init4 lock4; snap s4; update_to s4
[[ "$(cat "${NREAL}/init.lua")" == "init4" && "$(cat "${NREAL}/lazy-lock.json")" == "lock-local" \
    && "$(pending)" == "${N}/lazy-lock.json|moved" ]] \
    && ok "managed copies: unchanged files follow, your lock stays, its upstream change is pending" || fail "after manage: pending '$(pending)'"

# ── resolve keep: your own copy, never updated ──────────────────────────────
reset_case; nvim_stage init1 lock1; snap s1; update_to s1
echo lock-local > "${NREAL}/lazy-lock.json"
nvim_stage init2 lock2; snap s2; update_to s2
workbench_files_resolve "${M}" "$(target_line "${N}")" keep >>"${LOG}" 2>&1
nvim_stage init3 lock3; snap s3; update_to s3
[[ ! -L "${NREAL}" && "$(cat "${NREAL}/init.lua")" == "init1" && "$(cat "${NREAL}/lazy-lock.json")" == "lock-local" \
    && "$(state_of "${N}")" == "user" && -z "$(pending)" ]] \
    && ok "resolve keep (link_tree): your copy, never updated" || fail "resolve keep: state '$(state_of "${N}")'"

# ── resolve use: your change backed up, link follows again ──────────────────
reset_case; nvim_stage init1 lock1; snap s1; update_to s1
echo lock-local > "${NREAL}/lazy-lock.json"
nvim_stage init2 lock2; snap s2; update_to s2
workbench_files_resolve "${M}" "$(target_line "${N}")" use >>"${LOG}" 2>&1
[[ "$(readlink "${NREAL}")" == "${MDIR}/current" && "$(cat "${NREAL}/lazy-lock.json")" == "lock2" ]] && backed_up lock-local \
    && ok "resolve use (link_tree): your change backed up, link follows the module" || fail "resolve use"

# ── explicit follow: drift backed up, update taken, no hold ─────────────────
reset_case; nvim_stage init1 lock1; snap s1; update_to s1
workbench_files_policy_set "${M}" "${N}" follow
echo lock-local > "${NREAL}/lazy-lock.json"
nvim_stage init2 lock2; snap s2; update_to s2
[[ "$(readlink "${NREAL}")" == "${MDIR}/current" && "$(cat "${NREAL}/lazy-lock.json")" == "lock2" && -z "$(pending)" ]] && backed_up lock-local \
    && ok "link_tree (entry follow): your change backed up, update taken, no hold" || fail "link follow"

# ── a real directory at a link_tree dest ────────────────────────────────────
reset_case; nvim_stage init1 lock1; snap s1
mkdir -p "${NREAL}"; echo mine > "${NREAL}/init.lua"
workbench_files_default_policy_set follow
update_to s1
[[ -d "${NREAL}" && ! -L "${NREAL}" && "$(cat "${NREAL}/init.lua")" == "mine" && -z "$(state_of "${N}")" ]] \
    && ok "link_tree: host default follow never moves your directory" || fail "host follow moved a dir"
workbench_files_use "${M}" "$(target_line "${N}")" >>"${LOG}" 2>&1
[[ "$(readlink "${NREAL}")" == "${MDIR}/current" ]] && backed_up mine \
    && ok "use (link_tree): your directory moved aside, link created" || fail "use link_tree"
workbench_files_restore "${M}" "${N}" >>"${LOG}" 2>&1
[[ -d "${NREAL}" && ! -L "${NREAL}" && "$(cat "${NREAL}/init.lua")" == "mine" ]] \
    && ok "restore (link_tree): your directory is back" || fail "restore link_tree"

# ── resolve on an unchanged linked entry: choose ahead of any change ───────
reset_case; nvim_stage init1 lock1; snap s1; update_to s1
workbench_files_resolve "${M}" "$(target_line "${N}")" manage >>"${LOG}" 2>&1
nvim_stage init2 lock2; snap s2; update_to s2
[[ -d "${NREAL}" && ! -L "${NREAL}" && "$(cat "${NREAL}/init.lua")" == "init2" && "$(cat "${NREAL}/lazy-lock.json")" == "lock2" ]] \
    && ok "resolve manage (unchanged link_tree): managed copies that keep following" || fail "manage ahead of change"

# ── mode: link — a user's own symlink is never repointed ────────────────────
L='~/.config/demo/tool'
LREAL="${HOME}/.config/demo/tool"
reset_case
manifest <<'EOF'
deploy:
  - src: files/tool
    dest: ~/.config/demo/tool
    mode: link
EOF
echo tool1 > "${STAGE}/files/tool"; snap s1
mkdir -p "$(dirname "${LREAL}")"; echo stowed > "${WORK}/stow-tool"; ln -s "${WORK}/stow-tool" "${LREAL}"
update_to s1
[[ "$(readlink "${LREAL}")" == "${WORK}/stow-tool" && -z "$(state_of "${L}")" ]] \
    && ok "link: a symlink the user made is left alone" || fail "link repointed a user symlink: $(readlink "${LREAL}")"

reset_case
manifest <<'EOF'
deploy:
  - src: files/tool
    dest: ~/.config/demo/tool
    mode: link
EOF
echo tool1 > "${STAGE}/files/tool"; snap s1; update_to s1
[[ "$(readlink "${LREAL}")" == "${MDIR}/current/files/tool" ]] && ok "link: new file linked via current" || fail "link new"
echo edited > "${LREAL}"
echo tool2 > "${STAGE}/files/tool"; snap s2; update_to s2
[[ "$(state_of "${L}")" == "held" && "$(cat "${LREAL}")" == "edited" ]] \
    && ok "link: an edit through the link holds it" || fail "link drift: '$(state_of "${L}")'"
workbench_files_resolve "${M}" "$(target_line "${L}")" manage >>"${LOG}" 2>&1
[[ ! -L "${LREAL}" && "$(cat "${LREAL}")" == "edited" && "$(workbench_files_form_get "${M}" "${L}")" == "copy" ]] \
    && ok "resolve manage (link): becomes a managed copy holding your edit" || fail "link manage"
echo tool3 > "${STAGE}/files/tool"; snap s3; update_to s3
[[ "$(cat "${LREAL}")" == "edited" && "$(pending)" == "${L}|moved" ]] \
    && ok "managed copy (link): stays yours, upstream change pending" || fail "link managed after update: '$(pending)'"

# ═════════════════════ regressions from the independent review ═════════════

# ── resolve never touches what the user put in place of core's link ────────
reset_case
manifest <<'EOF'
deploy:
  - src: files/tool
    dest: ~/.config/demo/tool
    mode: link
EOF
echo tool1 > "${STAGE}/files/tool"; snap s1; update_to s1
rm -f "${LREAL}"; echo "my own tool" > "${LREAL}"
rc=0; workbench_files_resolve "${M}" "$(target_line "${L}")" keep >>"${LOG}" 2>&1 || rc=$?
[[ "${rc}" -eq 4 && "$(cat "${LREAL}")" == "my own tool" ]] \
    && ok "resolve keep: a file the user put in place of the link is untouched (rc 4)" || fail "resolve keep clobbered the user's file (rc ${rc})"

reset_case; nvim_stage init1 lock1; snap s1; update_to s1
rm -f "${NREAL}"; mkdir -p "${NREAL}"; echo mine > "${NREAL}/init.lua"
rc=0; workbench_files_resolve "${M}" "$(target_line "${N}")" manage >>"${LOG}" 2>&1 || rc=$?
[[ "${rc}" -eq 4 && "$(cat "${NREAL}/init.lua")" == "mine" && ! -e "${NREAL}/lazy-lock.json" ]] \
    && ok "resolve manage: a directory the user put in place of the link is untouched (rc 4)" || fail "resolve manage wrote into the user's dir (rc ${rc})"

# ── resolve use only acts on something pending ──────────────────────────────
reset_case; tmux_manifest
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
echo theirs > "${HOME}/.tmux.conf"
rc=0; workbench_files_resolve "${M}" "$(target_line "${T}")" use >>"${LOG}" 2>&1 || rc=$?
[[ "${rc}" -eq 3 && -e "${HOME}/.tmux.conf" ]] \
    && ok "resolve use on nothing pending: rc 3, nothing moved" || fail "resolve use acted without anything pending (rc ${rc})"

# ── a user's symlink at a copy dest is moved aside whole, and comes back ────
reset_case; tmux_manifest
mkdir -p "$(dirname "${TREAL}")"; echo stowed > "${WORK}/stow-tmux.conf"; ln -s "${WORK}/stow-tmux.conf" "${TREAL}"
workbench_files_default_policy_set follow
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
orig="$(workbench_files_ledger_field "${M}" "${T}" 5)"
[[ "$(content "${T}")" == "v1" && ! -L "${TREAL}" && -L "${orig}" && "$(readlink "${orig}")" == "${WORK}/stow-tmux.conf" \
    && "$(cat "${WORK}/stow-tmux.conf")" == "stowed" ]] \
    && ok "copy (host follow) over a user's symlink: the link itself is kept as the original" || fail "user symlink not preserved: original '${orig}'"
workbench_files_restore "${M}" "${T}" >>"${LOG}" 2>&1
[[ -L "${TREAL}" && "$(readlink "${TREAL}")" == "${WORK}/stow-tmux.conf" ]] \
    && ok "restore: the user's symlink is back" || fail "restore didn't put the symlink back"

# ── a '|' in a filename under a directory src can't forge target fields ─────
reset_case
manifest <<'EOF'
deploy:
  - src: files/dir/
    dest: ~/.config/demo/dir/
    mode: link
EOF
mkdir -p "${STAGE}/files/dir"
echo ok > "${STAGE}/files/dir/fine.conf"
echo evil > "${STAGE}/files/dir/P|Q|.tmux.conf|deploy|link||link"
snap s1; update_to s1
targets="$(workbench_files_targets "${M}")"
[[ "$(printf '%s\n' "${targets}" | wc -l | tr -d ' ')" == "1" ]] && grep -q '|~/.config/demo/dir/fine.conf|' <<< "${targets}" \
    && ! grep -q '^\.tmux\.conf|' <<< "${targets}" && [[ ! -e "${HOME}/.tmux.conf" ]] \
    && ok "targets: a '|' in a snapshot filename is refused, nothing forged" || fail "forged target: ${targets}"

# ── drift backups keep relative paths ───────────────────────────────────────
reset_case; nvim_stage init1 lock1; mkdir -p "${STAGE}/lua/plugins"; echo plug > "${STAGE}/lua/plugins/init.lua"
snap s1; update_to s1
echo top-local > "${NREAL}/init.lua"; echo plug-local > "${NREAL}/lua/plugins/init.lua"
workbench_files_policy_set "${M}" "${N}" follow
nvim_stage init2 lock2; mkdir -p "${STAGE}/lua/plugins"; echo plug2 > "${STAGE}/lua/plugins/init.lua"; snap s2; update_to s2
bdir="$(find "${BACKUPS}" -mindepth 3 -maxdepth 3 -type d -name 'demo-nvim.*' | head -1)"
[[ -n "${bdir}" && "$(cat "${bdir}/init.lua" 2>/dev/null)" == "top-local" && "$(cat "${bdir}/lua/plugins/init.lua" 2>/dev/null)" == "plug-local" ]] \
    && ok "drift backup: one directory, relative paths kept" || fail "drift backup lost structure: '${bdir}'"

# ── follow, but the backup can't be made: held instead, nothing lost ────────
reset_case; nvim_stage init1 lock1; snap s1; update_to s1
workbench_files_policy_set "${M}" "${N}" follow
echo lock-local > "${NREAL}/lazy-lock.json"
mkdir -p "$(dirname "${BACKUPS}")"; : > "${BACKUPS}"
nvim_stage init2 lock2; snap s2; update_to s2
rm -f "${BACKUPS}"
[[ "$(state_of "${N}")" == "held" && "$(cat "${NREAL}/lazy-lock.json")" == "lock-local" ]] \
    && ok "follow with an unusable backup root: held instead, change kept" || fail "follow lost the change: state '$(state_of "${N}")'"

# ── skip on a linked entry really stops it following ────────────────────────
reset_case; nvim_stage init1 lock1; snap s1; update_to s1
workbench_files_policy_set "${M}" "${N}" skip
nvim_stage init2 lock2; snap s2; update_to s2
[[ -d "${NREAL}" && ! -L "${NREAL}" && "$(cat "${NREAL}/init.lua")" == "init1" && "$(state_of "${N}")" == "user" ]] \
    && ok "skip on a linked entry: frozen as your own copy, no longer follows" || fail "skip link still followed: '$(cat "${NREAL}/init.lua")'"

# ── switching an entry between copy and link ────────────────────────────────
reset_case
manifest <<'EOF'
deploy:
  - src: files/tool
    dest: ~/.config/demo/tool
    mode: link
EOF
echo tool1 > "${STAGE}/files/tool"; snap s1; update_to s1
manifest <<'EOF'
deploy:
  - src: files/tool
    dest: ~/.config/demo/tool
EOF
echo tool2 > "${STAGE}/files/tool"; snap s2; update_to s2
[[ ! -L "${LREAL}" && "$(cat "${LREAL}")" == "tool2" && "$(state_of "${L}")" == "active" && -z "$(pending)" ]] \
    && ok "link → copy: core's link becomes a managed copy" || fail "link→copy: pending '$(pending)'"
manifest <<'EOF'
deploy:
  - src: files/tool
    dest: ~/.config/demo/tool
    mode: link
EOF
echo tool3 > "${STAGE}/files/tool"; snap s3; update_to s3
[[ "$(readlink "${LREAL}")" == "${MDIR}/current/files/tool" ]] \
    && ok "copy → link: core's unedited copy becomes the link" || fail "copy→link: '$(readlink "${LREAL}")'"

# ── a pre-D81 copy of a link_tree module is adopted as managed copies ───────
reset_case; nvim_stage init1 lock1; snap s1
nvim_stage init2 lock2; snap s2
workbench_snapshot_swap "${M}" "${MDIR}/snapshots/s1"
mkdir -p "${NREAL}/lua"; cp "${MDIR}/snapshots/s1/init.lua" "${MDIR}/snapshots/s1/lua/options.lua" "${NREAL}/" 2>/dev/null
cp "${MDIR}/snapshots/s1/lua/options.lua" "${NREAL}/lua/"; rm -f "${NREAL}/options.lua"
cp "${MDIR}/snapshots/s1/workbench.yml" "${NREAL}/"
echo lock-local > "${NREAL}/lazy-lock.json"
update_to s2
[[ -d "${NREAL}" && ! -L "${NREAL}" && "$(cat "${NREAL}/init.lua")" == "init2" && "$(cat "${NREAL}/lazy-lock.json")" == "lock-local" \
    && "$(state_of "${N}")" == "converted" ]] \
    && ok "pre-D81 copied tree: adopted as managed copies — defaults refreshed, your lock kept" || fail "adoption: state '$(state_of "${N}")', init '$(cat "${NREAL}/init.lua")'"

# ── a snapshot carrying the user's changes is never swapped back in ─────────
reset_case; nvim_stage init1 lock1; snap s1; update_to s1
echo lock-local > "${NREAL}/lazy-lock.json"
nvim_stage init2 lock2; snap s2; update_to s2
workbench_files_snapshot_reusable "${M}" "${MDIR}/snapshots/s1" \
    && fail "a held, changed snapshot was reported reusable" || ok "reuse check: a held, changed snapshot is not reusable"

# ── a held entry whose manifest entry was dropped can still be resolved ─────
manifest <<'EOF'
deploy: []
EOF
snap s3; update_to s3
line="$(workbench_files_row_as_target "${M}" "${N}")"
workbench_files_resolve "${M}" "${line}" use >>"${LOG}" 2>&1
[[ "$(state_of "${N}")" == "active" ]] && ! workbench_files_pinned_snapshots "${M}" | grep -q . \
    && ok "orphaned held entry: resolvable via its ledger row, snapshot unpinned" || fail "orphaned held: state '$(state_of "${N}")'"

# ── restore leaves a directory the user put in place of the link ────────────
reset_case; nvim_stage init1 lock1; snap s1; update_to s1
rm -f "${NREAL}"; mkdir -p "${NREAL}"; echo mine > "${NREAL}/init.lua"
workbench_files_restore "${M}" "${N}" >>"${LOG}" 2>&1
[[ "$(cat "${NREAL}/init.lua" 2>/dev/null)" == "mine" ]] \
    && ok "restore: a directory the user put in place of the link is left alone" || fail "restore removed the user's dir"

# ── the engine refuses to swap when changes can't be secured ────────────────
EREPO="${WORK}/e2e"
reset_case
rm -rf "${EREPO}"; git init -q --bare "${EREPO}/n.git"; git clone -q "${EREPO}/n.git" "${EREPO}/src" 2>/dev/null
(
    cd "${EREPO}/src" || exit 1
    git config user.email t@t; git config user.name t
    printf 'version: 1\nbranch: main\ndeploy:\n  - src: .\n    dest: ~/.config/nvim\n    mode: link_tree\n' > .dotfiles-sync.yml
    echo init1 > init.lua; echo lock1 > lazy-lock.json
    git add -A; git commit -qm v1; git branch -M main; git push -q origin main; git tag v1.0.0; git push -q origin v1.0.0
)
_wb_require modules/add.sh
workbench_cmd_add e2e-nvim "${EREPO}/n.git" --private >>"${LOG}" 2>&1
E_CUR_BEFORE="$(readlink "$(workbench_module_dir e2e-nvim)/current")"
echo lock-local > "${NREAL}/lazy-lock.json"
(
    cd "${EREPO}/src" || exit 1
    echo init2 > init.lua; git commit -qam v2; git push -q origin main; git tag v1.1.0; git push -q origin v1.1.0
)
workbench_sync_module e2e-nvim manual >>"${LOG}" 2>&1
[[ "$(workbench_files_ledger_field e2e-nvim "${N}" 3)" == "held" && "$(cat "${NREAL}/lazy-lock.json")" == "lock-local" \
    && "$(readlink "$(workbench_module_dir e2e-nvim)/current")" != "${E_CUR_BEFORE}" ]] \
    && ok "real sync: a change through link_tree is held, the module still advances" || fail "real sync hold"
(
    cd "${EREPO}/src" || exit 1
    echo init3 > init.lua; git commit -qam v3; git push -q origin main; git tag v1.2.0; git push -q origin v1.2.0
)
E_CUR_BEFORE="$(readlink "$(workbench_module_dir e2e-nvim)/current")"
# Simulated failure, in a subshell so the stub doesn't outlive this check.
rc=0
# shellcheck disable=SC2317,SC2329  # called by workbench_sync_module (SC2317 on shellcheck < 0.11)
( workbench_files_before_swap() { return 1; }; workbench_sync_module e2e-nvim manual ) >>"${LOG}" 2>&1 || rc=$?
[[ "${rc}" -ne 0 && "$(readlink "$(workbench_module_dir e2e-nvim)/current")" == "${E_CUR_BEFORE}" ]] \
    && ok "real sync: if changes can't be secured, the update is refused and nothing swaps" || fail "sync swapped despite before_swap failing (rc ${rc})"
rm -rf "$(workbench_module_dir e2e-nvim)"

# ═════════════════════════════ engine wiring ═══════════════════════════════

reset_case
manifest <<'EOF'
deploy:
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    yield_to: [~/.tmux.conf]
  - src: files/seed.conf
    dest: ~/.config/demo/seed.conf
    lifecycle: seed
  - src: files/gen.sh
    dest: ~/.config/demo/gen.sh
    force: true
  - src: files/dir/
    dest: ~/.config/demo/dir/
  - src: files/tool
    dest: ~/.config/demo/tool
    mode: link
overrides_src: shell/overrides.sh
EOF
mkdir -p "${STAGE}/files/dir" "${STAGE}/shell"
echo v1 > "${STAGE}/files/tmux.conf"; echo seed1 > "${STAGE}/files/seed.conf"; echo gen1 > "${STAGE}/files/gen.sh"
echo a > "${STAGE}/files/dir/a.conf"; echo tool > "${STAGE}/files/tool"; echo '# knobs' > "${STAGE}/shell/overrides.sh"
snap s1; update_to s1
targets="$(workbench_files_targets "${M}")"
grep -qx "tmux.conf|files/tmux.conf|~/.config/tmux/tmux.conf|deploy|managed|~/.tmux.conf|copy|${MDIR}/current/files/tmux.conf" <<< "${targets}" \
    && ok "targets: copy entry with default lifecycle and yield_to" || fail "targets tmux: ${targets}"
grep -q '^gen.sh|files/gen.sh|~/.config/demo/gen.sh|deploy|generated||copy|' <<< "${targets}" \
    && ok "targets: force: true listed as generated" || fail "targets gen"
grep -q '^a.conf|files/dir/a.conf|~/.config/demo/dir/a.conf|deploy|managed||copy|' <<< "${targets}" \
    && ok "targets: directory src expanded per file" || fail "targets dir"
grep -qx "tool|files/tool|~/.config/demo/tool|deploy|link||link|${MDIR}/current/files/tool" <<< "${targets}" \
    && grep -q '|overrides|seed||copy|' <<< "${targets}" \
    && ok "targets: link entry via current; overrides_src as seed" || fail "targets link/overrides"

echo mine > "${TREAL}"; echo my-seed > "${HOME}/.config/demo/seed.conf"; echo my-gen > "${HOME}/.config/demo/gen.sh"
echo v2 > "${STAGE}/files/tmux.conf"; echo seed2 > "${STAGE}/files/seed.conf"; echo gen2 > "${STAGE}/files/gen.sh"
snap s2; update_to s2
[[ "$(content "${T}")" == "mine" && "$(cat "${HOME}/.config/demo/seed.conf")" == "my-seed" \
    && "$(cat "${HOME}/.config/demo/gen.sh")" == "gen2" ]] \
    && ok "engine: managed edit kept, seed kept, force: true follows upstream" || fail "engine wiring"

# ── yield_to gets full dest validation ──────────────────────────────────────
reset_case
manifest <<'EOF'
deploy:
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    yield_to: [~/.ssh/config]
EOF
echo v1 > "${STAGE}/files/tmux.conf"
workbench_manifest_paths_safe "${STAGE}/workbench.yml" "${M}" >>"${LOG}" 2>&1 && rc=0 || rc=$?
[[ "${rc}" -ne 0 ]] && grep -q "yield_to '~/.ssh/config' violates dest validation" "${LOG}" \
    && ok "paths_safe: a denylisted yield_to path refuses the manifest" || fail "denylisted yield_to accepted"

# ── unattended path: errexit doesn't trip on any branch ─────────────────────
reset_case; tmux_manifest
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
echo mine > "${TREAL}"
echo v2 > "${STAGE}/files/tmux.conf"; snap s2
workbench_files_record_sums "${M}" "${MDIR}/snapshots/s2"
workbench_snapshot_swap "${M}" "${MDIR}/snapshots/s2"
WB_PATH="${REPO_ROOT}/bin/wb" bash -c 'set --; source "${WB_PATH}" >/dev/null 2>&1; set -e; _wb_require core/installers-common.sh files/lifecycle.sh; workbench_deploy_module demo >/dev/null 2>&1; echo reached' > "${WORK}/errexit.out" 2>&1
grep -qx reached "${WORK}/errexit.out" && ok "deploy completes under set -e" || fail "deploy aborted under set -e: $(cat "${WORK}/errexit.out")"

# ── shell-start notice: interactive only, counts pending files ──────────────
reset_case; tmux_manifest
echo v1 > "${STAGE}/files/tmux.conf"; snap s1; update_to s1
echo mine > "${TREAL}"
echo v2 > "${STAGE}/files/tmux.conf"; snap s2; update_to s2
notice() {
    env -i HOME="${HOME}" XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" XDG_DATA_HOME="${XDG_DATA_HOME}" PATH="${PATH}" \
        bash "$@" -c "source '${REPO_ROOT}/lib/loader.sh'" 2>&1
}
notice -i | grep -q "workbench: 1 file(s) need your decision" \
    && ok "loader: interactive shell shows the pending-decision notice" || fail "loader notice missing"
notice | grep -q "need your decision" \
    && fail "loader notice leaked into a non-interactive shell" || ok "loader: no notice in a non-interactive shell"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
else
    echo "${FAILED} of ${check_no} checks FAILED."
    exit 1
fi
