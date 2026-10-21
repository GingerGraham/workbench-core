#!/usr/bin/env bash
# lib/files/lifecycle.sh — core's single owner of every file a module causes
# to exist outside its own snapshot (docs/decisions-log.md D81).
#
# Modules declare WHAT they provide (deploy[], overrides_src). Everything
# about WHEN and WHETHER a file is written, linked, backed up, refreshed,
# held, left alone, or restored is decided here, from:
#
#   1. the module's declared lifecycle for a copy-mode entry
#      (seed|managed|generated) and its yield_to paths
#   2. the host's policy for that entry (files.policy) or the host default
#      (files.conf DEFAULT_POLICY)
#   3. the file's condition, measured against the ledger (files.list) —
#      what core last wrote there — and, for linked entries, against the
#      snapshot's recorded checksums (sums/<snapshot>)
#
# Invariant: core never discards a change it didn't make. A user's file is
# left alone; an edited copy stops updating; a change made through a link
# into a snapshot holds that entry at its current version until the user
# chooses (workbench_files_resolve). The only exceptions are an explicit
# 'follow' policy and explicit commands, and both back the change up first.
# Anything the user put at a path is moved aside whole — a symlink as a
# symlink, a directory as a directory — never deleted or written through.
#
# Bash 3.2: no associative arrays, no mapfile, no ${var,,}. Every state file
# here is '|'-delimited data read with awk/read — never sourced.
#
# Depends on (loaded in the sync path): workbench_module_dir,
# workbench_module_current_dir, workbench_modules_dir (lib/sync/state.sh),
# _wb_expand_dest, _wb_backup_path_new, workbench_backup_existing_file
# (lib/sync/engine.sh), workbench_resolve_manifest_path,
# workbench_manifest_deploy_entries, workbench_manifest_scalar,
# _wb_path_is_safe_relative, _wb_dest_is_safe, _wb_dest_physical_is_safe
# (lib/manifest/parse.sh), _wb_sha256 (lib/core/installers-common.sh),
# log_info/log_warn/log_error.

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/files/lifecycle.sh" "0.2.0" || true

# ── Paths ───────────────────────────────────────────────────────────────────

workbench_files_ledger_path()    { printf '%s/files.list\n'      "$(workbench_module_dir "$1")"; }
workbench_files_policy_path()    { printf '%s/files.policy\n'    "$(workbench_module_dir "$1")"; }
workbench_files_displaced_path() { printf '%s/files.displaced\n' "$(workbench_module_dir "$1")"; }
workbench_files_forms_path()     { printf '%s/files.forms\n'     "$(workbench_module_dir "$1")"; }
workbench_files_pending_path()   { printf '%s/files.pending\n'   "$(workbench_module_dir "$1")"; }

# sums/<snapshot-basename>, beside snapshots/ rather than inside it: a
# snapshot is the fetched commit, byte for byte.
workbench_files_sums_path() {
    printf '%s/sums/%s\n' "$(workbench_module_dir "$1")" "$(basename "$2")"
}

# Host-wide, not per module: sibling of the modules/ root, so a test that
# overrides WORKBENCH_MODULES_DIR isolates this file too.
workbench_files_conf_path() {
    printf '%s/files.conf\n' "$(dirname "$(workbench_modules_dir)")"
}

# ── Small shared helpers ────────────────────────────────────────────────────

# Rewrites <file> without lines whose field <n> equals <value>, then appends
# <line> if given. Atomic (temp file + rename). Creates <file> with <header>.
_wb_files_table_put() {
    local file="$1" header="$2" n="$3" value="$4" line="${5:-}" tmp
    mkdir -p "$(dirname "${file}")" || return 1
    tmp="$(mktemp "${file}.XXXXXX")" || return 1
    if [[ -f "${file}" ]]; then
        awk -F'|' -v n="${n}" -v v="${value}" '$n != v' "${file}" > "${tmp}"
    else
        printf '%s\n' "${header}" > "${tmp}"
    fi
    [[ -n "${line}" ]] && printf '%s\n' "${line}" >> "${tmp}"
    mv "${tmp}" "${file}"
}

# Rejects anything that would corrupt a '|'-delimited, one-per-line table or
# a comma-joined yield list.
_wb_files_key_ok() {
    case "$1" in
        ''|*'|'*|*$'\n'*) return 1 ;;
    esac
    return 0
}

# Octal permission bits of a file, Linux (GNU stat) or macOS (BSD stat).
_wb_files_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# True when <real> is a symlink into this module's own state — core's link.
_wb_files_is_our_link() {
    local module="$1" real="$2"
    [[ -L "${real}" ]] || return 1
    case "$(readlink "${real}")" in
        "$(workbench_module_dir "${module}")/"*) return 0 ;;
    esac
    return 1
}

# D75's symlink-resolved check for anything core is about to write, move or
# remove at a user path. overrides_src's engine-computed path lives under
# ~/.config/workbench/, denylisted by design, and is exempt (D48).
_wb_files_path_safe() {
    local module="$1" path="$2" kind="${3:-deploy}"
    [[ "${kind}" == "overrides" ]] && return 0
    if ! _wb_dest_physical_is_safe "$(_wb_expand_dest "${path%/}")" "${module}"; then
        log_error "  refusing ${path} — resolves through a symlink to a denied location"
        return 1
    fi
}

# Atomic file write: copy beside the target, then rename over it. Refuses a
# symlink or directory at the target — mv onto either moves the file INTO
# the directory, and replacing a symlink is the caller's decision (ours:
# remove; the user's: move aside), never this function's.
_wb_files_write() {
    local abs_src="$1" real="$2" tmp
    if [[ -L "${real}" || -d "${real}" ]]; then
        log_error "  ${real} is a symlink or directory — not writing over it"
        return 1
    fi
    mkdir -p "$(dirname "${real}")" || return 1
    tmp="$(mktemp "${real}.wb.XXXXXX")" || return 1
    if cp "${abs_src}" "${tmp}" && chmod "$(_wb_files_mode "${abs_src}")" "${tmp}" && mv -f "${tmp}" "${real}"; then
        return 0
    fi
    rm -f "${tmp}"
    return 1
}

# Creates or repoints a symlink. Only ever called when <real> is absent or
# is core's own link. ln -sfn (GNU) / -sfh (BSD) never descends into an
# existing symlink-to-directory, unlike mv (see workbench_snapshot_swap).
_wb_files_link() {
    local real="$1" target="$2"
    mkdir -p "$(dirname "${real}")" || return 1
    ln -sfn "${target}" "${real}" 2>/dev/null || ln -sfh "${target}" "${real}"
}

# Moves whatever is at <real> — file, directory or symlink, as-is — into the
# backup root. Prints the backup path.
_wb_files_move_aside() {
    local module="$1" real="$2" backup
    backup="$(_wb_backup_path_new "${real}" "${module}")" || return 1
    if ! mv "${real}" "${backup}"; then
        log_error "  failed to move ${real} aside"
        return 1
    fi
    log_info "  moved ${real} -> ${backup}" >&2
    printf '%s\n' "${backup}"
}

# Lists every regular file under a directory as paths relative to it, NUL-
# separated. Traverses the physical path, so a symlinked start (current) is
# entered the same way on GNU and BSD find; .git is never included.
_wb_files_list_tree() {
    local dir="$1" phys file
    phys="$(cd "${dir}" 2>/dev/null && pwd -P)" || return 1
    while IFS= read -r -d '' file; do
        printf '%s\0' "${file#"${phys}"/}"
    done < <(find "${phys}" -name .git -prune -o -type f -print0)
}

# Copies every regular file under <src> (file or directory) to <dst>,
# preserving relative paths. Symlinks inside a snapshot are never followed
# or reproduced — the same rule the copy-mode deploy loop applies.
_wb_files_copy_tree() {
    local src="$1" dst="$2" rel
    if [[ -f "${src}" && ! -L "${src}" ]]; then
        _wb_files_write "${src}" "${dst}"
        return $?
    fi
    mkdir -p "${dst}" || return 1
    while IFS= read -r -d '' rel; do
        _wb_files_write "${src%/}/${rel}" "${dst%/}/${rel}" || return 1
    done < <(_wb_files_list_tree "${src}")
}

# ── Ledger: <dest>|<kind>|<state>|<sha>|<original>|<ack>|<pin> ───────────────
#
#   dest      ~/-form path as declared (directory children as <dest>/<path>),
#             or the absolute engine-computed path for overrides_src. The key.
#   kind      deploy | overrides | layer (D82 — key '<target>#<position>',
#             sha of the block text, original '-', '+created' or a backup;
#             see lib/files/layers.sh)
#   state     active    — core wrote (or linked) it
#             user      — the user chose to own it ('resolve keep', or 'skip'
#                         on a linked entry); never written by core again
#             removed   — core wrote it, the user deleted it; an opt-out
#             restored  — 'wb files restore' ran; never rewritten
#             held      — linked, with changes made through the link; pinned
#             converted — a linked directory now delivered as managed copies
#   sha       copy: sha256 of what core last wrote. linked: 'link:<src-rel>'.
#   original  backup of pre-workbench content core displaced at dest, or '-'
#   ack       copy: the upstream sha256 the user chose to keep their edit over
#   pin       held: the snapshot basename the entry is held at
#
# Content core finds that isn't its own gets no row: it's re-evaluated on
# every deploy, so a later 'follow' (per entry or host-wide) applies to it.
_WB_FILES_LEDGER_HEADER='# dest|kind|state|sha|original|ack|pin'

