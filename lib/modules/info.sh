#!/usr/bin/env bash
# lib/modules/info.sh — `wb module info` / `wb module docs`
# (ARCHITECTURE.md §12 D45).
#
# The rendering commands (_wb_cmd_module_info/_wb_cmd_module_docs) live in
# bin/wb, same split as `wb tools`: this file holds only the one reusable
# primitive that isn't CLI-output formatting — resolving which docs file
# (if any) a module publishes.

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/modules/info.sh" "0.2.0" || true

# workbench_module_docs_path <name>
# Prints the absolute path of whichever of HELP.md/README.md exists at
# the module's current/ root, in that order, and returns 0. Returns 1
# with no output if neither exists — convention-only, no manifest field,
# no further fallback chain (ARCHITECTURE.md §12 D45).
workbench_module_docs_path() {
    local name="$1"
    local current_dir
    current_dir="$(workbench_module_current_dir "${name}")"

    local candidate
    for candidate in HELP.md README.md; do
        if [[ -f "${current_dir}/${candidate}" ]]; then
            printf '%s\n' "${current_dir}/${candidate}"
            return 0
        fi
    done
    return 1
}
