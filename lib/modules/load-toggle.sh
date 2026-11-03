#!/usr/bin/env bash
# lib/modules/load-toggle.sh — `wb load enable|disable <name>`
# (docs/decisions-log.md D108). Whether new shells source a module's shell
# content. Independent of sync and registration: updates, config files and
# `wb tools` carry on either way, so this answers "is its shell code the
# problem?" without changing anything else.

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/modules/load-toggle.sh" "0.1.0" || true

# workbench_cmd_load_toggle <enable|disable> <name>
workbench_cmd_load_toggle() {
    local action="$1" name="${2:-}" value
    case "${action}" in
        enable)  value="true" ;;
        disable) value="false" ;;
    esac
    if [[ -z "${name}" ]]; then
        log_error "wb load: usage: wb load enable|disable <name>"
        return 2
    fi
    # Every module's shell content relies on core's. No default to core either:
    # unlike 'wb sync', turning off the wrong thing here breaks the shell.
    if [[ "${name}" == "core" ]]; then
        log_error "wb load: core's shell content can't be turned off, because every module relies on it"
        return 1
    fi
    if ! workbench_is_registered "${name}"; then
        log_error "wb load ${action}: '${name}' is not registered"
        return 1
    fi
    if [[ "$(workbench_module_conf_get "${name}" LOAD_ENABLED true)" == "${value}" ]]; then
        log_info "wb load ${action}: '${name}' is already ${action}d — no-op"
        return 0
    fi
    workbench_module_conf_set "${name}" LOAD_ENABLED "${value}"
    if [[ "${value}" == "false" ]]; then
        log_info "wb load disable: new shells won't load ${name}'s shell content. Its updates and config carry on. Open a new terminal to see the effect: this one keeps what it loaded. 'wb load enable ${name}' turns it back on."
    else
        log_info "wb load enable: new shells will load ${name}'s shell content again"
    fi
}