workbench_files_ledger_get() {
    local file
    file="$(workbench_files_ledger_path "$1")"
    [[ -f "${file}" ]] || return 0
    awk -F'|' -v d="$2" '$1 == d { print; exit }' "${file}"
}

# Prints one field (1-based) of <dest>'s row, or nothing.
workbench_files_ledger_field() {
    workbench_files_ledger_get "$1" "$2" | awk -F'|' -v n="$3" '{ print $n }'
}

# workbench_files_ledger_set <module> <dest> <kind> <state> <sha> [<original>] [<ack>] [<pin>]
# <original> defaults to the row's existing value: once recorded, the
# pre-workbench original is only ever cleared by restore.
workbench_files_ledger_set() {
    local module="$1" dest="$2" kind="$3" state="$4" sha="$5"
    local original="${6:-}" ack="${7:--}" pin="${8:--}"
    if [[ -z "${original}" ]]; then
        original="$(workbench_files_ledger_field "${module}" "${dest}" 5)"
        [[ -z "${original}" ]] && original="-"
    fi
    _wb_files_table_put "$(workbench_files_ledger_path "${module}")" "${_WB_FILES_LEDGER_HEADER}" 1 "${dest}" \
        "${dest}|${kind}|${state}|${sha}|${original}|${ack}|${pin}"
}

workbench_files_ledger_delete() {
    _wb_files_table_put "$(workbench_files_ledger_path "$1")" "${_WB_FILES_LEDGER_HEADER}" 1 "$2"
}

workbench_files_ledger_rows() {
    local file
    file="$(workbench_files_ledger_path "$1")"
    [[ -f "${file}" ]] && grep -v '^#' "${file}"
    return 0
}

# Snapshot basenames held entries are pinned to — workbench_snapshot_prune
# never deletes these.
workbench_files_pinned_snapshots() {
    workbench_files_ledger_rows "$1" | awk -F'|' '$3 == "held" && $7 != "-" { print $7 }'
}

# ── Policy ──────────────────────────────────────────────────────────────────

_wb_files_policy_valid() {
    case "$1" in skip|seed|managed|follow) return 0 ;; esac
    return 1
}

workbench_files_policy_get() {
    local file value
    file="$(workbench_files_policy_path "$1")"
    [[ -f "${file}" ]] || return 0
    value="$(awk -F'|' -v d="$2" '$1 == d { print $2; exit }' "${file}")"
    _wb_files_policy_valid "${value}" && printf '%s\n' "${value}"
    return 0
}

# workbench_files_policy_set <module> <dest> <policy|default>
# "default" removes the per-entry line, falling back to lifecycle/host default.
workbench_files_policy_set() {
    local module="$1" dest="$2" policy="$3" line=""
    if [[ "${policy}" != "default" ]]; then
        _wb_files_policy_valid "${policy}" || { log_error "workbench_files_policy_set: invalid policy '${policy}' (skip|seed|managed|follow|default)"; return 2; }
        line="${dest}|${policy}"
    fi
    _wb_files_table_put "$(workbench_files_policy_path "${module}")" '# dest|policy' 1 "${dest}" "${line}"
}

# Host default applies to lifecycle: managed entries (and linked entries)
# only. Never to seed (a file meant to be edited) or generated (a file
# never meant to be).
workbench_files_default_policy() {
    local file value=""
    file="$(workbench_files_conf_path)"
    [[ -f "${file}" ]] && value="$(grep '^DEFAULT_POLICY=' "${file}" 2>/dev/null | tail -1 | cut -d= -f2)"
    case "${value}" in
        managed|follow) printf '%s\n' "${value}" ;;
        *)              printf 'managed\n' ;;
    esac
}

workbench_files_default_policy_set() {
    local value="$1" file tmp
    case "${value}" in
        managed|follow) ;;
        *) log_error "workbench_files_default_policy_set: must be managed or follow"; return 2 ;;
    esac
    file="$(workbench_files_conf_path)"
    mkdir -p "$(dirname "${file}")"
    tmp="$(mktemp "${file}.XXXXXX")" || return 1
    [[ -f "${file}" ]] && grep -v '^DEFAULT_POLICY=' "${file}" > "${tmp}"
    printf 'DEFAULT_POLICY=%s\n' "${value}" >> "${tmp}"
    mv "${tmp}" "${file}"
}

# workbench_files_effective_policy <module> <dest> <lifecycle>
# <lifecycle> is 'link' for linked entries (link, link_tree).
workbench_files_effective_policy() {
    local module="$1" dest="$2" lifecycle="$3" policy
    policy="$(workbench_files_policy_get "${module}" "${dest}")"
    if [[ -n "${policy}" ]]; then
        printf '%s\n' "${policy}"
        return 0
    fi
    case "${lifecycle}" in
        seed)      printf 'seed\n' ;;
        generated) printf 'follow\n' ;;
        *)         workbench_files_default_policy ;;
    esac
}

# True when the effective policy was chosen for this file specifically (a
# files.policy row, or lifecycle: generated) rather than by the host default.
_wb_files_policy_explicit() {
    local module="$1" dest="$2" lifecycle="$3"
    [[ -n "$(workbench_files_policy_get "${module}" "${dest}")" || "${lifecycle}" == "generated" ]]
}

# ── Forms: a linked entry the user chose to have managed as copies ──────────

workbench_files_form_get() {
    local file
    file="$(workbench_files_forms_path "$1")"
    [[ -f "${file}" ]] || return 0
    awk -F'|' -v d="$2" '$1 == d { print $2; exit }' "${file}"
}

workbench_files_form_set() {
    local line=""
    [[ "$3" == "copy" ]] && line="$2|copy"
    _wb_files_table_put "$(workbench_files_forms_path "$1")" '# dest|form' 1 "$2" "${line}"
}

# ── Displacement: moving the user's competing config aside, on request ─────
#
# files.displaced: <owner-dest>|<path>|<backup>. Only explicit user commands
# displace anything ('wb files use', a per-entry 'follow' applied now).
# Unattended sync never does.

_wb_files_displace() {
    local module="$1" owner="$2" path="$3" real backup
    real="$(_wb_expand_dest "${path}")"
    [[ -e "${real}" || -L "${real}" ]] || return 0
    _wb_files_path_safe "${module}" "${path}" || return 1
    backup="$(_wb_files_move_aside "${module}" "${real}")" || return 1
    _wb_files_table_put "$(workbench_files_displaced_path "${module}")" '# owner|path|backup' 2 "${path}" \
        "${owner}|${path}|${backup}"
}

# Puts back everything displaced on behalf of <owner>. Copies, so the backup
# stays. Never overwrites something that has appeared at the path since.
_wb_files_undisplace() {
    local module="$1" owner="$2" file o p b real rc=0
    file="$(workbench_files_displaced_path "${module}")"
    [[ -f "${file}" ]] || return 0
    while IFS='|' read -r o p b; do
        [[ "${o}" == "${owner}" ]] || continue
        real="$(_wb_expand_dest "${p}")"
        if [[ -e "${real}" || -L "${real}" ]]; then
            log_warn "  ${p} exists again — leaving it; your earlier version is at ${b}"
        elif ! _wb_files_path_safe "${module}" "${p}"; then
            rc=1
        elif [[ -e "${b}" || -L "${b}" ]]; then
            mkdir -p "$(dirname "${real}")"
            if cp -a "${b}" "${real}"; then
                log_info "  put back ${p} from ${b}"
            else
                log_error "  failed to put back ${p} from ${b}"
                rc=1
                continue
            fi
        fi
        _wb_files_table_put "${file}" '# owner|path|backup' 2 "${p}"
    done < <(grep -v '^#' "${file}")
    return "${rc}"
}

# True when any comma-separated ~/-form path in <yield_csv> exists; sets
# WB_FILES_YIELD_PATH to the first hit. Unsafe paths are ignored here
# (workbench_manifest_paths_safe refuses the manifest before it gets here).
_wb_files_yield_hit() {
    local yield_csv="$1" path real
    WB_FILES_YIELD_PATH=""
    [[ -z "${yield_csv}" ]] && return 1
    while IFS= read -r path; do
        [[ -z "${path}" ]] && continue
        _wb_dest_is_safe "${path}" "" || continue
        real="$(_wb_expand_dest "${path}")"
        if [[ -e "${real}" || -L "${real}" ]]; then
            WB_FILES_YIELD_PATH="${path}"
            return 0
        fi
    done < <(printf '%s\n' "${yield_csv}" | tr ',' '\n')
    return 1
}

_wb_files_displace_yields() {
    local module="$1" owner="$2" yield_csv="$3" path
    [[ -z "${yield_csv}" ]] && return 0
    while IFS= read -r path; do
        [[ -z "${path}" ]] && continue
        _wb_dest_is_safe "${path}" "" || continue
        _wb_files_displace "${module}" "${owner}" "${path}" || return 1
    done < <(printf '%s\n' "${yield_csv}" | tr ',' '\n')
}

# ── Snapshot checksums and drift ────────────────────────────────────────────

