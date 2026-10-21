#!/usr/bin/env bash
# lib/modules/add.sh — `wb add` (docs/architecture.md §9/§10).
#
# Hot-path registration: writes sync.conf, bootstraps SSH if private, then
# runs one real sync cycle immediately (workbench_sync_module) — the exact
# same function `wb apply`'s Ansible-driven convergence and the timer both
# call. This IS the §8 convergence constraint: `wb add` writes a strict
# subset of what a full `wb apply` would produce for the same input, by
# construction, because it invokes the identical engine rather than a
# second implementation of "fetch and register a module."

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/modules/add.sh" "0.3.0" || true

# workbench_cmd_add <name> [url] [--private] [--allow-hooks] [--use-files [--follow] [--yes]] [--skip-layer <id>]...
# --use-files (docs/decisions-log.md D81): after the sync, use the module's
# version wherever the user already has their own config — one preview, one
# confirmation (bin/wb's _wb_files_use_at_install). On an already-registered
# module, only that step runs.
# --skip-layer <id> (repeatable, docs/decisions-log.md D82): a 'skip' policy
# row for that layer, written before the first deploy.
workbench_cmd_add() {
    local name="" url="" private="false" allow_hooks="false" use_files="false" follow="false" yes="false"
    local skip_layers="" layer_id
    local args=("$@")
    local i=0
    while [[ "${i}" -lt "${#args[@]}" ]]; do
        local a="${args[${i}]}"
        case "${a}" in
            --private)     private="true" ;;
            --allow-hooks) allow_hooks="true" ;;
            --use-files)   use_files="true" ;;
            --follow)      follow="true" ;;
            --yes|-y)      yes="true" ;;
            --skip-layer)
                i=$((i + 1))
                layer_id="${args[${i}]:-}"
                # A layer id is an adapter (lib/manifest/parse.sh's one list),
                # optionally with ':over'.
                if ! _wb_layer_adapter_known "${layer_id%:over}"; then
                    log_error "wb add: --skip-layer needs a layer id — one of ${_WB_LAYER_ADAPTERS}, optionally with ':over'"
                    return 2
                fi
                skip_layers="${skip_layers} ${layer_id}"
                ;;
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
        log_error "wb add: usage: wb add <name> [url] [--private] [--allow-hooks] [--use-files [--follow] [--yes]] [--skip-layer <id>]..."
        return 2
    fi
    if [[ "${follow}" == "true" && "${use_files}" != "true" ]]; then
        log_error "wb add: --follow goes with --use-files"
        return 2
    fi

    if ! workbench_valid_module_name "${name}"; then
        log_error "wb add: '${name}' is not a valid module name — lowercase letters, digits and '-' only, starting with a letter or digit, at most 64 characters"
        return 2
    fi

    # Refuse before registering anything: the --use-files confirmation
    # can't be asked without a terminal.
    if [[ "${use_files}" == "true" && "${yes}" != "true" && ! -t 0 ]]; then
        log_error "wb add: --use-files needs a terminal to confirm — re-run with --yes. Nothing was changed."
        return 1
    fi

    if workbench_is_registered "${name}"; then
        if [[ -n "${skip_layers}" ]]; then
            log_error "wb add: '${name}' is already registered — skip a layer with 'wb files policy ${name} <layer> skip'"
            return 1
        fi
        if [[ "${use_files}" == "true" ]]; then
            _wb_files_use_at_install "${follow}" "${yes}" "${name}"
            return $?
        fi
        log_info "wb add: '${name}' is already registered — no-op"
        return 0
    fi

    if [[ -z "${url}" ]]; then
        _wb_require modules/catalog.sh
        local catalog_entry catalog_url catalog_private
        catalog_entry="$(workbench_catalog_lookup "${name}")" || {
            log_error "wb add: '${name}' has no url given and is not in the known-modules catalog — pass a url explicitly"
            return 1
        }
        IFS='|' read -r catalog_url catalog_private <<< "${catalog_entry}"
        url="${catalog_url}"
        [[ "${private}" == "false" ]] && private="${catalog_private}"
    fi

    if ! workbench_valid_repo_url "${url}"; then
        log_error "wb add: '${url}' is not a recognised repo url shape (https://, ssh://, git@host:path, file://, or an absolute local path)"
        return 2
    fi

    mkdir -p "$(workbench_module_dir "${name}")"
    workbench_module_conf_set "${name}" REPO_URL "${url}"
    workbench_module_conf_set "${name}" PRIVATE "${private}"
    workbench_module_conf_set "${name}" TRACK_MODE "latest"
    workbench_module_conf_set "${name}" REGISTERED "true"
    workbench_module_conf_set "${name}" SYNC_ENABLED "true"
    workbench_module_conf_set "${name}" ALLOW_HOOKS "${allow_hooks}"

    if [[ -n "${skip_layers}" ]]; then
        _wb_engine_require_files
        for layer_id in ${skip_layers}; do
            workbench_files_policy_set "${name}" "${layer_id}" skip
            log_info "wb add: ${name}: layer '${layer_id}' will be skipped"
        done
    fi

    if [[ "${private}" == "true" ]]; then
        _wb_require ssh/bootstrap.sh
        workbench_ssh_bootstrap_module "${name}"
    fi

    log_info "wb add: registered '${name}' (${url}), syncing now..."
    if workbench_sync_module "${name}" "add"; then
        log_info "wb add: '${name}' registered and synced successfully"
    else
        log_warn "wb add: '${name}' registered, but the initial sync failed — it will retry on the next cycle (see 'wb update ${name}')"
        [[ "${use_files}" == "true" ]] && log_warn "wb add: --use-files skipped — run 'wb add ${name} --use-files' once it has synced"
        return 0
    fi
    if [[ "${use_files}" == "true" ]]; then
        _wb_files_use_at_install "${follow}" "${yes}" "${name}"
    fi
}
