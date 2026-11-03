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
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/modules/add.sh" "0.7.0" || true

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
#
# A module 'wb remove' deregistered isn't new: _wb_add_returning brings it
# back with its settings and asks which version (docs/decisions-log.md D108).
# --latest and --keep-version answer that without asking.
workbench_cmd_add() {
    local name="" url="" private="false" allow_hooks="false" use_files="false" follow="false" yes="false"
    local keep_files="false" stage_only="false" skip_layers="" layer_id mode rc version_flag=""
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
            --latest|--keep-version)
                if [[ -n "${version_flag}" && "${version_flag}" != "${a}" ]]; then
                    log_error "wb add: --latest and --keep-version contradict each other — pick one"
                    return 2
                fi
                version_flag="${a}"
                ;;
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
        _WB_ADD_VERSION_FLAG="${version_flag}"
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

    if _wb_add_is_returning "${name}" "${url}"; then
        _wb_add_returning "${name}" "${version_flag}" "${private}" "${allow_hooks}" \
            "${keep_files}" "${use_files}" "${follow}" "${yes}" "${skip_layers}"
        return $?
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

# _wb_add_is_returning <name> <url>
# True for a module 'wb remove' deregistered whose state is still on disk. A
# different url is a different repo, so that registers as new.
_wb_add_is_returning() {
    local name="$1" url="$2" stored
    [[ -f "$(workbench_module_conf_path "${name}")" ]] || return 1
    workbench_is_registered "${name}" && return 1
    [[ -d "$(workbench_module_current_dir "${name}")" ]] || return 1
    stored="$(workbench_module_conf_get "${name}" REPO_URL "")"
    [[ -n "${stored}" ]] || return 1
    [[ -z "${url}" || "${url}" == "${stored}" ]]
}

# _wb_add_ask_version <label>
# Prints latest, keep, or abort when the terminal closes. The question goes
# through /dev/tty, as every other wb question does.
_wb_add_ask_version() {
    local label="$1" answer
    {
        echo
        echo "  1) Move to the latest release and follow updates (recommended)"
        echo "  2) Stay on ${label}, pinned"
        echo
    } >/dev/tty
    while true; do
        printf 'Choose [1/2] (Enter for 1): ' >/dev/tty
        if ! IFS= read -r answer </dev/tty; then
            echo abort
            return 0
        fi
        case "${answer}" in
            ""|1) echo latest; return 0 ;;
            2)    echo keep; return 0 ;;
        esac
        echo "Please enter 1 or 2." >/dev/tty
    done
}

# _wb_add_returning_config <name> <keep_files> <use_files> <follow> <yes>
# After 'wb remove --restore', the user's config is back and the module's rows
# are marked restored. Taking it out was a deliberate choice, so putting it
# back needs a yes: the default is no, and with no terminal the answer is no.
# Asks before calling _wb_files_use_at_install, which clears those rows.
_wb_add_returning_config() {
    local name="$1" keep_files="$2" use_files="$3" follow="$4" yes="$5" restored answer
    restored="$(workbench_files_ledger_rows "${name}" | awk -F'|' '$3 == "restored" { sub(/#.*/, "", $1); print $1 }' | sort -u)"
    if [[ "${use_files}" == "true" ]]; then
        _wb_files_use_at_install "${follow}" "${yes}" "${name}"
        return $?
    fi
    [[ -n "${restored}" ]] || return 0
    if [[ "${keep_files}" == "true" ]]; then
        return 0
    fi
    if ! _wb_have_tty; then
        log_info "wb add: ${name}'s config stays out, as you left it — 'wb add ${name} --use-files' puts it back"
        return 0
    fi
    {
        echo
        echo "You took ${name}'s config out with 'wb remove --restore':"
        printf '%s\n' "${restored}" | sed 's/^/  /'
        printf 'Put it back? [y/N]: '
    } >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
    case "${answer}" in
        y|Y|yes|YES)
            _wb_files_use_at_install "${follow}" true "${name}"
            return $?
            ;;
    esac
    log_info "wb add: ${name}'s config stays out — 'wb add ${name} --use-files' puts it back"
}