# Prints "<sha256>  <path>" for every regular file at or under <rel>
# (relative to <dir>; '.' for all), paths relative to <dir>.
_wb_files_sum_tree() {
    local dir="$1" rel="${2:-.}"
    local -a cmd
    if command -v sha256sum &>/dev/null; then
        cmd=(sha256sum)
    else
        cmd=(shasum -a 256)
    fi
    ( cd "${dir}" 2>/dev/null && [[ -e "${rel}" ]] && find "${rel}" -type f -exec "${cmd[@]}" {} + ) \
        | sed 's#^\([0-9a-f]\{64\}\)  \./#\1  #'
}

# Records checksums for a snapshot, once — a snapshot never changes
# legitimately after it's fetched.
workbench_files_record_sums() {
    local module="$1" snap="$2" out tmp
    out="$(workbench_files_sums_path "${module}" "${snap}")"
    [[ -f "${out}" ]] && return 0
    mkdir -p "$(dirname "${out}")" || return 1
    tmp="$(mktemp "${out}.XXXXXX")" || return 1
    _wb_files_sum_tree "${snap}" . > "${tmp}" || { rm -f "${tmp}"; return 1; }
    mv "${tmp}" "${out}"
}

# workbench_files_snapshot_drift <module> <snapshot_dir> <rel>
# What changed at or under <rel> since the snapshot was fetched:
#   M <path>  modified    A <path>  added    D <path>  deleted
# Prints nothing when no checksums were recorded for this snapshot.
workbench_files_snapshot_drift() {
    local module="$1" snap="$2" rel="${3:-.}" sums
    sums="$(workbench_files_sums_path "${module}" "${snap}")"
    [[ -f "${sums}" ]] || return 0
    _wb_files_sum_tree "${snap}" "${rel}" | awk -v pre="${rel}" '
        function inscope(p) { return pre == "." || p == pre || index(p, pre "/") == 1 }
        FNR == NR { p = substr($0, 67); if (inscope(p)) rec[p] = substr($0, 1, 64); next }
        { p = substr($0, 67); cur[p] = substr($0, 1, 64) }
        END {
            for (p in cur) { if (!(p in rec)) print "A " p; else if (cur[p] != rec[p]) print "M " p }
            for (p in rec) if (!(p in cur)) print "D " p
        }
    ' "${sums}" -
}

# True when a snapshot on disk may be swapped in again: not pinned by a held
# entry, and unchanged since it was fetched. A snapshot that was held, then
# left behind, then returned to (a rollback) can carry the user's changes.
workbench_files_snapshot_reusable() {
    local module="$1" snap="$2"
    if workbench_files_pinned_snapshots "${module}" | grep -qxF "$(basename "${snap}")"; then
        return 1
    fi
    [[ -z "$(workbench_files_snapshot_drift "${module}" "${snap}" .)" ]]
}

# Recorded checksum of one snapshot file, or nothing.
_wb_files_recorded_sum() {
    local sums
    sums="$(workbench_files_sums_path "$1" "$2")"
    [[ -f "${sums}" ]] || return 0
    awk -v p="$3" 'substr($0, 67) == p { print substr($0, 1, 64); exit }' "${sums}"
}

# Backs up every modified or added file in <drift> (from <snap>) into one
# backup directory named after <label>, keeping each file's relative path —
# after the snapshot is unpinned and pruned this is the only copy left.
_wb_files_backup_drift() {
    local module="$1" snap="$2" drift="$3" label="$4" dir st path
    printf '%s\n' "${drift}" | grep -q '^[MA] ' || return 0
    dir="$(_wb_backup_path_new "${label}" "${module}")" || return 1
    while IFS=' ' read -r st path; do
        [[ "${st}" == "M" || "${st}" == "A" ]] || continue
        mkdir -p "$(dirname "${dir}/${path}")" && cp -a "${snap}/${path}" "${dir}/${path}" || {
            log_error "  failed to back up ${path} from ${snap}"
            return 1
        }
    done <<< "${drift}"
    log_info "  backed up your changes -> ${dir}"
}

# ── Targets ─────────────────────────────────────────────────────────────────

# workbench_files_targets <module> [--log]
# The one derivation of what this module deploys on this platform. One line
# per target:
#   <basename>|<src_rel>|<dest>|<kind>|<lifecycle>|<yield_csv>|<mode>|<source>
#   mode     copy | link | link_tree
#   source   copy: the file to copy. link/link_tree: the symlink target,
#            always via <module>/current so it follows every update.
# A copy-mode directory src, and a link-mode directory src, expand to one
# line per file. A linked entry the user chose to manage (files.forms) is
# listed as copy-mode targets instead. overrides_src is a copy target with
# kind 'overrides', lifecycle 'seed'. D75 lexical checks, plus a field check
# on every path emitted (a '|' or newline in a filename inside a snapshot
# would otherwise forge fields); --log reports each refusal (the deploy
# path), otherwise silent. Layers (D82) follow, one line each:
#   <layer-id>|<src>|<target>#<position>|layer|managed||layer|<abs-src>
workbench_files_targets() {
    local module="$1" log_refusals="${2:-}" current_dir manifest
    local src dest dest_macos mode force platforms lifecycle yield_to
    local chosen effective abs rel path ok_yield form
    current_dir="$(workbench_module_current_dir "${module}")"
    [[ -d "${current_dir}" ]] || return 1
    manifest="$(workbench_resolve_manifest_path "${current_dir}")"

    while IFS='|' read -r src dest dest_macos mode force platforms lifecycle yield_to; do
        [[ -z "${src}" ]] && continue
        if [[ -n "${platforms}" ]]; then
            case "${WORKBENCH_OS:-}" in
                Mac)   printf '%s\n' "${platforms}" | tr ',' '\n' | grep -qx macos || continue ;;
                Linux) printf '%s\n' "${platforms}" | tr ',' '\n' | grep -qx linux || continue ;;
            esac
        fi
        chosen="${dest}"
        [[ "${WORKBENCH_OS:-}" == "Mac" && -n "${dest_macos}" ]] && chosen="${dest_macos}"
        if ! _wb_path_is_safe_relative "${src}" || ! _wb_dest_is_safe "${chosen}" "${module}" || ! _wb_files_key_ok "${chosen}"; then
            [[ -n "${log_refusals}" ]] && log_error "workbench_deploy_module: ${module}: refusing unsafe deploy entry (src: ${src}, dest: ${chosen})"
            continue
        fi
        ok_yield=""
        while IFS= read -r path; do
            [[ -z "${path}" ]] && continue
            if _wb_dest_is_safe "${path}" "${module}" && _wb_files_key_ok "${path}"; then
                ok_yield="${ok_yield:+${ok_yield},}${path}"
            elif [[ -n "${log_refusals}" ]]; then
                log_error "workbench_deploy_module: ${module}: ignoring unsafe yield_to path '${path}'"
            fi
        done < <(printf '%s\n' "${yield_to}" | tr ',' '\n')

        effective="${lifecycle:-managed}"
        [[ -z "${lifecycle}" && "${force}" == "true" ]] && effective="generated"
        # src '.' is the module's own current pointer, a symlink by design;
        # any other src that is a symlink is refused (D75).
        if [[ "${src}" == "." ]]; then abs="${current_dir}"; else abs="${current_dir}/${src%/}"; fi
        if [[ "${src}" != "." && -L "${abs}" ]]; then
            [[ -n "${log_refusals}" ]] && log_error "workbench_deploy_module: ${module}: refusing deploy src '${src}' — it is a symlink"
            continue
        fi
        if [[ ! -e "${abs}" ]]; then
            [[ -n "${log_refusals}" ]] && log_warn "workbench_deploy_module: ${module}: deploy src not found: ${abs}"
            continue
        fi

        form="$(workbench_files_form_get "${module}" "${chosen}")"
        if [[ "${mode}" == "link_tree" && "${form}" != "copy" ]]; then
            printf '%s|.|%s|deploy|link|%s|link_tree|%s\n' "$(basename "${chosen}")" "${chosen%/}" "${ok_yield}" "${current_dir}"
            continue
        fi
        if [[ "${mode}" == "link_tree" ]]; then
            mode="copy"; effective="managed"
        fi

        if [[ -d "${abs}" ]]; then
            while IFS= read -r -d '' rel; do
                if ! _wb_files_key_ok "${rel}" || ! _wb_path_is_safe_relative "${rel}"; then
                    [[ -n "${log_refusals}" ]] && log_error "workbench_deploy_module: ${module}: refusing a file under '${src}' — its name contains '|', a newline, or '..'"
                    continue
                fi
                if [[ "${mode}" == "link" && "$(workbench_files_form_get "${module}" "${chosen%/}/${rel}")" != "copy" ]]; then
                    printf '%s|%s|%s|deploy|link|%s|link|%s\n' "$(basename "${rel}")" "${src%/}/${rel}" "${chosen%/}/${rel}" "${ok_yield}" "${abs}/${rel}"
                else
                    printf '%s|%s|%s|deploy|%s|%s|copy|%s\n' "$(basename "${rel}")" "${src%/}/${rel}" "${chosen%/}/${rel}" \
                        "$([[ "${mode}" == "link" ]] && echo managed || echo "${effective}")" "${ok_yield}" "${abs}/${rel}"
                fi
            done < <(_wb_files_list_tree "${abs}")
        elif [[ "${mode}" == "link" && "${form}" != "copy" ]]; then
            printf '%s|%s|%s|deploy|link|%s|link|%s\n' "$(basename "${chosen}")" "${src}" "${chosen}" "${ok_yield}" "${abs}"
        else
            [[ "${mode}" == "link" ]] && effective="managed"
            printf '%s|%s|%s|deploy|%s|%s|copy|%s\n' "$(basename "${chosen}")" "${src}" "${chosen}" "${effective}" "${ok_yield}" "${abs}"
        fi
    done < <(workbench_manifest_deploy_entries "${manifest}")

    src="$(workbench_manifest_scalar overrides_src "${manifest}")"
    if [[ -n "${src}" && -f "${current_dir}/${src}" ]]; then
        dest="${XDG_CONFIG_HOME:-${HOME}/.config}/workbench/local/overrides/${module}.sh"
        _wb_files_key_ok "${dest}" && printf '%s|%s|%s|overrides|seed||copy|%s\n' "$(basename "${dest}")" "${src}" "${dest}" "${current_dir}/${src}"
    fi

    # D82: layers, after the deploy targets — kind and mode 'layer', dest
    # '<target>#<position>', the layer id in the basename field.
    if command -v workbench_layers_target_lines &>/dev/null; then
        workbench_layers_target_lines "${module}" "${manifest}" "${current_dir}" "${log_refusals}"
    fi
}

