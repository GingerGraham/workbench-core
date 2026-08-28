#!/usr/bin/env bash
# lib/modules/dev.sh — `wb dev [<name>]` (ARCHITECTURE.md §10/D9).
#
# A guided wrapper over `wb track`, not a separate mechanism: with no
# argument, walks every currently-registered module (core included)
# prompting keep-or-switch; with <name>, jumps straight to that module.
# Implicitly ensures sync.enabled=true for anything switched into
# branch:-tracking, since dev tracking without active sync defeats the
# purpose.
#
# Prompts read plain stdin (`read -r`), not /dev/tty like
# lib/core/functions.sh's _read_prompt — this is a top-level interactive
# CLI command a human runs directly (or a test pipes input into), unlike
# _read_prompt's provisioning-script use case where stdin may already be
# consumed by something else in the pipeline.

command -v workbench_register_script_version &>/dev/null && workbench_register_script_version "lib/modules/dev.sh" "0.1.0" || true

_wb_dev_prompt_one() {
    local name="$1" current answer

    current="$(workbench_module_conf_get "${name}" TRACK_MODE latest)"
    printf '%s (currently: %s) — keep, or switch to [b]ranch/[t]ag/[c]ommit/[l]atest? [k]: ' "${name}" "${current}"
    if ! read -r answer; then
        echo
        return 0
    fi
    answer="${answer:-k}"

    case "${answer}" in
        k|K|"")
            log_info "wb dev: '${name}' left on ${current}"
            return 0
            ;;
        b|B)
            local branch
            printf 'branch name for %s: ' "${name}"
            read -r branch
            [[ -z "${branch}" ]] && { log_warn "wb dev: no branch given — leaving '${name}' unchanged"; return 0; }
            workbench_cmd_track "${name}" --branch "${branch}"
            workbench_module_conf_set "${name}" SYNC_ENABLED true
            ;;
        t|T)
            local tag
            printf 'tag name for %s: ' "${name}"
            read -r tag
            [[ -z "${tag}" ]] && { log_warn "wb dev: no tag given — leaving '${name}' unchanged"; return 0; }
            workbench_cmd_track "${name}" --tag "${tag}"
            ;;
        c|C)
            local sha
            printf 'commit sha for %s: ' "${name}"
            read -r sha
            [[ -z "${sha}" ]] && { log_warn "wb dev: no commit given — leaving '${name}' unchanged"; return 0; }
            workbench_cmd_track "${name}" --commit "${sha}"
            ;;
        l|L)
            workbench_cmd_track "${name}" --latest
            ;;
        *)
            log_warn "wb dev: unrecognised answer '${answer}' — leaving '${name}' unchanged"
            ;;
    esac
}

# workbench_cmd_dev [<name>]
workbench_cmd_dev() {
    local name="${1:-}"

    if [[ -n "${name}" ]]; then
        if ! workbench_is_registered "${name}"; then
            log_error "wb dev: '${name}' is not registered"
            return 1
        fi
        _wb_dev_prompt_one "${name}"
        return 0
    fi

    # Collect names into an array FIRST, then iterate with a plain `for` —
    # NOT `while read m; do ...; done < <(workbench_list_registered_modules)`.
    # That pattern redirects fd 0 for the whole loop body, so
    # _wb_dev_prompt_one's own interactive `read`s would consume the
    # module-list stream instead of the real answers coming from the
    # caller's stdin (confirmed the hard way while testing this file: the
    # second module's prompt was answered with the *third* module's name).
    local -a modules=()
    local m
    while IFS= read -r m; do
        [[ -n "${m}" ]] && modules+=("${m}")
    done < <(workbench_list_registered_modules)

    for m in "${modules[@]}"; do
        _wb_dev_prompt_one "${m}"
    done
}
