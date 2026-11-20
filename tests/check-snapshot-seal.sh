#!/usr/bin/env bash
# tests/check-snapshot-seal.sh — D120: snapshots are read-only once written,
# except what a link-mode deploy points at (D81 lets a user edit through a
# link and holds the change).
#
# Permission bits are asserted with stat, so they are checked as root too;
# the checks that actually try to write are skipped under root (root ignores
# permission bits) and run in CI, which is not root.
#
# SC2088: '~/...' is quoted on purpose — ledger and target keys are the
#         literal ~/-form path, expanded only by _wb_expand_dest.
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
# Sealed snapshots can't be deleted until they are unsealed — the point.
trap 'chmod -R u+w "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT

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
SNAPN=0
IS_ROOT=false
[[ "$(id -u)" -eq 0 ]] && IS_ROOT=true

reset_case() {
    workbench_snapshot_unseal "${MDIR}"
    rm -rf "${MDIR}" "${HOME}" "${STAGE}" "$(workbench_files_conf_path)"
    SNAPN=0
    mkdir -p "${HOME}" "${STAGE}/files/nested"
    : > "${LOG}"
}

manifest() { { printf 'version: 2\n'; cat; } > "${STAGE}/workbench.yml"; }

snap() {
    mkdir -p "${MDIR}/snapshots"
    workbench_snapshot_unseal "${MDIR}/snapshots/$1"
    rm -rf "${MDIR}/snapshots/$1"
    cp -R "${STAGE}" "${MDIR}/snapshots/$1"
    SNAPN=$((SNAPN + 1))
    touch -t "202601010000.$(printf '%02d' "${SNAPN}")" "${MDIR}/snapshots/$1"
}

# update_to <name>: the engine's order for a snapshot already on disk.
update_to() {
    local new="${MDIR}/snapshots/$1"
    workbench_files_record_sums "${M}" "${new}"
    workbench_files_before_swap "${M}" >>"${LOG}" 2>&1
    workbench_snapshot_swap "${M}" "${new}"
    workbench_snapshot_prune "${M}" "${KEEP:-3}" >>"${LOG}" 2>&1
    workbench_deploy_module "${M}" >>"${LOG}" 2>&1
}