# workbench_files_row_as_target <module> <dest>
# A target line for a linked ledger row whose manifest entry is gone (so a
# held entry can still be resolved, and its snapshot unpinned). Nothing for
# copy rows or unknown dests.
workbench_files_row_as_target() {
    local module="$1" dest="$2" row kind sha rel current_dir
    row="$(workbench_files_ledger_get "${module}" "${dest}")"
    [[ -z "${row}" ]] && return 0
    kind="$(printf '%s\n' "${row}" | awk -F'|' '{ print $2 }')"
    sha="$(printf '%s\n' "${row}" | awk -F'|' '{ print $4 }')"
    [[ "${sha}" == link:* ]] || return 0
    rel="${sha#link:}"
    current_dir="$(workbench_module_current_dir "${module}")"
    if [[ "${rel}" == "." ]]; then
        printf '%s|.|%s|%s|link||link_tree|%s\n' "$(basename "${dest}")" "${dest}" "${kind}" "${current_dir}"
    else
        printf '%s|%s|%s|%s|link||link|%s\n' "$(basename "${dest}")" "${rel}" "${dest}" "${kind}" "${current_dir}/${rel}"
    fi
}

# ── Copy-mode: condition ────────────────────────────────────────────────────

# True when <real_dest> is byte-identical to <src_rel> in any snapshot still
# on disk for this module — an unedited copy of a default we once shipped.
workbench_files_is_known_default() {
    local module="$1" src_rel="$2" real_dest="$3" snap
    for snap in "$(workbench_module_dir "${module}")"/snapshots/*/; do
        [[ -f "${snap}${src_rel}" ]] || continue
        cmp -s "${snap}${src_rel}" "${real_dest}" && return 0
    done
    return 1
}

# workbench_files_classify <module> <dest> <src_rel> [<yield_csv>]
# Prints exactly one of:
#   new        nothing at dest, no record
#   yielded    nothing at dest, no record, a yield_to path exists
#   adoptable  dest is an unedited known default with no record, or core's
#              own link (a legacy link-mode deploy, or this entry was linked
#              before the module switched it to copy)
#   foreign    dest exists and isn't core's
#   clean      recorded, dest content == what core wrote
#   edited     recorded, dest content changed (or replaced by a symlink or
#              directory the user made)
#   gone       recorded, dest no longer exists
#   held | user | removed | restored   ledger state, passed through
workbench_files_classify() {
    local module="$1" dest="$2" src_rel="$3" yield_csv="${4:-}"
    local real row state sha
    real="$(_wb_expand_dest "${dest}")"
    row="$(workbench_files_ledger_get "${module}" "${dest}")"
    state="$(printf '%s\n' "${row}" | awk -F'|' '{ print $3 }')"
    sha="$(printf '%s\n' "${row}" | awk -F'|' '{ print $4 }')"

    case "${state}" in
        held|user|removed|restored) printf '%s\n' "${state}"; return 0 ;;
    esac

    if [[ -n "${row}" && "${sha}" != link:* ]]; then
        if [[ ! -e "${real}" && ! -L "${real}" ]]; then
            printf 'gone\n'
        elif [[ -L "${real}" || ! -f "${real}" ]]; then
            printf 'edited\n'
        elif [[ "$(_wb_sha256 "${real}")" == "${sha}" ]]; then
            printf 'clean\n'
        else
            printf 'edited\n'
        fi
        return 0
    fi

    if [[ ! -e "${real}" && ! -L "${real}" ]]; then
        if [[ -n "${row}" ]]; then
            printf 'gone\n'
        elif _wb_files_yield_hit "${yield_csv}"; then
            printf 'yielded\n'
        else
            printf 'new\n'
        fi
        return 0
    fi
    if _wb_files_is_our_link "${module}" "${real}"; then
        printf 'adoptable\n'
        return 0
    fi
    if [[ -z "${row}" && -f "${real}" && ! -L "${real}" ]] && workbench_files_is_known_default "${module}" "${src_rel}" "${real}"; then
        printf 'adoptable\n'
        return 0
    fi
    printf 'foreign\n'
}

# ── Copy-mode: the decision matrix ──────────────────────────────────────────
#
#   condition  | skip | seed        | managed          | follow (host)  | follow (file)
#   -----------+------+-------------+------------------+----------------+----------------
#   new        |  -   | write       | write            | write          | write
#   yielded    |  -   | leave       | leave            | leave          | write-warn
#   adoptable  |  -   | adopt*      | write            | write          | write
#   foreign    |  -   | leave       | leave            | write-original | write-original
#   clean      |  -   | -           | write if moved   | write if moved | write if moved
#   edited     |  -   | -           | notify if moved  | write-backup   | write-backup
#   gone       |  -   | mark-removed| mark-removed     | mark-removed   | mark-removed
#   held / user / removed / restored: never written — only explicit commands change that
#
#   * adopt = record the existing file as ours without changing it. A symlink
#     (core's own) is always replaced by a real copy instead (action: write).
#   "moved" = the module's current src differs from what core last wrote, and
#   (for edited) from the version the user last chose to keep theirs over.
#   follow (file) = a files.policy row or lifecycle: generated. The host-wide
#   default never creates a second config beside one the user has elsewhere
#   (tmux would load both); 'wb files use' is how to switch.

# _wb_files_decide <policy> <condition> <moved> <is_symlink> [<explicit>]
# Pure: prints the action name and touches nothing.
_wb_files_decide() {
    local policy="$1" condition="$2" moved="$3" is_symlink="$4" explicit="${5:-true}"
    if [[ "${policy}" == "skip" ]]; then
        printf 'none\n'; return 0
    fi
    case "${condition}" in
        held|user|removed|restored) printf 'none\n' ;;
        new)        printf 'write\n' ;;
        gone)       printf 'mark-removed\n' ;;
        yielded)
            if [[ "${policy}" == "follow" && "${explicit}" == "true" ]]; then printf 'write-warn\n'; else printf 'leave\n'; fi ;;
        foreign)
            if [[ "${policy}" == "follow" ]]; then printf 'write-original\n'; else printf 'leave\n'; fi ;;
        adoptable)
            if [[ "${is_symlink}" == "true" || "${policy}" != "seed" ]]; then printf 'write\n'; else printf 'adopt\n'; fi ;;
        clean)
            if [[ "${moved}" == "true" && "${policy}" != "seed" ]]; then printf 'write\n'; else printf 'none\n'; fi ;;
        edited)
            case "${policy}" in
                follow)  printf 'write-backup\n' ;;
                managed) if [[ "${moved}" == "true" ]]; then printf 'notify\n'; else printf 'none\n'; fi ;;
                *)       printf 'none\n' ;;
            esac ;;
        *)          printf 'unknown\n' ;;
    esac
}

# workbench_files_plan <module> <dest> <abs_src> <src_rel> <lifecycle> [<yield_csv>]
# Prints <policy>|<condition>|<action> for one copy-mode target. Read-only.
workbench_files_plan() {
    local module="$1" dest="$2" abs_src="$3" src_rel="$4" lifecycle="$5" yield_csv="${6:-}"
    local policy condition moved=false is_symlink=false explicit=false row_sha ack src_sha
    policy="$(workbench_files_effective_policy "${module}" "${dest}" "${lifecycle}")"
    _wb_files_policy_explicit "${module}" "${dest}" "${lifecycle}" && explicit=true
    condition="$(workbench_files_classify "${module}" "${dest}" "${src_rel}" "${yield_csv}")"
    row_sha="$(workbench_files_ledger_field "${module}" "${dest}" 4)"
    ack="$(workbench_files_ledger_field "${module}" "${dest}" 6)"
    if [[ -f "${abs_src}" && -n "${row_sha}" && "${row_sha}" != "-" && "${row_sha}" != link:* ]]; then
        src_sha="$(_wb_sha256 "${abs_src}")"
        if [[ "${src_sha}" != "${row_sha}" ]]; then
            moved=true
            [[ "${condition}" == "edited" && "${src_sha}" == "${ack}" ]] && moved=false
        fi
    fi
    [[ -L "$(_wb_expand_dest "${dest}")" ]] && is_symlink=true
    printf '%s|%s|%s\n' "${policy}" "${condition}" "$(_wb_files_decide "${policy}" "${condition}" "${moved}" "${is_symlink}" "${explicit}")"
}

# Writes <abs_src> to <dest> and records it active. What's at dest first:
#   core's own link        → removed
#   any other symlink      → moved aside whole (never followed)
#   a regular file         → backed up unless byte-identical (D53)
#   a directory            → refused (explicit commands move it aside first)
# backup_reason: none | routine | original. 'original' records the backup
# as the entry's pre-workbench original if none is held yet.
_wb_files_write_recorded() {
    local module="$1" dest="$2" abs_src="$3" kind="$4" backup_reason="$5"
    local real original sha backup
    real="$(_wb_expand_dest "${dest}")"
    original="$(workbench_files_ledger_field "${module}" "${dest}" 5)"
    [[ -z "${original}" ]] && original="-"

    if [[ -L "${real}" ]]; then
        if _wb_files_is_our_link "${module}" "${real}"; then
            rm -f "${real}"
        else
            backup="$(_wb_files_move_aside "${module}" "${real}")" || return 1
            [[ "${backup_reason}" == "original" && "${original}" == "-" ]] && original="${backup}"
        fi
    elif [[ -f "${real}" ]] && ! cmp -s "${abs_src}" "${real}"; then
        workbench_backup_existing_file "${real}" "${module}" || return 1
        if [[ "${backup_reason}" == "original" && "${original}" == "-" ]]; then
            original="${WB_LAST_BACKUP_PATH:--}"
        fi
    fi

    _wb_files_write "${abs_src}" "${real}" || { log_error "  failed to write ${dest}"; return 1; }
    sha="$(_wb_sha256 "${abs_src}")"
    workbench_files_ledger_set "${module}" "${dest}" "${kind}" active "${sha}" "${original}"
    log_info "  deployed: ${dest}"
}

# workbench_files_apply <module> <dest> <abs_src> <src_rel> <kind> <lifecycle> [<yield_csv>]
# The sync engine's entry point for one copy-mode target.
workbench_files_apply() {
    local module="$1" dest="$2" abs_src="$3" src_rel="$4" kind="$5" lifecycle="$6" yield_csv="${7:-}"
    local plan action original
    if ! _wb_files_key_ok "${dest}"; then
        log_error "workbench_files_apply: refusing ${dest} — '|' and newlines are not allowed in a dest"
        return 1
    fi
    plan="$(workbench_files_plan "${module}" "${dest}" "${abs_src}" "${src_rel}" "${lifecycle}" "${yield_csv}")"
    action="${plan##*|}"

    case "${action}" in
        none|notify)
            # notify: surfaced through files.pending, not the sync log
            return 0
            ;;
        write)
            _wb_files_write_recorded "${module}" "${dest}" "${abs_src}" "${kind}" none
            ;;
        write-backup)
            _wb_files_write_recorded "${module}" "${dest}" "${abs_src}" "${kind}" routine
            ;;
        write-original)
            _wb_files_write_recorded "${module}" "${dest}" "${abs_src}" "${kind}" original
            ;;
        write-warn)
            _wb_files_yield_hit "${yield_csv}"
            log_warn "  ${dest}: writing workbench's version although ${WB_FILES_YIELD_PATH} exists (policy: follow) — 'wb files use' moves yours aside"
            _wb_files_write_recorded "${module}" "${dest}" "${abs_src}" "${kind}" none
            ;;
        adopt)
            workbench_files_ledger_set "${module}" "${dest}" "${kind}" active "$(_wb_sha256 "$(_wb_expand_dest "${dest}")")" -
            log_info "  ${dest}: adopted existing workbench default as-is"
            ;;
        leave)
            if _wb_files_yield_hit "${yield_csv}"; then
                log_info "  ${dest}: found your own config at ${WB_FILES_YIELD_PATH} — leaving it alone"
            else
                log_info "  ${dest}: already exists and isn't from workbench — leaving it alone"
            fi
            ;;
        mark-removed)
            original="$(workbench_files_ledger_field "${module}" "${dest}" 5)"
            workbench_files_ledger_set "${module}" "${dest}" "${kind}" removed - "${original:--}"
            log_info "  ${dest}: you removed it — workbench won't recreate it ('wb files use ${module} $(basename "${dest}")' brings it back)"
            ;;
        *)
            log_error "workbench_files_apply: ${dest}: no action for plan '${plan}'"
            return 1
            ;;
    esac
}

# ── Linked entries (mode: link, mode: link_tree) ────────────────────────────
#
# A linked entry is a symlink from dest into <module>/current, so it follows
# every update. It is core's only while it points into that module's state.
#
#   at dest                            | skip    | managed    | follow (file)  | follow (host)
#   -----------------------------------+---------+------------+----------------+---------------
#   nothing, no record                 |  -      | link       | link           | link
#   nothing, a yield_to path exists    |  -      | leave      | link, warn     | leave
#   core's link                        | freeze* | relink     | relink         | relink
#   core's unedited copy (was copy)    |  -      | link       | link           | link
#   a file, or a symlink elsewhere     |  -      | leave      | move, link     | move, link
#   a real directory                   |  -      | leave†     | move, link     | leave†
#   recorded, now gone                 |  -      | removed    | removed        | removed
#   held / user / removed / restored / converted: never touched by sync
#
#   * skip on a link core already made: it's replaced by a plain copy the
#     user owns (state user), so it really does stop following the module.
#   † link_tree only: a pre-D81 copy of this module's tree (most files
#     byte-identical to a retained snapshot) is adopted as managed copies.
#
# Changes made THROUGH the link (into the snapshot) are handled at update
# time by workbench_files_before_swap.

# Replaces core's link at <real> with a plain copy of what it points at, owned
# by the user from now on. Keeps any changes made through the link.
_wb_files_freeze_link() {
    local module="$1" dest="$2" kind="$3" real target
    real="$(_wb_expand_dest "${dest%/}")"
    _wb_files_is_our_link "${module}" "${real}" || return 0
    target="$(readlink "${real}")"
    [[ -L "${target}" ]] && target="$(readlink "${target}")"    # <module>/current → snapshot
    rm -f "${real}"
    _wb_files_copy_tree "${target}" "${real}" || { log_error "  failed to make ${dest} your own copy"; return 1; }
    workbench_files_ledger_set "${module}" "${dest}" "${kind}" user -
    log_info "  ${dest}: now your own copy; workbench won't update it"
}

# A pre-D81 copy of a link_tree module's tree at dest (copy-once fall-through
# before this decision) — adopted as managed copies, not left orphaned.
# Looks like ours when at least half the snapshot's files are present and
# byte-identical to a retained default.
_wb_files_dir_looks_ours() {
    local module="$1" real="$2" current_dir="$3" rel total=0 same=0
    while IFS= read -r -d '' rel; do
        total=$((total + 1))
        [[ -f "${real}/${rel}" ]] && workbench_files_is_known_default "${module}" "${rel}" "${real}/${rel}" && same=$((same + 1))
    done < <(_wb_files_list_tree "${current_dir}")
    [[ "${total}" -gt 0 && $((same * 2)) -ge "${total}" ]]
}

_wb_files_adopt_dir() {
    local module="$1" dest="$2" kind="$3" current_dir snap rel child real_child other present_elsewhere
    current_dir="$(workbench_module_current_dir "${module}")"
    snap="$(readlink "${current_dir}")"
    while IFS= read -r -d '' rel; do
        _wb_files_key_ok "${rel}" || continue
        child="${dest%/}/${rel}"
        real_child="$(_wb_expand_dest "${child}")"
        if [[ -f "${real_child}" && ! -L "${real_child}" ]]; then
            if workbench_files_is_known_default "${module}" "${rel}" "${real_child}"; then
                cmp -s "${current_dir}/${rel}" "${real_child}" || _wb_files_write "${current_dir}/${rel}" "${real_child}" || return 1
            fi
            workbench_files_ledger_set "${module}" "${child}" "${kind}" active "$(_wb_sha256 "${current_dir}/${rel}")" -
        elif [[ ! -e "${real_child}" && ! -L "${real_child}" ]]; then
            # Missing: deleted by the user if an older retained snapshot had
            # it; otherwise new upstream since the copy was made.
            present_elsewhere=false
            for other in "$(workbench_module_dir "${module}")"/snapshots/*/; do
                [[ "${other%/}" == "${snap}" ]] && continue
                [[ -f "${other}${rel}" ]] && present_elsewhere=true
            done
            if [[ "${present_elsewhere}" == "true" ]]; then
                workbench_files_ledger_set "${module}" "${child}" "${kind}" removed - -
            else
                _wb_files_write "${current_dir}/${rel}" "${real_child}" || return 1
                workbench_files_ledger_set "${module}" "${child}" "${kind}" active "$(_wb_sha256 "${current_dir}/${rel}")" -
            fi
        fi
    done < <(_wb_files_list_tree "${current_dir}")
    workbench_files_ledger_set "${module}" "${dest}" "${kind}" converted "link:."
    workbench_files_form_set "${module}" "${dest}" copy
    log_info "  ${dest}: found an earlier copy of ${module} — now managed as copies; your changes stay yours"
}

