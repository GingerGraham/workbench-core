#!/usr/bin/env bash
# lib/modules/track.sh — `wb track` (ARCHITECTURE.md §9.2/§10). The single
# verb `wb dev` (lib/modules/dev.sh) wraps; returning a module to production
# is `wb track <name> --latest`, not a separate command.

# workbench_cmd_track <name> --latest | --branch <b> | --tag <t> | --commit <sha>
workbench_cmd_track() {
    local name="$1"; shift || true
    if [[ -z "${name}" ]]; then
        log_error "wb track: usage: wb track <name> --latest | --branch <b> | --tag <t> | --commit <sha>"
        return 2
    fi
    if ! workbench_is_registered "${name}"; then
        log_error "wb track: '${name}' is not registered — run 'wb add ${name}' first"
        return 1
    fi

    local new_mode="" seen=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --latest) new_mode="latest"; seen=$((seen + 1)) ;;
            --branch|--tag|--commit)
                if [[ -z "${2:-}" ]]; then
                    log_error "wb track: $1 requires a value"
                    return 2
                fi
                case "$1" in
                    --branch) new_mode="branch:$2" ;;
                    --tag)    new_mode="tag:$2" ;;
                    --commit) new_mode="commit:$2" ;;
                esac
                seen=$((seen + 1))
                shift
                ;;
            *)
                log_error "wb track: unknown argument '$1'"
                return 2
                ;;
        esac
        shift
    done

    if [[ "${seen}" -eq 0 ]]; then
        log_error "wb track: exactly one of --latest, --branch, --tag, --commit is required"
        return 2
    fi
    if [[ "${seen}" -gt 1 ]]; then
        log_error "wb track: --latest/--branch/--tag/--commit are mutually exclusive — got ${seen}"
        return 2
    fi

    local current_mode
    current_mode="$(workbench_module_conf_get "${name}" TRACK_MODE latest)"
    if [[ "${current_mode}" == "${new_mode}" ]]; then
        log_info "wb track: '${name}' is already tracking ${new_mode} — no-op"
        return 0
    fi

    workbench_module_conf_set "${name}" TRACK_MODE "${new_mode}"
    log_info "wb track: '${name}' now tracking ${new_mode} (was ${current_mode}) — syncing now..."
    workbench_sync_module "${name}" "track"
}
