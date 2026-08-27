#!/usr/bin/env bash
# lib/core/version.sh — read/write the version taxonomy file
# (ARCHITECTURE.md §6): CORE_API_VERSION, MANIFEST_SCHEMA_VERSION,
# STATE_SCHEMA_VERSION, WORKBENCH_CORE_SEMVER.
#
# Deliberately readable with only `grep`/`cut` (both hard baseline prereqs,
# unlike `awk`) — a module or a diagnostic script that needs to check the
# Core API version before anything else is loaded shouldn't have to source
# this file at all, just grep the plain KEY=VALUE file directly. These
# functions exist for convenience, not as the only supported access path.

_wb_version_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

workbench_version_file_path() {
    printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}/workbench/core/version"
}

# workbench_ensure_version_file
# Writes the default version file if one does not already exist. Never
# overwrites an existing file — upgrades to individual version integers are
# a deliberate, explicit act (a future `wb` migration path), not something
# this function silently performs.
workbench_ensure_version_file() {
    local file
    file="$(workbench_version_file_path)"
    [[ -f "${file}" ]] && return 0

    mkdir -p "$(dirname "${file}")"
    if [[ -f "${_wb_version_lib_dir}/version-defaults.conf" ]]; then
        cp "${_wb_version_lib_dir}/version-defaults.conf" "${file}"
    else
        cat > "${file}" <<'EOF'
CORE_API_VERSION=1
MANIFEST_SCHEMA_VERSION=1
STATE_SCHEMA_VERSION=1
WORKBENCH_CORE_SEMVER=0.1.0
EOF
    fi
    log_info "workbench: wrote default version file to ${file}"
}

# workbench_read_version_var <NAME>
# Prints the value of NAME from the version file, or nothing (exit 1) if the
# file or the key is absent. Last matching line wins, matching plain
# KEY=VALUE shell-source semantics.
workbench_read_version_var() {
    local name="$1" file
    file="$(workbench_version_file_path)"
    [[ -f "${file}" ]] || return 1
    grep -E "^${name}=" "${file}" | tail -n 1 | cut -d= -f2-
}

workbench_core_api_version()      { workbench_read_version_var CORE_API_VERSION; }
workbench_manifest_schema_version() { workbench_read_version_var MANIFEST_SCHEMA_VERSION; }
workbench_state_schema_version()  { workbench_read_version_var STATE_SCHEMA_VERSION; }
workbench_core_semver()           { workbench_read_version_var WORKBENCH_CORE_SEMVER; }