# workbench_files_apply_link <module> <dest> <target> <src_rel> <kind> [<yield_csv>]
workbench_files_apply_link() {
    local module="$1" dest="$2" target="$3" src_rel="$4" kind="$5" yield_csv="${6:-}"
    local real policy explicit=false row state sha original backup current_dir
    if ! _wb_files_key_ok "${dest}"; then
        log_error "workbench_files_apply_link: refusing ${dest} — '|' and newlines are not allowed in a dest"
        return 1
    fi
    real="$(_wb_expand_dest "${dest%/}")"
    policy="$(workbench_files_effective_policy "${module}" "${dest}" link)"
    _wb_files_policy_explicit "${module}" "${dest}" link && explicit=true
    row="$(workbench_files_ledger_get "${module}" "${dest}")"
    state="$(printf '%s\n' "${row}" | awk -F'|' '{ print $3 }')"
    sha="$(printf '%s\n' "${row}" | awk -F'|' '{ print $4 }')"
    original="$(printf '%s\n' "${row}" | awk -F'|' '{ print $5 }')"

    case "${state}" in
        held|user|removed|restored|converted) return 0 ;;
    esac
    if [[ "${policy}" == "skip" ]]; then
        _wb_files_freeze_link "${module}" "${dest}" "${kind}"
        return $?
    fi

    if [[ "${state}" == "active" && ! -e "${real}" && ! -L "${real}" ]]; then
        workbench_files_ledger_set "${module}" "${dest}" "${kind}" removed "${sha}"
        log_info "  ${dest}: you removed it — workbench won't recreate it ('wb files use ${module} $(basename "${dest}")' brings it back)"
        return 0
    fi

    if [[ ! -e "${real}" && ! -L "${real}" ]]; then
        if [[ -z "${row}" ]] && _wb_files_yield_hit "${yield_csv}"; then
            if [[ "${policy}" != "follow" || "${explicit}" != "true" ]]; then
                log_info "  ${dest}: found your own config at ${WB_FILES_YIELD_PATH} — leaving it alone"
                return 0
            fi
            log_warn "  ${dest}: linking workbench's version although ${WB_FILES_YIELD_PATH} exists (policy: follow) — 'wb files use' moves yours aside"
        fi
        _wb_files_link "${real}" "${target}" || { log_error "  failed to link ${dest}"; return 1; }
        workbench_files_ledger_set "${module}" "${dest}" "${kind}" active "link:${src_rel}"
        log_info "  deployed (link): ${dest} -> ${target}"
        return 0
    fi

    if _wb_files_is_our_link "${module}" "${real}"; then
        if [[ "$(readlink "${real}")" != "${target}" ]]; then
            _wb_files_link "${real}" "${target}" || return 1
            log_info "  relinked: ${dest} -> ${target}"
        fi
        [[ "${state}" == "active" && "${sha}" == "link:${src_rel}" ]] || \
            workbench_files_ledger_set "${module}" "${dest}" "${kind}" active "link:${src_rel}"
        return 0
    fi

    # The entry was copy mode before: core's unedited copy becomes the link.
    if [[ "${state}" == "active" && "${sha}" != link:* && -f "${real}" && ! -L "${real}" ]] \
        && [[ "$(_wb_sha256 "${real}")" == "${sha}" ]]; then
        rm -f "${real}"
        _wb_files_link "${real}" "${target}" || return 1
        workbench_files_ledger_set "${module}" "${dest}" "${kind}" active "link:${src_rel}"
        log_info "  deployed (link): ${dest} -> ${target} (was an unedited copy)"
        return 0
    fi

    # A pre-D81 copy of a link_tree module's tree (not under a per-entry
    # follow, which asks for the link itself).
    if [[ -z "${row}" && "${src_rel}" == "." && -d "${real}" && ! -L "${real}" ]] \
        && [[ "${policy}" != "follow" || "${explicit}" != "true" ]]; then
        current_dir="$(workbench_module_current_dir "${module}")"
        if _wb_files_dir_looks_ours "${module}" "${real}" "${current_dir}"; then
            _wb_files_adopt_dir "${module}" "${dest}" "${kind}"
            return $?
        fi
    fi

    # The user's: a real file or directory, or a symlink they made.
    if [[ "${policy}" == "follow" ]] && { [[ "${explicit}" == "true" ]] || [[ ! -d "${real}" || -L "${real}" ]]; }; then
        _wb_files_path_safe "${module}" "${dest}" "${kind}" || return 1
        backup="$(_wb_files_move_aside "${module}" "${real}")" || return 1
        [[ -z "${original}" || "${original}" == "-" ]] && original="${backup}"
        _wb_files_link "${real}" "${target}" || return 1
        workbench_files_ledger_set "${module}" "${dest}" "${kind}" active "link:${src_rel}" "${original}"
        log_info "  deployed (link): ${dest} -> ${target}"
        return 0
    fi
    log_info "  ${dest}: already exists and isn't from workbench — leaving it alone"
}

