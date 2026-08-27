#!/usr/bin/env bash
# lib/modules/add.sh — `wb add` (ARCHITECTURE.md §9/§10).
#
# Hot-path registration: writes sync.conf, bootstraps SSH if private, then
# runs one real sync cycle immediately (workbench_sync_module) — the exact
# same function `wb apply`'s Ansible-driven convergence and the timer both
# call. This IS the §8 convergence constraint: `wb add` writes a strict
# subset of what a full `wb apply` would produce for the same input, by
# construction, because it invokes the identical engine rather than a
# second implementation of "fetch and register a module."

# workbench_cmd_add <name> [url] [--private] [--allow-hooks]
workbench_cmd_add() {
    local name="" url="" private="false" allow_hooks="false"
    local args=("$@")
    local i=0
    while [[ "${i}" -lt "${#args[@]}" ]]; do
        local a="${args[${i}]}"
        case "${a}" in
            --private)     private="true" ;;
            --allow-hooks) allow_hooks="true" ;;
            --*)
                log_error "wb add: unknown flag '${a}'"
                return 2
                ;;
            *)
                if [[ -z "${name}" ]]; then
                    name="${a}"
                elif [[ -z "${url}" ]]; then
                    url="${a}"
                else
                    log_error "wb add: unexpected extra argument '${a}'"
                    return 2
                fi
                ;;
        esac
        i=$((i + 1))
    done

    if [[ -z "${name}" ]]; then
        log_error "wb add: usage: wb add <name> [url] [--private] [--allow-hooks]"
        return 2
    fi

    if workbench_is_registered "${name}"; then
        log_info "wb add: '${name}' is already registered — no-op"
        return 0
    fi

    if [[ -z "${url}" ]]; then
        local catalog_entry catalog_url catalog_private
        catalog_entry="$(workbench_catalog_lookup "${name}")" || {
            log_error "wb add: '${name}' has no url given and is not in the known-modules catalog — pass a url explicitly"
            return 1
        }
        IFS='|' read -r catalog_url catalog_private <<< "${catalog_entry}"
        url="${catalog_url}"
        [[ "${private}" == "false" ]] && private="${catalog_private}"
    fi

    mkdir -p "$(workbench_module_dir "${name}")"
    workbench_module_conf_set "${name}" REPO_URL "${url}"
    workbench_module_conf_set "${name}" PRIVATE "${private}"
    workbench_module_conf_set "${name}" TRACK_MODE "latest"
    workbench_module_conf_set "${name}" REGISTERED "true"
    workbench_module_conf_set "${name}" SYNC_ENABLED "true"
    workbench_module_conf_set "${name}" ALLOW_HOOKS "${allow_hooks}"

    if [[ "${private}" == "true" ]]; then
        workbench_ssh_bootstrap_module "${name}"
    fi

    log_info "wb add: registered '${name}' (${url}), syncing now..."
    if workbench_sync_module "${name}" "add"; then
        log_info "wb add: '${name}' registered and synced successfully"
    else
        log_warn "wb add: '${name}' registered, but the initial sync failed — it will retry on the next cycle (see 'wb update ${name}')"
    fi
}
