#!/usr/bin/env bash
# lib/modules/revert.sh — `wb revert` (docs/decisions-log.md D108).
#
# Goes back to a version already on disk under <module>/snapshots/, with no
# network, and pins the module there so no update moves it forward again.
# Everything after the choice of version is the ordinary sync path:
# workbench_sync_module takes the on-disk version in place of resolving a
# ref, so the version, path-safety and Core API gates, the linked-file
# guard, deploy and hooks all behave exactly as they do for 'wb track'.
# Returning to production is 'wb track <name> --latest', not a separate verb.

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/modules/revert.sh" "0.1.0" || true

# _wb_revert_snapshots <module>
# Snapshot directory names, most recently fetched first — the order
# workbench_snapshot_prune keeps them in. Only real directories named
# <ref-slug>-<shortsha>: a dev checkout's 'local-checkout' is a symlink and
# isn't a version to go back to.
_wb_revert_snapshots() {
    local dir path base
    dir="$(workbench_module_dir "$1")/snapshots"
    [[ -d "${dir}" ]] || return 0
    while IFS= read -r path; do
        [[ -z "${path}" ]] && continue
        base="$(basename "${path}")"
        [[ "${base}" == *-* ]] && printf '%s\n' "${base}"
    done < <(find "${dir}" -mindepth 1 -maxdepth 1 -type d -exec ls -1dt {} + 2>/dev/null)
}

# _wb_revert_current <module>
# The snapshot directory name 'current' points at, or nothing.
_wb_revert_current() {
    local link
    link="$(workbench_module_dir "$1")/current"
    [[ -L "${link}" ]] && basename "$(readlink "${link}")"
    return 0
}

# _wb_revert_facts <module> <snapshot-name>
# Prints "<label>|<sha>" for a snapshot. A snapshot's directory name holds
# only a slug and a short sha, so the exact ref label and full sha come from
# the snapshot's 'adopt' row in adoption.log (D77). With no row — a version
# bootstrap.sh fetched, or a removed log — a tag-shaped name is still usable:
# its short sha is corrected by the next sync of that tag. A commit-tracked
# snapshot is named after the commit as it was given, which starts with its
# short sha; that commit is the most exact sha on hand, so it's both label and
# sha and pins as a commit. A branch snapshot with no row can't be pinned
# safely, so this prints nothing.
_wb_revert_facts() {
    local module="$1" snapshot="$2" stem="${2%-*}" short="${2##*-}" log row
    log="${XDG_DATA_HOME:-${HOME}/.local/share}/workbench/adoption.log"
    if [[ -f "${log}" ]]; then
        row="$(awk -F'\t' -v m="${module}" -v s="${short}" '
            $2 == "adopt" && $3 == m && index($5, s) == 1 { found = $6 "|" $5 }
            END { if (found != "") print found }' "${log}")"
    fi
    if [[ -n "${row:-}" ]]; then
        printf '%s\n' "${row}"
        return 0
    fi
    case "${stem}" in
        branch-*) return 0 ;;
    esac
    if [[ "${stem}" == "${short}"* && -z "$(printf '%s' "${stem}" | tr -d '0-9a-f')" ]]; then
        printf '%s|%s\n' "${stem}" "${stem}"
        return 0
    fi
    printf '%s|%s\n' "${stem}" "${short}"
}

# _wb_revert_mode_for <label> <sha>
# The TRACK_MODE that holds a module at this version. A branch moves, and a
# label that is the commit itself was commit-tracked; both pin to the commit.
# Anything else is a tag.
_wb_revert_mode_for() {
    local label="$1" sha="$2"
    case "${label}" in
        branch:*) printf 'commit:%s\n' "${sha}"; return 0 ;;
    esac
    if [[ "${sha}" == "${label}"* ]]; then
        printf 'commit:%s\n' "${label}"
        return 0
    fi
    printf 'tag:%s\n' "${label}"
}

# _wb_revert_display <module> <snapshot-name>
# "<label> <shortsha>" for showing to a person.
_wb_revert_display() {
    local facts label
    facts="$(_wb_revert_facts "$1" "$2")"
    label="${facts%%|*}"
    printf '%s (%s)\n' "${label:-${2%-*}}" "${2##*-}"
}

