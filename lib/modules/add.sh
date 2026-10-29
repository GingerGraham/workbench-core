#!/usr/bin/env bash
# lib/modules/add.sh — `wb add` (docs/architecture.md §9/§10).
#
# Hot-path registration: writes sync.conf, bootstraps SSH if private, then
# runs one real sync cycle immediately (workbench_sync_module) — the exact
# same function `wb apply`'s convergence and the timer both call. This IS the §8 convergence constraint: `wb add` writes a strict
# subset of what a full `wb apply` would produce for the same input, by
# construction, because it invokes the identical engine rather than a
# second implementation of "fetch and register a module."

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/modules/add.sh" "0.5.1" || true

# workbench_cmd_add <name> [url] [--private] [--allow-hooks] [--keep-files | --use-files [--follow] [--yes]] [--skip-layer <id>]...
# workbench_cmd_add <name> <name>... [--keep-files | --use-files [--follow] [--yes]] [--skip-layer <id>]...
# The first sync is staged (docs/decisions-log.md D84): fetched, nothing
# deployed, then bin/wb's _wb_install_modules shows which of the user's
# files the module would touch and asks keep / use / choose / diff / quit
# (through /dev/tty; no terminal means keep) before deploying.
# --keep-files answers keep, --use-files use (D81: preview and confirmation
# unless --yes). On an already-registered module, --use-files switches
# its files now (bin/wb's _wb_files_use_at_install).
# --stage-only (internal, for workbench_add_modules): register and stage,
# leaving the question and the deploy to the caller.
# --skip-layer <id> (repeatable, docs/decisions-log.md D82): a 'skip' policy
# row for that layer, written before the first deploy.
#
# Two or more names (docs/decisions-log.md D106) go through
# workbench_add_modules — the same path as 'wb install --bundle': every
# name is checked against the catalog before anything is registered, then
# one question covers every new module. A url, --private and --allow-hooks
# are per-repo decisions and only go with a single name.
#
# A positional after the first name is a url if it contains '/' or ':'
# (every shape workbench_valid_repo_url accepts does, and no valid module
# name can), otherwise another module name.
workbench_cmd_add() {
    local name="" url="" private="false" allow_hooks="false" use_files="false" follow="false" yes="false"
    local keep_files="false" stage_only="false" skip_layers="" layer_id mode rc
    local -a extra_names=()
    local args=("$@")
    local i=0
    while [[ "${i}" -lt "${#args[@]}" ]]; do
        local a="${args[${i}]}"
        case "${a}" in
            --private)     private="true" ;;
            --allow-hooks) allow_hooks="true" ;;
            --use-files)   use_files="true" ;;
            --keep-files)  keep_files="true" ;;
            --stage-only)  stage_only="true" ;;
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
                else
                    case "${a}" in
                        */*|*:*)
                            if [[ -n "${url}" ]]; then
                                log_error "wb add: unexpected extra argument '${a}'"
                                return 2
                            fi
                            url="${a}"
                            ;;
                        *)
                            extra_names+=("${a}")
                            ;;
                    esac
                fi
                ;;
        esac
        i=$((i + 1))
    done

    if [[ -z "${name}" ]]; then
        log_error "wb add: usage: wb add <name> [url] [--private] [--allow-hooks] [--keep-files | --use-files [--follow] [--yes]] [--skip-layer <id>]...  |  wb add <name> <name>... [--keep-files | --use-files [--follow] [--yes]] [--skip-layer <id>]..."
        return 2
    fi
    if [[ "${keep_files}" == "true" && "${use_files}" == "true" ]]; then
        log_error "wb add: --keep-files and --use-files contradict each other — pick one"
        return 2
    fi
    if [[ "${follow}" == "true" && "${use_files}" != "true" ]]; then
        log_error "wb add: --follow goes with --use-files"
        return 2
    fi

    if [[ "${#extra_names[@]}" -gt 0 ]]; then
        if [[ -n "${url}" ]]; then
            log_error "wb add: a url applies to one module — add a module from its url on its own ('wb add <name> <url>'). Nothing was changed."
            return 2
        fi
        if [[ "${private}" == "true" ]]; then
            log_error "wb add: --private goes with a url, which applies to one module — add it on its own ('wb add <name> <url> --private'). Nothing was changed."
            return 2
        fi
        if [[ "${allow_hooks}" == "true" ]]; then
            log_error "wb add: --allow-hooks is a per-module decision — add each module that should run hooks on its own ('wb add <name> --allow-hooks'). Nothing was changed."
            return 2
        fi
        if [[ "${stage_only}" == "true" ]]; then
            log_error "wb add: --stage-only takes one module"
            return 2
        fi
        _wb_add_many "${keep_files}" "${use_files}" "${follow}" "${yes}" "${skip_layers}" "${name}" "${extra_names[@]}"
        return $?
    fi

    if ! workbench_valid_module_name "${name}"; then
        log_error "wb add: '${name}' is not a valid module name — lowercase letters, digits and '-' only, starting with a letter or digit, at most 64 characters"
        return 2
    fi

    # Refuse before registering anything: the --use-files confirmation
    # can't be asked without a terminal.
    if [[ "${use_files}" == "true" && "${yes}" != "true" ]] && ! _wb_have_tty; then
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
            if workbench_catalog_bundle_modules "${name}" >/dev/null 2>&1; then
                log_error "wb add: '${name}' is a bundle, not a module — use 'wb install --bundle ${name}'"
            else
                log_error "wb add: '${name}' has no url given and is not in the known-modules catalog — pass a url explicitly"
            fi
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

    log_info "wb add: registered '${name}' (${url}), fetching..."
    if ! workbench_sync_module "${name}" "stage"; then
        log_warn "wb add: '${name}' registered, but the initial sync failed — it will retry on the next cycle (see 'wb update ${name}')"
        [[ "${use_files}" == "true" ]] && log_warn "wb add: --use-files skipped — run 'wb add ${name} --use-files' once it has synced"
        return 0
    fi
    [[ "${stage_only}" == "true" ]] && return 0

    mode="ask"
    [[ "${keep_files}" == "true" ]] && mode="keep"
    [[ "${use_files}" == "true" ]] && mode="use"
    rc=0
    _wb_install_modules "${mode}" "${follow}" "${yes}" add "${name}" || rc=$?
    case "${rc}" in
        0) log_info "wb add: '${name}' registered and synced successfully" ;;
        3) return 0 ;;
        *) log_warn "wb add: '${name}' registered; not everything was deployed — see above ('wb files status')"; return "${rc}" ;;
    esac
}

# _wb_add_many <keep_files> <use_files> <follow> <yes> <skip_layers> <name>...
# 'wb add <name> <name>...' (docs/decisions-log.md D106). Every name is
# checked first — a valid module name, and either already registered or
# in the known-modules catalog — and if any fails, every failure is named
# in one error and nothing is registered (exit 2, as for an unknown
# bundle, D88). A typo in the third name never leaves two modules
# registered. Then workbench_add_modules does the work, and one summary
# says what was registered, what already was, and what failed.
_wb_add_many() {
    local keep_files="$1" use_files="$2" follow="$3" yes="$4" skip_layers="$5"
    shift 5
    local n mode rc=0
    local invalid="" unknown="" bundles="" registered_already=""
    local -a names=()

    _wb_require modules/catalog.sh

    # De-duplicate, keeping the order given.
    for n in "$@"; do
        case " ${names[*]:-} " in
            *" ${n} "*) continue ;;
        esac
        names+=("${n}")
    done

    for n in "${names[@]}"; do
        if ! workbench_valid_module_name "${n}"; then
            invalid="${invalid} ${n}"
        elif workbench_is_registered "${n}"; then
            registered_already="${registered_already} ${n}"
        elif ! workbench_catalog_lookup "${n}" >/dev/null; then
            if workbench_catalog_bundle_modules "${n}" >/dev/null 2>&1; then
                bundles="${bundles} ${n}"
            else
                unknown="${unknown} ${n}"
            fi
        fi
    done

    if [[ -n "${invalid}${unknown}${bundles}" ]]; then
        [[ -n "${invalid}" ]] && log_error "wb add: not valid module names (lowercase letters, digits and '-' only):${invalid}"
        [[ -n "${unknown}" ]] && log_error "wb add: not in the known-modules catalog:${unknown} — a module from a url is added on its own ('wb add <name> <url>')"
        [[ -n "${bundles}" ]] && log_error "wb add: bundles, not modules:${bundles} — use 'wb install --bundle <name>'"
        log_error "wb add: nothing was changed."
        return 2
    fi
    if [[ -n "${skip_layers}" && -n "${registered_already}" ]]; then
        log_error "wb add: already registered:${registered_already} — --skip-layer only applies before a module's first deploy; use 'wb files policy <name> <layer> skip'. Nothing was changed."
        return 2
    fi

    # Refuse before registering anything: the --use-files confirmation
    # can't be asked without a terminal.
    if [[ "${use_files}" == "true" && "${yes}" != "true" ]] && ! _wb_have_tty; then
        log_error "wb add: --use-files needs a terminal to confirm — re-run with --yes. Nothing was changed."
        return 1
    fi

    mode="ask"
    [[ "${keep_files}" == "true" ]] && mode="keep"
    [[ "${use_files}" == "true" ]] && mode="use"
    workbench_add_modules "wb add" "${mode}" "${follow}" "${yes}" "${skip_layers}" "${names[@]}" || rc=$?

    echo
    [[ -n "${_WB_ADD_STAGED}" ]] && log_info "wb add: registered:${_WB_ADD_STAGED}"
    [[ -n "${_WB_ADD_EARLIER}" ]] && log_info "wb add: already registered:${_WB_ADD_EARLIER}"
    [[ -n "${_WB_ADD_FAILED}" ]] && log_error "wb add: not registered:${_WB_ADD_FAILED} — run 'wb add <name>' for each to see why"
    return "${rc}"
}

# workbench_add_modules <caller> <mode> <follow> <yes> <skip_layers> <name>...
# Registers and stages every <name> not registered yet (its url from the
# known-modules catalog), then asks the D84 question once across every
# newly staged module and deploys them. The one path behind both
# 'wb install --bundle' and 'wb add <name> <name>...' (docs/decisions-log.md
# D106): a bundle is a catalog-supplied list of names, nothing more.
#   <caller>       prefix for log lines: "wb install" or "wb add"
#   <mode>         ask | keep | use
#   <skip_layers>  space-separated layer ids, a 'skip' policy for each
#                    newly registered module ("" for none)
# Names already registered are reported and, with mode use, switched to
# the module's files (D81). Sets three space-separated name lists for the
# caller's summary: _WB_ADD_STAGED (newly registered), _WB_ADD_EARLIER
# (already registered), _WB_ADD_FAILED (could not be registered).
# Returns 0 when everything registered and deployed (a quit at the
# question counts: the user chose it), 1 otherwise.
workbench_add_modules() {
    local caller="$1" mode="$2" follow="$3" yes="$4" skip_layers="$5"
    shift 5
    local member layer_id install_rc=0 use_rc=0
    local -a add_args=() staged=() earlier=()
    _WB_ADD_STAGED=""
    _WB_ADD_EARLIER=""
    _WB_ADD_FAILED=""

    for layer_id in ${skip_layers}; do
        add_args+=(--skip-layer "${layer_id}")
    done

    for member in "$@"; do
        if workbench_is_registered "${member}"; then
            log_info "${caller}: '${member}' is already registered"
            earlier+=("${member}")
            _WB_ADD_EARLIER="${_WB_ADD_EARLIER} ${member}"
            continue
        fi
        if workbench_cmd_add "${member}" --stage-only ${add_args[@]+"${add_args[@]}"} </dev/null; then
            staged+=("${member}")
            _WB_ADD_STAGED="${_WB_ADD_STAGED} ${member}"
        else
            _WB_ADD_FAILED="${_WB_ADD_FAILED} ${member}"
        fi
    done

    # One plan and one question across every new module, after the loop
    # (D84). Modules registered before keep D81's --use-files.
    if [[ "${#staged[@]}" -gt 0 ]]; then
        _wb_install_modules "${mode}" "${follow}" "${yes}" add "${staged[@]}" || install_rc=$?
        if [[ "${install_rc}" -ne 0 && "${install_rc}" -ne 3 ]]; then
            log_warn "${caller}: not every file was deployed — see above; 'wb files status' shows where things stand"
        fi
    fi
    if [[ "${mode}" == "use" && "${#earlier[@]}" -gt 0 ]]; then
        if ! _wb_files_use_at_install "${follow}" "${yes}" "${earlier[@]}"; then
            use_rc=1
            log_warn "${caller}: --use-files didn't complete for every file — see above; 'wb files status' shows where things stand"
        fi
    fi

    if [[ -n "${_WB_ADD_FAILED}" ]]; then
        return 1
    fi
    if [[ "${install_rc}" -ne 0 && "${install_rc}" -ne 3 ]]; then
        return 1
    fi
    return "${use_rc}"
}