# ── Update time: never discard changes made through a link ──────────────────

# workbench_files_before_swap <module>
# Called by the sync engine immediately before workbench_snapshot_swap
# replaces the current snapshot. The engine must not swap if this fails.
# For every linked entry that is core's link into the current snapshot:
#   skip policy          → frozen as the user's own copy first
#   no change            → nothing to do; the link follows the swap
#   changed, follow      → changes backed up (per-entry follow only); if the
#                          backup fails, held instead
#   changed, otherwise   → held: repointed at this exact snapshot, pinned
#                          against pruning, waiting for 'wb files resolve'
# Records the current snapshot's checksums first if it has none (a host
# upgrading to D81): changes made before that point can't be detected.
# Every entry is processed even after a failure; returns 1 if any failed.
workbench_files_before_swap() {
    local module="$1" module_dir snap pin rows dest kind state sha original ack rel target real drift rc=0
    module_dir="$(workbench_module_dir "${module}")"
    [[ -L "${module_dir}/current" ]] || return 0
    snap="$(readlink "${module_dir}/current")"
    [[ -d "${snap}" ]] || return 0
    pin="$(basename "${snap}")"
    if [[ ! -f "$(workbench_files_sums_path "${module}" "${snap}")" ]]; then
        workbench_files_record_sums "${module}" "${snap}" || return 1
        return 0
    fi

    rows="$(workbench_files_ledger_rows "${module}" | awk -F'|' '$3 == "active" && index($4, "link:") == 1')"
    [[ -z "${rows}" ]] && return 0
    while IFS='|' read -r dest kind state sha original ack _; do
        rel="${sha#link:}"
        real="$(_wb_expand_dest "${dest%/}")"
        if [[ "${rel}" == "." ]]; then target="${module_dir}/current"; else target="${module_dir}/current/${rel}"; fi
        [[ -L "${real}" && "$(readlink "${real}")" == "${target}" ]] || continue

        if [[ "$(workbench_files_policy_get "${module}" "${dest}")" == "skip" ]]; then
            _wb_files_freeze_link "${module}" "${dest}" "${kind}" || rc=1
            continue
        fi
        drift="$(workbench_files_snapshot_drift "${module}" "${snap}" "${rel}")"
        [[ -z "${drift}" ]] && continue

        if [[ "$(workbench_files_policy_get "${module}" "${dest}")" == "follow" ]]; then
            if _wb_files_backup_drift "${module}" "${snap}" "${drift}" "$(basename "${dest%/}")"; then
                log_info "  ${dest}: taking the update (policy: follow)"
                continue
            fi
            log_warn "  ${dest}: couldn't back up your changes — holding it instead"
        fi
        if [[ "${rel}" == "." ]]; then target="${snap}"; else target="${snap}/${rel}"; fi
        if ! _wb_files_link "${real}" "${target}"; then
            log_error "  ${dest}: failed to hold it at the current version"
            rc=1
            continue
        fi
        workbench_files_ledger_set "${module}" "${dest}" "${kind}" held "${sha}" "${original}" "${ack}" "${pin}"
        log_warn "  ${dest}: has changes made since the last update ($(printf '%s\n' "${drift}" | wc -l | tr -d ' ') file(s)) — holding it at the current version until you choose: 'wb files resolve ${module} $(basename "${dest%/}")'"
    done <<< "${rows}"
    return "${rc}"
}

# ── Pending decisions ───────────────────────────────────────────────────────

# workbench_files_pending <module>
# One line per target waiting on the user: <dest>|held or <dest>|moved
# (a copy the user edited, whose default has since changed), or
# <target>#<position>|linked (a layer whose target is a symlink the user
# manages, waiting on 'wb files resolve ... use|keep' — D82).
workbench_files_pending() {
    local module="$1" base src dest kind lifecycle yield mode source plan
    workbench_files_ledger_rows "${module}" | awk -F'|' '$3 == "held" { print $1 "|held" }'
    while IFS='|' read -r base src dest kind lifecycle yield mode source; do
        if [[ "${mode}" == "layer" ]]; then
            [[ "$(workbench_layers_state "${module}" "${base}|${src}|${dest}|${kind}|${lifecycle}|${yield}|${mode}|${source}")" == "linked" ]] \
                && printf '%s|linked\n' "${dest}"
            continue
        fi
        [[ "${mode}" == "copy" ]] || continue
        plan="$(workbench_files_plan "${module}" "${dest}" "${source}" "${src}" "${lifecycle}" "${yield}")"
        [[ "${plan##*|}" == "notify" ]] && printf '%s|moved\n' "${dest}"
    done < <(workbench_files_targets "${module}")
    return 0
}

