#!/usr/bin/env bash
# lib/core/tools.sh — the tool-updating framework's discovery/consumption
# half (ARCHITECTURE.md §12 D23, baseline-completion brief §Phase 3).
#
# `register.installers[].src` was declared, parsed, and validated from Wave
# B onward but nothing ever consumed it at runtime — this is that consumer.
# Rendering each module's installers.list (workbench_render_installers_list)
# lives in lib/sync/engine.sh, right alongside workbench_render_register_list,
# since it runs at exactly the same point in the sync/convergence cycle.
# This file owns turning the resulting per-module installers.list files into
# one aggregated, de-duplicated registry that `wb tools` consumes.
#
# Core has no idea how any individual tool is installed, checked, or
# updated — it only discovers and invokes install-* functions a module
# declares, exactly the way register.getters[]/get-functions already works
# (principle 4: core provides the mechanism, modules provide the content).

_wb_tools_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
command -v workbench_register_script_version &>/dev/null && workbench_register_script_version "lib/core/tools.sh" "0.1.0" || true

# workbench_tools_collect
# Emits one line per discovered installer, across every loadable
# (registered AND sync-enabled) module, AFTER de-duplication by friendly
# name: module|abs_path|function|friendly.
#
# Collisions (two modules declaring the same install-<name> function) are
# resolved by first-encountered-wins — modules are walked in the same
# module-name sort order workbench_list_loadable_modules already returns,
# so "first" here means "first alphabetically by module name," the same
# tie-break convention the loader's tier-sourcing already uses. Each
# collision is warned about exactly once.
#
# Tracks what's already been seen as a newline-delimited "friendly|owner"
# string rather than a bash array — friendly names are restricted to
# [a-zA-Z0-9_-] by _extract_function_names' own pattern, so a plain grep
# match is safe, and this sidesteps the empty-array-under-`set -u` hazard
# documented in lib/core/version.sh for bash 3.2.
workbench_tools_collect() {
    local name instlist abs_path func friendly
    local seen="" already

    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        instlist="$(workbench_module_dir "${name}")/installers.list"
        [[ -f "${instlist}" ]] || continue

        while IFS='|' read -r abs_path func friendly; do
            [[ -z "${friendly}" ]] && continue

            already="$(printf '%s\n' "${seen}" | grep "^${friendly}|" | head -n 1 | cut -d'|' -f2)"
            if [[ -n "${already}" ]]; then
                log_warn "wb tools: '${friendly}' is declared by both '${already}' and '${name}' — '${already}' wins (first by module-name order); rename one of the two install-${friendly} functions to resolve this."
                continue
            fi

            seen="${seen}
${friendly}|${name}"
            printf '%s|%s|%s|%s\n' "${name}" "${abs_path}" "${func}" "${friendly}"
        done < "${instlist}"
    done < <(workbench_list_loadable_modules)
}

# workbench_tools_lookup <friendly-name>
# Prints "<module>|<abs_path>|<function>" for exactly one discovered,
# de-duplicated installer, or nothing (exit 1) if no such tool exists.
workbench_tools_lookup() {
    local target="$1"
    local name abs_path func friendly

    while IFS='|' read -r name abs_path func friendly; do
        [[ "${friendly}" == "${target}" ]] || continue
        printf '%s|%s|%s\n' "${name}" "${abs_path}" "${func}"
        return 0
    done < <(workbench_tools_collect)
    return 1
}