# _wb_add_returning <name> <version_flag> <private> <allow_hooks> <keep_files> <use_files> <follow> <yes> <skip_layers>
# Brings back a deregistered module with its url, pin, sync, load and hook
# settings. It always offers the choice of version. With nothing to decide, or
# no terminal to ask on, the module returns as the user left it: a pin stays
# pinned, and a module following releases follows them. Staying on a version
# needs no network; only moving to the latest does (docs/decisions-log.md D108).
_wb_add_returning() {
    local name="$1" version_flag="$2" private="$3" allow_hooks="$4" keep_files="$5"
    local use_files="$6" follow="$7" yes="$8" skip_layers="$9"
    _wb_engine_require_files
    _wb_require distribution/resolve.sh modules/revert.sh

    local mode snapshot facts label sha pinned="true" newest newest_label="" newest_sha="" choice layer_id
    mode="$(workbench_module_conf_get "${name}" TRACK_MODE latest)"
    case "${mode}" in
        latest|branch:*) pinned="false" ;;
    esac
    snapshot="$(_wb_revert_current "${name}")"
    facts="$(_wb_revert_facts "${name}" "${snapshot}")"
    label="${facts%%|*}"
    sha="${facts##*|}"
    [[ -n "${label}" ]] || label="${snapshot%-*}"
    newest="$(workbench_resolve_module "${name}" latest 2>/dev/null)"
    if [[ -n "${newest}" ]]; then
        newest_label="${newest%%|*}"
        newest_sha="${newest##*|}"
    fi

    echo
    if [[ "${pinned}" == "true" ]]; then
        echo "${name} was pinned to ${label} when you removed it."
    else
        echo "${name} was on ${label} when you removed it."
    fi
    if [[ -n "${newest_label}" ]]; then
        echo "The latest release is ${newest_label}."
    else
        echo "Couldn't check for a newer release, so the latest version isn't known."
    fi

    case "${version_flag}" in
        --latest)       choice="latest" ;;
        --keep-version) choice="keep" ;;
        *)
            if [[ -z "${newest_sha}" ]]; then
                choice="as-left"
            elif [[ "${pinned}" == "false" && "$(workbench_module_conf_get "${name}" RESOLVED_SHA "")" == "${newest_sha}" ]]; then
                choice="as-left"
            elif ! _wb_have_tty; then
                log_info "wb add: no terminal to ask on, so ${name} comes back as you left it — 'wb track ${name} --latest' moves it on"
                choice="as-left"
            else
                choice="$(_wb_add_ask_version "${label}")"
            fi
            ;;
    esac
    if [[ "${choice}" == "abort" ]]; then
        log_info "wb add: nothing was changed — '${name}' is still removed"
        return 0
    fi

    workbench_module_conf_set "${name}" REGISTERED "true"
    [[ "${private}" == "true" ]] && workbench_module_conf_set "${name}" PRIVATE "true"
    [[ "${allow_hooks}" == "true" ]] && workbench_module_conf_set "${name}" ALLOW_HOOKS "true"
    for layer_id in ${skip_layers}; do
        workbench_files_policy_set "${name}" "${layer_id}" skip
        log_info "wb add: ${name}: layer '${layer_id}' will be skipped"
    done
    if [[ "$(workbench_module_conf_get "${name}" PRIVATE false)" == "true" ]]; then
        _wb_require ssh/bootstrap.sh
        workbench_ssh_bootstrap_module "${name}"
    fi

    case "${choice}" in
        latest)
            local held_before
            held_before="$(workbench_module_conf_get "${name}" HELD_CORE_API "")"
            workbench_module_conf_set "${name}" TRACK_MODE "latest"
            if ! workbench_sync_module "${name}" "add"; then
                workbench_module_conf_set "${name}" TRACK_MODE "${mode}"
                workbench_module_conf_set "${name}" HELD_CORE_API "${held_before}"
                log_warn "wb add: couldn't reach the latest release, so '${name}' stays on ${label} — 'wb track ${name} --latest' tries again"
            fi
            ;;
        keep)
            if [[ "${pinned}" == "false" ]]; then
                if [[ -n "${facts}" ]]; then
                    workbench_module_conf_set "${name}" TRACK_MODE "$(_wb_revert_mode_for "${label}" "${sha}")"
                else
                    log_warn "wb add: no record of the exact commit behind ${label}, so '${name}' can't be pinned and will follow ${mode}"
                fi
            fi
            ;;
        as-left)
            if [[ "${pinned}" == "false" ]] && ! workbench_sync_module "${name}" "add"; then
                log_warn "wb add: '${name}' couldn't sync just now, so it stays on ${label} — it tries again next cycle ('wb update ${name}')"
            fi
            ;;
    esac
    workbench_render_register_list "${name}"
    workbench_render_installers_list "${name}"
    workbench_render_getters_list "${name}"

    workbench_is_sync_enabled "${name}" \
        || log_info "wb add: ${name}'s sync is still off, as you left it — 'wb sync enable ${name}' turns updates on"
    workbench_is_load_enabled "${name}" \
        || log_info "wb add: ${name}'s shell content is still off, as you left it — 'wb load enable ${name}' turns it on"

    local returning_rc=0
    _wb_add_returning_config "${name}" "${keep_files}" "${use_files}" "${follow}" "${yes}" || returning_rc=$?

    facts="$(_wb_revert_facts "${name}" "$(_wb_revert_current "${name}")")"
    log_info "wb add: '${name}' is back, on ${facts%%|*}"
    return "${returning_rc}"
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
        elif _wb_add_is_returning "${n}" ""; then
            :
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
        # A returning module asks its own questions and needs no staging.
        if _wb_add_is_returning "${member}" ""; then
            local -a returning_args=()
            [[ -n "${_WB_ADD_VERSION_FLAG:-}" ]] && returning_args+=("${_WB_ADD_VERSION_FLAG}")
            [[ "${mode}" == "keep" ]] && returning_args+=(--keep-files)
            [[ "${mode}" == "use" ]] && returning_args+=(--use-files)
            [[ "${follow}" == "true" ]] && returning_args+=(--follow)
            [[ "${yes}" == "true" ]] && returning_args+=(--yes)
            if workbench_cmd_add "${member}" ${returning_args[@]+"${returning_args[@]}"} ${add_args[@]+"${add_args[@]}"}; then
                _WB_ADD_STAGED="${_WB_ADD_STAGED} ${member}"
            else
                _WB_ADD_FAILED="${_WB_ADD_FAILED} ${member}"
            fi
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