# Rewrites files.pending (removed when empty). The loader's shell-start
# notice and 'wb status' read only this file's existence and line count.
workbench_files_write_pending() {
    local module="$1" file tmp
    file="$(workbench_files_pending_path "${module}")"
    tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || return 0
    workbench_files_pending "${module}" > "${tmp}"
    if [[ -s "${tmp}" ]]; then mv "${tmp}" "${file}"; else rm -f "${tmp}" "${file}"; fi
}

# ── User-invoked operations ─────────────────────────────────────────────────
#
# Each takes one target line (workbench_files_targets, or
# workbench_files_row_as_target for an entry no longer in the manifest).
# Confirmation and previews are the caller's job (bin/wb). Each runs D75's
# physical path check on everything it writes, moves or removes.

# Sets WB_T_* from one target line. WB_T_BASE is for bin/wb's messages.
_wb_files_target_fields() {
    # shellcheck disable=SC2034
    IFS='|' read -r WB_T_BASE WB_T_SRC WB_T_DEST WB_T_KIND WB_T_LIFECYCLE WB_T_YIELD WB_T_MODE WB_T_SOURCE <<< "$1"
}

# The snapshot a linked target's content currently comes from: its pin when
# held, otherwise wherever current points.
_wb_files_link_snapshot() {
    local module="$1" pin="$2" module_dir
    module_dir="$(workbench_module_dir "${module}")"
    if [[ -n "${pin}" && "${pin}" != "-" ]]; then
        printf '%s/snapshots/%s\n' "${module_dir}" "${pin}"
    else
        readlink "${module_dir}/current"
    fi
}

# workbench_files_use <module> <target-line> [follow]
# "Use the module's version": whatever is at dest is moved or backed up (and
# kept as the original if it predates workbench), every yield_to path that
# exists is moved aside so the tool only finds this one, any hold or
# managed-copy form is undone, and the per-entry policy is cleared — or set
# to follow.
workbench_files_use() {
    local module="$1" line="$2" follow="${3:-}"
    local real row state pin snap drift original backup
    _wb_files_target_fields "${line}"
    if [[ "${WB_T_MODE}" == "layer" ]]; then
        workbench_layers_use "${module}" "${line}"
        return $?
    fi
    _wb_files_path_safe "${module}" "${WB_T_DEST}" "${WB_T_KIND}" || return 1
    real="$(_wb_expand_dest "${WB_T_DEST%/}")"
    row="$(workbench_files_ledger_get "${module}" "${WB_T_DEST}")"
    state="$(printf '%s\n' "${row}" | awk -F'|' '{ print $3 }')"
    pin="$(printf '%s\n' "${row}" | awk -F'|' '{ print $7 }')"
    original="$(printf '%s\n' "${row}" | awk -F'|' '{ print $5 }')"
    [[ -z "${original}" ]] && original="-"

    if [[ "${state}" == "held" ]]; then
        snap="$(_wb_files_link_snapshot "${module}" "${pin}")"
        drift="$(workbench_files_snapshot_drift "${module}" "${snap}" "${WB_T_SRC}")"
        _wb_files_backup_drift "${module}" "${snap}" "${drift}" "${WB_T_BASE}" || return 1
    fi
    _wb_files_displace_yields "${module}" "${WB_T_DEST}" "${WB_T_YIELD}" || return 1

    if [[ "${state}" == "converted" ]]; then
        _wb_files_unconvert "${module}" "${WB_T_DEST}" || return 1
        state=""
    fi

    # Anything at dest that isn't core's: moved aside whole. Kept as the
    # original only if it predates workbench (no record, or the user's).
    if [[ -e "${real}" || -L "${real}" ]] && ! _wb_files_is_our_link "${module}" "${real}"; then
        if [[ "${WB_T_MODE}" != "copy" || -d "${real}" || -L "${real}" ]]; then
            backup="$(_wb_files_move_aside "${module}" "${real}")" || return 1
            [[ "${original}" == "-" && "${state}" != "active" && "${state}" != "removed" ]] && original="${backup}"
            workbench_files_ledger_set "${module}" "${WB_T_DEST}" "${WB_T_KIND}" "${state:-user}" - "${original}"
        fi
    fi

    if [[ "${WB_T_MODE}" == "copy" ]]; then
        if [[ -f "${real}" && ( -z "${state}" || "${state}" == "user" ) ]]; then
            _wb_files_write_recorded "${module}" "${WB_T_DEST}" "${WB_T_SOURCE}" "${WB_T_KIND}" original || return 1
        else
            _wb_files_write_recorded "${module}" "${WB_T_DEST}" "${WB_T_SOURCE}" "${WB_T_KIND}" routine || return 1
        fi
    else
        _wb_files_link "${real}" "${WB_T_SOURCE}" || return 1
        workbench_files_ledger_set "${module}" "${WB_T_DEST}" "${WB_T_KIND}" active "link:${WB_T_SRC}" "${original}"
        log_info "  deployed (link): ${WB_T_DEST} -> ${WB_T_SOURCE}"
    fi

    if [[ "${follow}" == "follow" ]]; then
        workbench_files_policy_set "${module}" "${WB_T_DEST}" follow
    else
        workbench_files_policy_set "${module}" "${WB_T_DEST}" default
    fi
    workbench_files_write_pending "${module}"
}

# A converted linked directory back to nothing: its managed copies are moved
# aside as one directory, their ledger rows and the form are dropped.
_wb_files_unconvert() {
    local module="$1" dest="$2" real child
    real="$(_wb_expand_dest "${dest%/}")"
    if [[ -e "${real}" || -L "${real}" ]]; then
        _wb_files_move_aside "${module}" "${real}" >/dev/null || return 1
    fi
    while IFS= read -r child; do
        workbench_files_ledger_delete "${module}" "${child}"
    done < <(workbench_files_ledger_rows "${module}" | awk -F'|' -v p="${dest%/}/" 'index($1, p) == 1 { print $1 }')
    workbench_files_form_set "${module}" "${dest}" ""
}

# workbench_files_resolve <module> <target-line> keep|manage|use [follow]
#
# For a linked entry — held, or still core's link (choosing ahead):
#   keep    your version becomes a real copy you own; no further updates
#   manage  becomes managed copies: what you changed stays yours, everything
#           else keeps following the module (the lazy-lock.json case)
#   use     (held only) your changes are backed up; the link follows again
# For a copy you edited whose default has moved:
#   keep    yours from now on; no further notices (policy seed)
#   manage  keep yours, no notice until the default changes again
#   use     take the default (yours is backed up)
# Returns 3 when the target has nothing to resolve; 4 when dest is no longer
# core's link (the user replaced it — it's theirs, nothing to decide).
workbench_files_resolve() {
    local module="$1" line="$2" choice="$3" follow="${4:-}"
    local row state pin snap real src_sha src_path
    case "${choice}" in
        keep|manage|use) ;;
        *) log_error "workbench_files_resolve: unknown choice '${choice}'"; return 2 ;;
    esac
    _wb_files_target_fields "${line}"
    if [[ "${WB_T_MODE}" == "layer" ]]; then
        # A layer has one thing to decide: a symlinked target (D82).
        [[ "$(workbench_layers_state "${module}" "${line}")" == "linked" ]] || return 3
        [[ "${choice}" == "manage" ]] && { log_error "workbench_files_resolve: 'manage' isn't a choice for a layer — keep or use"; return 2; }
        workbench_layers_resolve "${module}" "${line}" "${choice}"
        return $?
    fi
    _wb_files_path_safe "${module}" "${WB_T_DEST}" "${WB_T_KIND}" || return 1
    row="$(workbench_files_ledger_get "${module}" "${WB_T_DEST}")"
    state="$(printf '%s\n' "${row}" | awk -F'|' '{ print $3 }')"
    pin="$(printf '%s\n' "${row}" | awk -F'|' '{ print $7 }')"
    real="$(_wb_expand_dest "${WB_T_DEST%/}")"

    if [[ "${state}" == "held" || ( "${state}" == "active" && "${WB_T_MODE}" != "copy" ) ]]; then
        if ! _wb_files_is_our_link "${module}" "${real}"; then
            # The user replaced or removed core's link. A held snapshot's
            # changes are backed up, and the entry is settled their way.
            if [[ "${state}" == "held" ]]; then
                snap="$(_wb_files_link_snapshot "${module}" "${pin}")"
                _wb_files_backup_drift "${module}" "${snap}" \
                    "$(workbench_files_snapshot_drift "${module}" "${snap}" "${WB_T_SRC}")" "${WB_T_BASE}" || return 1
                if [[ -e "${real}" || -L "${real}" ]]; then
                    workbench_files_ledger_set "${module}" "${WB_T_DEST}" "${WB_T_KIND}" user -
                else
                    workbench_files_ledger_set "${module}" "${WB_T_DEST}" "${WB_T_KIND}" removed -
                fi
                workbench_files_write_pending "${module}"
            fi
            if [[ -e "${real}" || -L "${real}" ]]; then
                log_warn "  ${WB_T_DEST}: no longer workbench's link — it's yours; nothing to resolve"
                return 4
            fi
            return 3
        fi
        [[ "${choice}" == "use" && "${state}" != "held" ]] && return 3
        [[ "${choice}" == "use" ]] && { workbench_files_use "${module}" "${line}" "${follow}"; return $?; }
        snap="$(_wb_files_link_snapshot "${module}" "${pin}")"
        workbench_files_record_sums "${module}" "${snap}" || return 1
        if [[ "${WB_T_SRC}" == "." ]]; then src_path="${snap}"; else src_path="${snap}/${WB_T_SRC}"; fi
        case "${choice}" in
            keep)
                rm -f "${real}"
                _wb_files_copy_tree "${src_path}" "${real}" || return 1
                workbench_files_ledger_set "${module}" "${WB_T_DEST}" "${WB_T_KIND}" user -
                log_info "  ${WB_T_DEST}: now your own copy; workbench won't update it"
                ;;
            manage)
                _wb_files_convert "${module}" "${WB_T_DEST}" "${WB_T_SRC}" "${snap}" "${WB_T_KIND}" || return 1
                ;;
        esac
        workbench_files_write_pending "${module}"
        return 0
    fi

    if [[ "${WB_T_MODE}" == "copy" ]] && \
        [[ "$(workbench_files_plan "${module}" "${WB_T_DEST}" "${WB_T_SOURCE}" "${WB_T_SRC}" "${WB_T_LIFECYCLE}" "${WB_T_YIELD}")" == *"|notify" ]]; then
        case "${choice}" in
            keep)
                workbench_files_policy_set "${module}" "${WB_T_DEST}" seed
                log_info "  ${WB_T_DEST}: yours from now on; no further notices"
                ;;
            manage)
                src_sha="$(_wb_sha256 "${WB_T_SOURCE}")"
                workbench_files_ledger_set "${module}" "${WB_T_DEST}" "${WB_T_KIND}" active \
                    "$(workbench_files_ledger_field "${module}" "${WB_T_DEST}" 4)" "" "${src_sha}"
                log_info "  ${WB_T_DEST}: keeping yours; you'll hear again if the default changes"
                ;;
            use)
                workbench_files_use "${module}" "${line}" "${follow}"
                return $?
                ;;
        esac
        workbench_files_write_pending "${module}"
        return 0
    fi
    return 3
}

