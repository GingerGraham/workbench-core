#!/usr/bin/env bash
# lib/modules/catalog.sh — known-modules catalog & bundles (ARCHITECTURE.md
# §10). Ships the *structure* in Wave B, empty of real entries until Wave C
# — `wb add <name>`/`wb install --bundle` have somewhere to resolve against
# from day one, without any hardcoded profile branching in the engine
# itself (bundles are pure sugar over repeated `wb add` calls, principle 4).
#
# On-disk format matches the hot-path dependency constraint (build brief
# §10): plain pipe-delimited text, read with the same awk/grep technique
# used throughout lib/manifest/parse.sh — no new dependency introduced for
# this.
#
#   modules.list:  <name>|<url>|<private:true|false>
#   bundles.list:  <bundle-name>|<comma-separated module names>
#
# Both are host-overridable/extensible: a machine-local
# ${XDG_CONFIG_HOME}/workbench/catalog/{modules,bundles}.list, if present,
# is read INSTEAD of (not merged with) the shipped defaults below — the
# override is total per-file, matching the "small, host-overridable"
# framing in ARCHITECTURE.md §10 without inventing a merge algorithm this
# task doesn't need yet.

_wb_catalog_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

_wb_catalog_modules_file() {
    local override="${XDG_CONFIG_HOME:-${HOME}/.config}/workbench/catalog/modules.list"
    [[ -f "${override}" ]] && { printf '%s\n' "${override}"; return 0; }
    printf '%s\n' "${_wb_catalog_lib_dir}/modules.list"
}

_wb_catalog_bundles_file() {
    local override="${XDG_CONFIG_HOME:-${HOME}/.config}/workbench/catalog/bundles.list"
    [[ -f "${override}" ]] && { printf '%s\n' "${override}"; return 0; }
    printf '%s\n' "${_wb_catalog_lib_dir}/bundles.list"
}

# workbench_catalog_lookup <name>
# Prints "<url>|<private>" for a known module name, or nothing (exit 1).
workbench_catalog_lookup() {
    local name="$1" file line n u p
    file="$(_wb_catalog_modules_file)"
    [[ -f "${file}" ]] || return 1
    while IFS='|' read -r n u p; do
        [[ -z "${n}" || "${n}" == \#* ]] && continue
        if [[ "${n}" == "${name}" ]]; then
            printf '%s|%s\n' "${u}" "${p:-false}"
            return 0
        fi
    done < "${file}"
    return 1
}

# workbench_catalog_bundle_modules <bundle-name>
# Prints the member module names, one per line, or nothing (exit 1) if the
# bundle isn't known.
workbench_catalog_bundle_modules() {
    local bundle="$1" file line n members m
    file="$(_wb_catalog_bundles_file)"
    [[ -f "${file}" ]] || return 1
    while IFS='|' read -r n members; do
        [[ -z "${n}" || "${n}" == \#* ]] && continue
        if [[ "${n}" == "${bundle}" ]]; then
            printf '%s\n' "${members}" | tr ',' '\n'
            return 0
        fi
    done < "${file}"
    return 1
}
