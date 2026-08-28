#!/usr/bin/env bash
# lib/modules/track.sh — `wb track` (ARCHITECTURE.md §9.2/§10). The single
# verb `wb dev` (lib/modules/dev.sh) wraps; returning a module to production
# is `wb track <name> --latest`, not a separate command.

command -v workbench_register_script_version &>/dev/null && workbench_register_script_version "lib/modules/track.sh" "0.1.0" || true

# _wb_track_ref_is_safe <value>
# TRACK_REF ends up written verbatim into sync.conf (a line-based
# KEY=VALUE file) and, for `latest`/`branch:`, into a snapshot directory
# name (_wb_slugify already makes that half filesystem-safe, but sync.conf
# itself has no such sanitising). Reject anything containing whitespace or
# control characters before it's ever written, rather than trusting every
# caller (a human typing `wb track`, or a future scripted caller) to have
# already done so.
_wb_track_ref_is_safe() {
    local v="$1"
    [[ -z "${v}" ]] && return 1
    case "${v}" in
        *[$' \t\n\r']*) return 1 ;;
    esac
    # Reject any other C0 control character (bytes 0x01-0x08, 0x0B-0x1F,
    # 0x7F) via LC_ALL=C so this is a byte-range check, not locale-dependent.
    if LC_ALL=C grep -q '[[:cntrl:]]' <<< "${v}"; then
        return 1
    fi
    return 0
}

# _wb_track_commit_is_safe <value>
# --commit must look like a git sha: 7-40 lowercase hex characters (git's
# minimum unambiguous abbreviation up to a full sha-1/sha-256 hex digest).
_wb_track_commit_is_safe() {
    local v="$1"
    case "${v}" in
        *[!0-9a-fA-F]*) return 1 ;;
        '') return 1 ;;
    esac
    local len="${#v}"
    [[ "${len}" -ge 7 && "${len}" -le 40 ]]
}

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
                if ! _wb_track_ref_is_safe "$2"; then
                    log_error "wb track: $1 value must not contain whitespace or control characters: '$2'"
                    return 2
                fi
                case "$1" in
                    --branch) new_mode="branch:$2" ;;
                    --tag)    new_mode="tag:$2" ;;
                    --commit)
                        if ! _wb_track_commit_is_safe "$2"; then
                            log_error "wb track: --commit must be a 7-40 character hex sha — got '$2'"
                            return 2
                        fi
                        new_mode="commit:$2"
                        ;;
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
