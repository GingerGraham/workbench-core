#!/usr/bin/env bash
# lib/modules/sync-toggle.sh — `wb sync enable|disable [<name>]`
# (ARCHITECTURE.md §9.7/§10). Independent of TRACK_MODE — toggling this
# never changes what a module tracks, only whether the timer/bulk
# `wb update` touches it. No argument means core's own toggle (module zero,
# no special-casing beyond "core" being the default name).

command -v workbench_register_script_version &>/dev/null && workbench_register_script_version "lib/modules/sync-toggle.sh" "0.1.0" || true

# workbench_cmd_sync_toggle <enable|disable> [<name>]
workbench_cmd_sync_toggle() {
    local action="$1" name="${2:-core}"
    local value
    case "${action}" in
        enable)  value="true" ;;
        disable) value="false" ;;
        *)
            log_error "wb sync: usage: wb sync enable|disable [<name>]"
            return 2
            ;;
    esac

    if ! workbench_is_registered "${name}"; then
        log_error "wb sync ${action}: '${name}' is not registered"
        return 1
    fi

    local current
    current="$(workbench_module_conf_get "${name}" SYNC_ENABLED true)"
    if [[ "${current}" == "${value}" ]]; then
        log_info "wb sync ${action}: '${name}' sync is already ${value} — no-op"
        return 0
    fi

    workbench_module_conf_set "${name}" SYNC_ENABLED "${value}"
    log_info "wb sync ${action}: '${name}' sync.enabled is now ${value}"
}
