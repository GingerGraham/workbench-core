#!/usr/bin/env bash
# lib/loader-select.sh — shared platform/distro filename-selector.
#
# Extracted out of lib/loader.sh so bin/wb's `wb functions` can apply the
# exact same "would the loader actually source this file" logic when
# deciding what counts as loaded, instead of a second, drifting copy.
# Sourced by lib/loader.sh (the real, side-effecting loader) and by bin/wb
# (which never sources module content itself, only asks "would it be
# sourced").

command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/loader-select.sh" "0.1.0" || true

# _wb_loader_should_source_by_name <tier> <basename-without-.sh>
# Filename-as-selector convention for the platform/distro tiers only (every
# other tier sources everything registered for it unconditionally): a
# distro-tier file only loads on a matching WORKBENCH_DISTRO; a
# platform-tier file loads on a matching WORKBENCH_OS (lowercased: Mac ->
# macos) or the literal "wsl" additionally when WORKBENCH_WSL=true.
_wb_loader_should_source_by_name() {
    local tier="$1" base="$2"
    case "${tier}" in
        distro)
            [[ "${base}" == "${WORKBENCH_DISTRO}" ]]
            ;;
        platform)
            local os_name
            case "${WORKBENCH_OS}" in
                Linux) os_name="linux" ;;
                Mac)   os_name="macos" ;;
                *)     os_name="${WORKBENCH_OS}" ;;
            esac
            if [[ "${base}" == "${os_name}" ]]; then
                return 0
            fi
            if [[ "${base}" == "wsl" && "${WORKBENCH_WSL}" == "true" ]]; then
                return 0
            fi
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}