# _wb_revert_list <module>
_wb_revert_list() {
    local module="$1" current snapshot marker any="false"
    current="$(_wb_revert_current "${module}")"
    echo "${module}: versions on this machine, newest first:"
    while IFS= read -r snapshot; do
        [[ -z "${snapshot}" ]] && continue
        any="true"
        marker=" "
        [[ "${snapshot}" == "${current}" ]] && marker="*"
        printf '  %s %s\n' "${marker}" "$(_wb_revert_display "${module}" "${snapshot}")"
    done < <(_wb_revert_snapshots "${module}")
    [[ "${any}" == "true" ]] || echo "    (none)"
}

# _wb_revert_pick <module> <version>
# With a <version>, the snapshot whose name, ref slug, exact label or short
# sha matches. Without one, the next snapshot older than current, so
# repeating 'wb revert' keeps going back rather than bouncing between two.
_wb_revert_pick() {
    local module="$1" version="$2" current snapshot facts label seen_current="false"
    current="$(_wb_revert_current "${module}")"
    while IFS= read -r snapshot; do
        [[ -z "${snapshot}" ]] && continue
        if [[ -n "${version}" ]]; then
            facts="$(_wb_revert_facts "${module}" "${snapshot}")"
            label="${facts%%|*}"
            if [[ "${version}" == "${snapshot}" || "${version}" == "${snapshot%-*}" \
                || "${version}" == "${snapshot##*-}" || "${version}" == "${label}" ]]; then
                printf '%s\n' "${snapshot}"
                return 0
            fi
        elif [[ "${seen_current}" == "true" ]]; then
            printf '%s\n' "${snapshot}"
            return 0
        elif [[ "${snapshot}" == "${current}" ]]; then
            seen_current="true"
        fi
    done < <(_wb_revert_snapshots "${module}")
    return 1
}

# _wb_revert_core_allowed <target-snapshot-dir>
# Going back with core is refused when the older core couldn't serve what's
# on this host: a registered module whose core_api range excludes it, or
# state written by a newer schema. Module syncs check core_api themselves
# (D91), but no module sync runs when core is the one that moved.
_wb_revert_core_allowed() {
    local target="$1" defaults api schema host_schema name manifest range allowed=0
    defaults="${target}/lib/core/version-defaults.conf"
    api="$(awk -F= '$1 == "CORE_API_VERSION" { print $2 }' "${defaults}" 2>/dev/null)"
    schema="$(awk -F= '$1 == "STATE_SCHEMA_VERSION" { print $2 }' "${defaults}" 2>/dev/null)"
    host_schema="$(_workbench_state_schema_version)"
    # Facts that can't be read can't show the older core is safe, and
    # going back with core is the one revert that can break wb itself.
    case "${schema}" in
        ""|*[!0-9]*)
            log_error "wb revert: can't read the state schema version from ${defaults}, so there's no way to check that core can read this host's state"
            return 1
            ;;
    esac
    if [[ -z "${api}" ]]; then
        log_error "wb revert: can't read the Core API version from ${defaults}, so there's no way to check that core can serve your modules"
        return 1
    fi
    case "${schema}:${host_schema}" in
        *[!0-9:]*|:*|*:) ;;
        *)
            if [[ "${schema}" -lt "${host_schema}" ]]; then
                log_error "wb revert: that core uses state schema ${schema}, and this host is already on ${host_schema} — it can't read this host's state"
                allowed=1
            fi
            ;;
    esac
    [[ -n "${api}" ]] || return "${allowed}"
    while IFS= read -r name; do
        [[ -z "${name}" || "${name}" == "core" ]] && continue
        manifest="$(workbench_resolve_manifest_path "$(workbench_module_current_dir "${name}")")"
        [[ -n "${manifest}" ]] || continue
        range="$(workbench_manifest_scalar core_api "${manifest}")"
        [[ -n "${range}" ]] || continue
        if ! _wb_version_satisfies "${api}" "${range}"; then
            log_error "wb revert: ${name} needs Core API '${range}', and that core provides ${api}"
            allowed=1
        fi
    done < <(workbench_list_registered_modules)
    return "${allowed}"
}

