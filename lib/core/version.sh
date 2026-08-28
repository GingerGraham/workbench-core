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

# ── Release/tag version (bootstrap-fix brief §5.1) ───────────────────────────
# Distinct from the contract-version functions above: this answers "which
# release of workbench-core is this checkout", not "what compatibility
# integer does it declare". Reads the single-line VERSION file at the repo
# root, relative to wherever this lib is actually running from — this file
# lives at lib/core/version.sh, so the repo root is two directories up. That
# relationship holds identically whether "wherever this lib is running from"
# is a developer's git clone or one of bootstrap.sh's/the sync engine's
# fetched tarball snapshots (both are the full repo tree, VERSION included),
# so no dev-vs-snapshot special-casing is needed here.
workbench_release_version() {
    local file="${_wb_version_lib_dir}/../../VERSION"
    if [[ -f "${file}" ]]; then
        head -n 1 "${file}"
    else
        printf 'unknown\n'
    fi
}

# ── Script-local version registry (bootstrap-fix brief §5.2) ────────────────
# Three decoupled version concepts now exist (contract / release-tag /
# script-local) — see ARCHITECTURE.md's version-concepts subsection. This
# registry is for the third: "which version of *this specific file*
# produced this output", independent of the release tag and bumped by that
# file's own author on its own schedule.
#
# A same-named `readonly` (or even plain) version variable repeated in every
# sourced file would get clobbered file-to-file when ~20 files land in one
# shell process (bin/wb) — an associative array keyed by filename is the
# obvious fix but is bash-4+-only, off the table under the bash 3.2
# constraint. Instead: a registration function appending "path|version" to a
# plain indexed array, the same pattern already established for
# _WB_SHELL_PREREQS_REQUIRED in lib/core/prereqs.sh.
#
# Guarded so re-sourcing this file (harmless and expected — e.g. a file that
# defensively sources core/version.sh for the registration helper, on top of
# bin/wb's own explicit source of it) never wipes already-registered
# entries.
[[ -n "${_WB_SCRIPT_VERSIONS+x}" ]] || _WB_SCRIPT_VERSIONS=()

# workbench_register_script_version <path> <version>
# Called once near the top of every in-scope operational file (bin/wb,
# bootstrap.sh's own inline constant excepted, lib/loader.sh, and every file
# under lib/) with that file's own repo-relative path and version. Callers
# guard the call with `command -v workbench_register_script_version
# &>/dev/null &&` so sourcing a file standalone (a test harness, a
# diagnostic script) without core/version.sh already loaded is a silent
# no-op rather than an error — this file being sourced first is only
# guaranteed inside bin/wb's own dispatch pass.
#
# Deduplicates by <path>, first registration wins: several files
# (lib/core/prereqs.sh, lib/distribution/snapshot.sh, lib/ssh/bootstrap.sh,
# lib/sync/engine.sh, ...) defensively re-source their own dependencies
# (functions.sh, semver.sh, state.sh, etc.) if not already loaded — under
# bin/wb's single dispatch pass those dependencies are already sourced once
# up front, but every one of those defensive re-sources still runs its own
# top-level code, registration line included. Without the dedup here, a
# file with N defensive re-sourcers upstream of it in bin/wb's list would
# register N+1 times — silently violating the "no duplicate/colliding
# entries after a full bin/wb source pass" guarantee tests/check-wb-
# version.sh checks for.
workbench_register_script_version() {
    local path="$1" version="$2" entry
    for entry in "${_WB_SCRIPT_VERSIONS[@]}"; do
        [[ "${entry%%|*}" == "${path}" ]] && return 0
    done
    _WB_SCRIPT_VERSIONS+=("${path}|${version}")
}

# workbench_print_script_versions
# One "  <path>  v<version>" line per registered entry, in registration
# (i.e. bin/wb's own source-order) order.
workbench_print_script_versions() {
    local entry
    for entry in "${_WB_SCRIPT_VERSIONS[@]}"; do
        printf '  %s\n' "${entry/|/  v}"
    done
}

command -v workbench_register_script_version &>/dev/null && workbench_register_script_version "lib/core/version.sh" "0.1.0" || true
