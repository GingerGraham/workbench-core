#!/usr/bin/env bash
# lib/modules/remove.sh — `wb remove` (ARCHITECTURE.md §10).
#
# Idempotent, non-destructive: flips REGISTERED=false so the loader stops
# sourcing this module's register.list and the sync engine stops touching
# it, but never deletes snapshots/, deployed content, or sync.conf itself
# (re-adding later, or hand-inspecting what was deployed, both still work).

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/modules/remove.sh" "0.1.0" || true

# workbench_cmd_remove <name>
workbench_cmd_remove() {
    local name="$1"
    if [[ -z "${name}" ]]; then
        log_error "wb remove: usage: wb remove <name>"
        return 2
    fi

    if ! workbench_is_registered "${name}"; then
        log_info "wb remove: '${name}' is not registered — no-op"
        return 0
    fi

    workbench_module_conf_set "${name}" REGISTERED "false"
    log_info "wb remove: '${name}' deregistered — its deployed content and snapshots are left in place; re-run 'wb add ${name}' to bring it back"
}