# writable <path>: true when any write bit is set
writable() { [[ $(( 8#$(_wb_files_mode "$1") & 8#222 )) -ne 0 ]]; }
snapdir()  { printf '%s/snapshots/%s\n' "${MDIR}" "$1"; }

# ── 1. A copy entry and a link entry: everything sealed but the link ────────
reset_case
manifest <<'EOF'
deploy:
  - src: files/plain.conf
    dest: ~/.config/demo/plain.conf
  - src: files/linked.conf
    dest: ~/.config/demo/linked.conf
    mode: link
EOF
echo plain1 > "${STAGE}/files/plain.conf"; echo linked1 > "${STAGE}/files/linked.conf"
echo other > "${STAGE}/files/nested/other.conf"
snap s1; update_to s1
S1="$(snapdir s1)"

if ! writable "${S1}" && ! writable "${S1}/files/plain.conf" && ! writable "${S1}/files/nested" && ! writable "${S1}/files/nested/other.conf"; then
    ok "a deployed snapshot is read-only: root, files and nested directories"
else
    fail "snapshot still has write bits: root $(_wb_files_mode "${S1}"), plain $(_wb_files_mode "${S1}/files/plain.conf"), nested $(_wb_files_mode "${S1}/files/nested")"
fi

if writable "${S1}/files/linked.conf" && writable "${S1}/files"; then
    ok "the file a link points at, and its directory, stay writable"
else
    fail "link target sealed: file $(_wb_files_mode "${S1}/files/linked.conf"), dir $(_wb_files_mode "${S1}/files")"
fi

if ! writable "${S1}/files/plain.conf" && ! writable "${S1}/files/nested/other.conf"; then
    ok "siblings of the link target are still read-only"
else
    fail "a sibling of the link target is writable"
fi

# The copy is the user's: it must not inherit the sealed source's missing bit.
PLAIN_REAL="$(_wb_expand_dest '~/.config/demo/plain.conf')"
if [[ -f "${PLAIN_REAL}" ]] && writable "${PLAIN_REAL}"; then
    ok "a copy deployed from a sealed file is owner-writable (mode $(_wb_files_mode "${PLAIN_REAL}"))"
else
    fail "deployed copy is read-only (mode $(_wb_files_mode "${PLAIN_REAL}" 2>/dev/null))"
fi

if [[ "${IS_ROOT}" == "true" ]]; then
    ok "writing into a sealed snapshot is refused — skipped, running as root"
else
    if ! ( echo x >> "${S1}/files/plain.conf" ) 2>/dev/null && ! ( touch "${S1}/new.txt" ) 2>/dev/null \
        && ! ( touch "${S1}/files/nested/new.txt" ) 2>/dev/null; then
        ok "editing a file, or creating one in a sealed directory, is refused"
    else
        fail "a sealed snapshot accepted a write"
    fi
    LINK_REAL="$(_wb_expand_dest '~/.config/demo/linked.conf')"
    if ( echo edited >> "${LINK_REAL}" ) 2>/dev/null && grep -q edited "${S1}/files/linked.conf"; then
        ok "writing through the link still works"
    else
        fail "the link target refused a write"
    fi
fi

# ── 2. Holds keep working: an edit through the link pins its snapshot ───────
LINK_REAL="$(_wb_expand_dest '~/.config/demo/linked.conf')"
echo edited >> "${LINK_REAL}"
echo linked2 > "${STAGE}/files/linked.conf"
snap s2; update_to s2
if [[ "$(workbench_files_ledger_field "${M}" '~/.config/demo/linked.conf' 3)" == "held" ]] \
    && [[ "$(readlink "${LINK_REAL}")" == "${S1}/files/linked.conf" ]]; then
    ok "an edit made through a link is still held at its snapshot after sealing"
else
    fail "hold broke: state '$(workbench_files_ledger_field "${M}" '~/.config/demo/linked.conf' 3)', link '$(readlink "${LINK_REAL}")'"
fi
if writable "${S1}/files/linked.conf"; then
    ok "the held snapshot's edited file is still writable"
else
    fail "the held snapshot's file was sealed"
fi
# The held entry now points into s1, so s2 has no active link target to keep open.
if ! writable "$(snapdir s2)" && ! writable "$(snapdir s2)/files" && ! writable "$(snapdir s2)/files/linked.conf"; then
    ok "the new current snapshot is sealed in full: the held entry's edits live in s1"
else
    fail "new snapshot modes: root $(_wb_files_mode "$(snapdir s2)"), files $(_wb_files_mode "$(snapdir s2)/files")"
fi

# ── 3. A link_tree entry makes the whole snapshot the user's ────────────────
reset_case
manifest <<'EOF'
deploy:
  - src: .
    dest: ~/.config/demo-tree
    mode: link_tree
EOF
echo init > "${STAGE}/files/init.lua"
snap s1; update_to s1
if writable "$(snapdir s1)" && writable "$(snapdir s1)/files" && writable "$(snapdir s1)/files/init.lua"; then
    ok "a link_tree entry leaves the whole snapshot writable"
else
    fail "link_tree snapshot was sealed"
fi

# A staged first sync seals before any link entry exists; the deploy that
# follows must open the whole tree again, not leave it sealed.
reset_case
manifest <<'EOF'
deploy:
  - src: .
    dest: ~/.config/demo-tree
    mode: link_tree
EOF
echo init > "${STAGE}/files/init.lua"
snap s1
workbench_files_record_sums "${M}" "$(snapdir s1)"
workbench_snapshot_swap "${M}" "$(snapdir s1)"
workbench_files_seal_snapshots "${M}"
if ! writable "$(snapdir s1)/files/init.lua"; then
    ok "staged first sync: with no link entry yet, the snapshot is sealed in full"
else
    fail "staged snapshot was not sealed"
fi
workbench_deploy_module "${M}" >>"${LOG}" 2>&1
if writable "$(snapdir s1)" && writable "$(snapdir s1)/files/init.lua"; then
    ok "the deploy that creates a link_tree entry reopens the sealed snapshot"
else
    fail "link_tree snapshot stayed sealed after deploy: root $(_wb_files_mode "$(snapdir s1)"), file $(_wb_files_mode "$(snapdir s1)/files/init.lua")"
fi

# ── 4. Copy mode becoming link mode opens the target ────────────────────────
reset_case
manifest <<'EOF'
deploy:
  - src: files/tool.conf
    dest: ~/.config/demo/tool.conf
EOF
echo t1 > "${STAGE}/files/tool.conf"
snap s1; update_to s1
manifest <<'EOF'
deploy:
  - src: files/tool.conf
    dest: ~/.config/demo/tool.conf
    mode: link
EOF
echo t2 > "${STAGE}/files/tool.conf"
snap s2; update_to s2
if writable "$(snapdir s2)/files/tool.conf" && [[ -L "$(_wb_expand_dest '~/.config/demo/tool.conf')" ]]; then
    ok "a copy entry that becomes a link has its new target left writable"
else
    fail "copy->link: target mode $(_wb_files_mode "$(snapdir s2)/files/tool.conf"), link? $([[ -L "$(_wb_expand_dest '~/.config/demo/tool.conf')" ]] && echo yes || echo no)"
fi

# ── 5. Deleting: prune and remove unseal first ──────────────────────────────
reset_case
manifest <<'EOF'
deploy:
  - src: files/plain.conf
    dest: ~/.config/demo/plain.conf
EOF
echo p > "${STAGE}/files/plain.conf"
for n in s1 s2 s3 s4 s5; do snap "${n}"; update_to "${n}"; done
if [[ ! -d "$(snapdir s1)" && ! -d "$(snapdir s2)" && -d "$(snapdir s3)" && -d "$(snapdir s5)" ]]; then
    ok "prune removes sealed old snapshots, keeping the newest three"
else
    fail "prune: s1 $([[ -d "$(snapdir s1)" ]] && echo present || echo gone), s2 $([[ -d "$(snapdir s2)" ]] && echo present || echo gone)"
fi
if ! writable "$(snapdir s3)" && ! writable "$(snapdir s4)"; then
    ok "older snapshots that are no longer current stay sealed in full"
else
    fail "a non-current snapshot is writable"
fi
workbench_snapshot_remove "$(snapdir s5)"
[[ ! -e "$(snapdir s5)" ]] && ok "workbench_snapshot_remove deletes a sealed tree" || fail "workbench_snapshot_remove left $(snapdir s5)"

# Sealing is idempotent, and unseal puts write access back for the owner.
workbench_files_seal_snapshots "${M}"; workbench_files_seal_snapshots "${M}"
workbench_snapshot_unseal "${MDIR}"
if writable "$(snapdir s3)" && writable "$(snapdir s3)/files/plain.conf"; then
    ok "unseal restores owner write access, and sealing twice is harmless"
else
    fail "unseal did not restore write access"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
