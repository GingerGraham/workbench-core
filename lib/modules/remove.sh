#!/usr/bin/env bash
# lib/modules/remove.sh — `wb remove` (docs/architecture.md §10).
#
# Idempotent, non-destructive: flips REGISTERED=false so the loader stops
# sourcing this module's register.list and the sync engine stops touching
# it, but never deletes snapshots/, deployed content, or sync.conf itself
# (re-adding later, or hand-inspecting what was deployed, both still work).

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/modules/remove.sh" "0.1.0" || true

# workbench_cmd_remove <name> [--restore [--yes]]
# --restore (docs/decisions-log.md D81): first 'wb files restore <name> all'
# — same preview and confirmation (bin/wb's _wb_files_restore_run) — and
# deregister only if that went ahead and succeeded.
workbench_cmd_remove() {
    local name="" restore="false" yes="false" rc
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restore) restore="true" ;;
            --yes|-y)  yes="true" ;;
            -*)
                log_error "wb remove: unknown flag '$1'"
                return 2
                ;;
            *)
                if [[ -n "${name}" ]]; then
                    log_error "wb remove: unexpected extra argument '$1'"
                    return 2
                fi
                name="$1"
                ;;
        esac
        shift
    done
    if [[ -z "${name}" ]]; then
        log_error "wb remove: usage: wb remove <name> [--restore [--yes]]"
        return 2
    fi

    if ! workbench_is_registered "${name}"; then
        log_info "wb remove: '${name}' is not registered — no-op"
        return 0
    fi

    if [[ "${restore}" == "true" ]]; then
        _wb_engine_require_files
        rc=0
        _wb_files_restore_run "${name}" all "${yes}" "wb remove" || rc=$?
        case "${rc}" in
            0) ;;
            2) log_info "wb remove: '${name}' is still registered"; return 0 ;;
            *) log_error "wb remove: '${name}' is still registered — restore didn't complete; see above"; return 1 ;;
        esac
        workbench_module_conf_set "${name}" REGISTERED "false"
        log_info "wb remove: '${name}' deregistered and its files put back — its snapshots are left in place; re-run 'wb add ${name}' to bring it back"
        return 0
    fi

    workbench_module_conf_set "${name}" REGISTERED "false"
    log_info "wb remove: '${name}' deregistered — its deployed content and snapshots are left in place; re-run 'wb add ${name}' to bring it back — to put back the files it replaced, run 'wb remove ${name} --restore' instead"
}
