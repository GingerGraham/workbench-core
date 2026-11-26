#!/usr/bin/env bash
# lib/modules/info.sh — `wb module info` / `wb module docs`
# (docs/decisions-log.md D45).
#
# The rendering commands (_wb_cmd_module_info/_wb_cmd_module_docs) live in
# bin/wb, same split as `wb tools`: this file holds only the reusable
# primitives that aren't CLI-output formatting — resolving which docs file
# (if any) a module publishes, and its docs/<topic>.md topics (D132).

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/modules/info.sh" "0.2.0" || true

# workbench_module_docs_path <name>
# Prints the absolute path of whichever of HELP.md/README.md exists at
# the module's current/ root, in that order, and returns 0. Returns 1
# with no output if neither exists — convention-only, no manifest field,
# no further fallback chain (docs/decisions-log.md D45).
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

# workbench_module_doc_topics <name>
# The module's docs/<topic>.md files, as topic names, one per line, sorted.
# Only names 'wb module docs <name> <topic>' accepts are listed: lowercase
# letters, digits and -, starting with a letter or digit (D132).
workbench_module_doc_topics() {
    local dir
    dir="$(workbench_module_current_dir "$1")/docs"
    [[ -d "${dir}" ]] || return 0
    find "${dir}" -mindepth 1 -maxdepth 1 -type f -name '*.md' 2>/dev/null \
        | sed 's#.*/##; s#\.md$##' \
        | grep -E '^[a-z0-9][a-z0-9-]*$' \
        | sort
}

# workbench_module_doc_topic_path <name> <topic>
# Prints the absolute path of the module's docs/<topic>.md and returns 0.
# Returns 1 with no output for a name outside the topic rule (so no path
# can leave docs/) or a file that isn't there (D132).
workbench_module_doc_topic_path() {
    local name="$1" topic="$2" file
    case "${topic}" in
        ''|[!abcdefghijklmnopqrstuvwxyz0123456789]*) return 1 ;;
        *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
    esac
    file="$(workbench_module_current_dir "${name}")/docs/${topic}.md"
    [[ -f "${file}" ]] || return 1
    printf '%s\n' "${file}"
}