# Core's link (held or not) → managed copies, file by file, against the
# snapshot's recorded checksums:
#   unchanged by you    → the module's current version, tracked from now on
#   changed by you      → yours, recorded as an edit of what was shipped
#   added by you        → copied, not tracked (not a module file)
#   deleted by you      → recorded removed, not recreated
_wb_files_convert() {
    local module="$1" dest="$2" src_rel="$3" snap="$4" kind="$5"
    local real current_dir prefix base rel snap_rel sums p
    real="$(_wb_expand_dest "${dest%/}")"
    current_dir="$(workbench_module_current_dir "${module}")"
    if [[ "${src_rel}" == "." ]]; then prefix=""; base="${snap}"; else prefix="${src_rel}/"; base="${snap}/${src_rel}"; fi

    rm -f "${real}"
    if [[ -d "${base}" ]]; then
        mkdir -p "${real}" || return 1
        while IFS= read -r -d '' rel; do
            _wb_files_key_ok "${rel}" || continue
            snap_rel="${prefix}${rel}"
            _wb_files_convert_one "${module}" "${dest%/}/${rel}" "${base}/${rel}" "${snap_rel}" "${snap}" "${current_dir}" "${kind}" || return 1
        done < <(_wb_files_list_tree "${base}")
        sums="$(workbench_files_sums_path "${module}" "${snap}")"
        while IFS= read -r p; do
            [[ "${src_rel}" == "." || "${p}" == "${prefix}"* ]] || continue
            [[ -e "${snap}/${p}" ]] && continue
            workbench_files_ledger_set "${module}" "${dest%/}/${p#"${prefix}"}" "${kind}" removed - -
        done < <(awk '{ print substr($0, 67) }' "${sums}")
        workbench_files_ledger_set "${module}" "${dest}" "${kind}" converted "link:${src_rel}"
    else
        _wb_files_convert_one "${module}" "${dest}" "${base}" "${src_rel}" "${snap}" "${current_dir}" "${kind}" || return 1
    fi
    workbench_files_form_set "${module}" "${dest}" copy
    log_info "  ${dest}: now managed as copies — your changes stay yours, the rest follows ${module}"
}

_wb_files_convert_one() {
    local module="$1" child="$2" mine="$3" snap_rel="$4" snap="$5" current_dir="$6" kind="$7"
    local recorded upstream real_child
    recorded="$(_wb_files_recorded_sum "${module}" "${snap}" "${snap_rel}")"
    upstream="${current_dir}/${snap_rel}"
    real_child="$(_wb_expand_dest "${child}")"
    if [[ -z "${recorded}" ]]; then
        _wb_files_write "${mine}" "${real_child}"
        return $?
    fi
    if [[ "$(_wb_sha256 "${mine}")" == "${recorded}" && -f "${upstream}" ]]; then
        _wb_files_write "${upstream}" "${real_child}" || return 1
        workbench_files_ledger_set "${module}" "${child}" "${kind}" active "$(_wb_sha256 "${upstream}")" -
    else
        _wb_files_write "${mine}" "${real_child}" || return 1
        workbench_files_ledger_set "${module}" "${child}" "${kind}" active "${recorded}" -
    fi
}

# workbench_files_restore <module> <dest>
# Put things back the way they were before workbench touched <dest>:
#   - a held entry's changes are backed up first, never dropped
#   - a converted directory's managed copies are restored one by one
#   - core's link, or core's copy (edited or not, backed up) → removed
#   - anything else at dest (the user replaced core's file/link) → left alone
#   - the original, if held, is copied back when dest is free
#   - anything 'wb files use' moved aside for this entry is put back
# The entry ends 'restored' with policy 'skip'. Returns 3 when there is
# nothing of workbench's to restore, 4 when dest is now a symlink the user
# made (left in place).
workbench_files_restore() {
    local module="$1" dest="$2"
    local real row kind state sha original pin snap drift child rc=0
    real="$(_wb_expand_dest "${dest%/}")"
    row="$(workbench_files_ledger_get "${module}" "${dest}")"
    [[ -z "${row}" ]] && return 3
    IFS='|' read -r _ kind state sha original _ pin <<< "${row}"
    if [[ "${kind}" == "layer" ]]; then
        workbench_layers_restore "${module}" "${dest}"
        return $?
    fi
    [[ "${state}" == "user" || "${state}" == "restored" ]] && return 3
    _wb_files_path_safe "${module}" "${dest}" "${kind}" || return 1

    if [[ "${state}" == "held" ]]; then
        snap="$(_wb_files_link_snapshot "${module}" "${pin}")"
        drift="$(workbench_files_snapshot_drift "${module}" "${snap}" "${sha#link:}")"
        _wb_files_backup_drift "${module}" "${snap}" "${drift}" "$(basename "${dest%/}")" || return 1
    fi

    if [[ "${state}" == "converted" ]]; then
        while IFS= read -r child; do
            workbench_files_restore "${module}" "${child}" || [[ $? -ge 3 ]] || rc=1
        done < <(workbench_files_ledger_rows "${module}" | awk -F'|' -v p="${dest%/}/" 'index($1, p) == 1 { print $1 }')
        [[ -d "${real}" ]] && find "${real}" -depth -type d -empty -exec rmdir {} \; 2>/dev/null
        workbench_files_form_set "${module}" "${dest}" ""
        [[ -e "${real}" ]] && log_warn "  ${dest}: left in place — it still holds files you added"
    elif [[ "${sha}" == link:* ]]; then
        if _wb_files_is_our_link "${module}" "${real}"; then
            rm -f "${real}"
            log_info "  removed ${dest} (workbench's link)"
        elif [[ -L "${real}" ]]; then
            log_warn "  ${dest} is now a symlink you created — leaving it; remove it yourself, then re-run restore"
            return 4
        elif [[ -e "${real}" ]]; then
            log_warn "  ${dest}: you replaced workbench's link — leaving yours in place"
        fi
    else
        if [[ -L "${real}" ]]; then
            log_warn "  ${dest} is now a symlink you created — leaving it; remove it yourself, then re-run restore"
            return 4
        elif [[ -f "${real}" ]]; then
            workbench_backup_existing_file "${real}" "${module}" || return 1
            rm -f "${real}"
            log_info "  removed ${dest} (workbench created it; a copy is in the backups folder)"
        elif [[ -e "${real}" ]]; then
            log_warn "  ${dest}: you replaced workbench's file — leaving yours in place"
        fi
    fi

    if [[ -n "${original}" && "${original}" != "-" && ( -e "${original}" || -L "${original}" ) ]]; then
        if [[ -e "${real}" || -L "${real}" ]]; then
            log_warn "  ${dest}: not putting back ${original} — something is in the way"
            rc=1
        else
            mkdir -p "$(dirname "${real}")"
            cp -a "${original}" "${real}" || { log_error "  failed to restore ${dest} from ${original}"; return 1; }
            log_info "  restored ${dest} from ${original}"
        fi
    fi
    _wb_files_undisplace "${module}" "${dest}" || rc=1

    workbench_files_ledger_set "${module}" "${dest}" "${kind}" restored - "${original}"
    workbench_files_policy_set "${module}" "${dest}" skip
    workbench_files_write_pending "${module}"
    return "${rc}"
}