# workbench_cmd_revert <name> [<version>] [--list] [--yes]
workbench_cmd_revert() {
    local name="" version="" list="false" yes="false" rc
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)   list="true" ;;
            --yes|-y) yes="true" ;;
            -*)
                log_error "wb revert: unknown flag '$1'"
                return 2
                ;;
            *)
                if [[ -z "${name}" ]]; then
                    name="$1"
                elif [[ -z "${version}" ]]; then
                    version="$1"
                else
                    log_error "wb revert: unexpected extra argument '$1'"
                    return 2
                fi
                ;;
        esac
        shift
    done
    if [[ -z "${name}" ]]; then
        log_error "wb revert: usage: wb revert <name> [<version>] [--list] [--yes]"
        return 2
    fi
    if ! workbench_is_registered "${name}"; then
        log_error "wb revert: '${name}' is not registered"
        return 1
    fi
    if [[ "${list}" == "true" ]]; then
        _wb_revert_list "${name}"
        return 0
    fi

    local target
    if ! target="$(_wb_revert_pick "${name}" "${version}")"; then
        if [[ -n "${version}" ]]; then
            log_error "wb revert: '${version}' isn't on this machine — 'wb revert ${name} --list' shows what is. For anything else: wb track ${name} --tag <tag>"
        else
            log_error "wb revert: no older version of '${name}' on this machine. Workbench keeps the last ${WORKBENCH_SNAPSHOT_KEEP:-3} it fetched. For anything older: wb track ${name} --tag <tag>"
        fi
        return 1
    fi
    if [[ "${target}" == "$(_wb_revert_current "${name}")" ]]; then
        log_info "wb revert: '${name}' is already on $(_wb_revert_display "${name}" "${target}") — no-op"
        return 0
    fi

    local facts label sha new_mode old_mode
    facts="$(_wb_revert_facts "${name}" "${target}")"
    if [[ -z "${facts}" ]]; then
        log_error "wb revert: no record of the exact commit behind ${target} (adoption.log has no entry for it), so it can't be pinned. Use: wb track ${name} --commit <sha>"
        return 1
    fi
    IFS='|' read -r label sha <<< "${facts}"
    new_mode="$(_wb_revert_mode_for "${label}" "${sha}")"
    old_mode="$(workbench_module_conf_get "${name}" TRACK_MODE latest)"

    if [[ "${name}" == "core" ]]; then
        _wb_revert_core_allowed "$(workbench_module_dir core)/snapshots/${target}" || {
            log_error "wb revert: core is unchanged"
            return 1
        }
    fi

    echo
    echo "wb revert: ${name}"
    echo "  from: $(_wb_revert_display "${name}" "$(_wb_revert_current "${name}")")"
    echo "  to:   $(_wb_revert_display "${name}" "${target}")"
    echo
    echo "Its files and config blocks go back to that version. A file you've edited"
    echo "follows the same rules as any update, and anything replaced goes to backups."
    echo "${name} then stays on that version until you run: wb track ${name} --latest"
    echo
    rc=0
    _wb_files_confirm "${yes}" "wb revert" || rc=$?
    [[ "${rc}" -eq 2 ]] && return 0
    [[ "${rc}" -ne 0 ]] && return "${rc}"

    local core_sha_before held_before
    core_sha_before="$(workbench_module_conf_get core RESOLVED_SHA "")"
    held_before="$(workbench_module_conf_get "${name}" HELD_CORE_API "")"

    workbench_module_conf_set "${name}" TRACK_MODE "${new_mode}"
    if ! workbench_sync_module "${name}" "track" "${label}|${sha}"; then
        workbench_module_conf_set "${name}" TRACK_MODE "${old_mode}"
        workbench_module_conf_set "${name}" HELD_CORE_API "${held_before}"
        log_error "wb revert: '${name}' is unchanged, still tracking ${old_mode} — see above"
        return 1
    fi
    workbench_files_settle_orphans "${name}"
    log_info "wb revert: ${name} is now on ${label} and will stay there. To go back to following releases: wb track ${name} --latest"
    workbench_is_sync_enabled "${name}" \
        || log_info "wb revert: ${name}'s sync is also off, so after that it only updates when you run 'wb update ${name}' — 'wb sync enable ${name}' turns updates on"

    command -v _wb_maybe_reconverge_core &>/dev/null && _wb_maybe_reconverge_core "${core_sha_before}" false
    return 0
}
