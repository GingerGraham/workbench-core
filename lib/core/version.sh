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

_workbench_version_file_path() {
    printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}/workbench/core/version"
}

# _workbench_ensure_version_file
# Writes the default version file if one does not already exist. Never
# overwrites an existing file — upgrades to individual version integers are
# a deliberate, explicit act (a future `wb` migration path), not something
# this function silently performs.
_workbench_ensure_version_file() {
    local file
    file="$(_workbench_version_file_path)"
    [[ -f "${file}" ]] && return 0

    mkdir -p "$(dirname "${file}")"
    if [[ -f "${_wb_version_lib_dir}/version-defaults.conf" ]]; then
        cp "${_wb_version_lib_dir}/version-defaults.conf" "${file}"
    else
        cat > "${file}" <<'EOF'
CORE_API_VERSION=1
MANIFEST_SCHEMA_VERSION=1
STATE_SCHEMA_VERSION=2
WORKBENCH_CORE_SEMVER=0.1.0
EOF
    fi
    log_info "workbench: wrote default version file to ${file}"
}

# _workbench_read_version_var <NAME>
# Prints the value of NAME from the version file, or nothing (exit 1) if the
# file or the key is absent. Last matching line wins, matching plain
# KEY=VALUE shell-source semantics.
_workbench_read_version_var() {
    local name="$1" file
    file="$(_workbench_version_file_path)"
    [[ -f "${file}" ]] || return 1
    grep -E "^${name}=" "${file}" | tail -n 1 | cut -d= -f2-
}

_workbench_core_api_version()      { _workbench_read_version_var CORE_API_VERSION; }
_workbench_manifest_schema_version() { _workbench_read_version_var MANIFEST_SCHEMA_VERSION; }
_workbench_state_schema_version()  { _workbench_read_version_var STATE_SCHEMA_VERSION; }
_workbench_core_semver()           { _workbench_read_version_var WORKBENCH_CORE_SEMVER; }

# _workbench_version_set_var <NAME> <value>
# Idempotent single-key update of the version file, same discipline as
# workbench_module_conf_set (lib/sync/state.sh) for sync.conf — rewrites
# NAME=value in place, leaving every other assignment untouched, and
# appends it if the key is missing entirely (e.g. a hand-edited or
# otherwise corrupted version file that dropped a line) rather than
# silently leaving it unset — the same fallback
# workbench_module_conf_set already has, without which a caller like
# _workbench_migrate_state_schema could re-attempt the same "migration"
# forever without it ever actually taking.
_workbench_version_set_var() {
    local name="$1" value="$2" file tmp
    file="$(_workbench_version_file_path)"
    [[ -f "${file}" ]] || return 1

    if grep -q "^${name}=" "${file}" 2>/dev/null; then
        tmp="$(mktemp "${file}.XXXXXX")"
        awk -v var="${name}" -v val="${value}" '
            BEGIN { key = var "=" }
            index($0, key) == 1 { print var "=" val; next }
            { print }
        ' "${file}" > "${tmp}"
        mv "${tmp}" "${file}"
    else
        printf '%s=%s\n' "${name}" "${value}" >> "${file}"
    fi
}

# ── STATE_SCHEMA_VERSION migration ───────────────────────────────────────────
# The current on-disk state shape's version — bump this alongside a new
# migration step below whenever contracts/state-schema.md's shape changes,
# per §6's "bump when this shape changes in a way that needs migration."
_WB_STATE_SCHEMA_VERSION_CURRENT=2

# _workbench_migrate_state_schema
# Brings an existing version file's STATE_SCHEMA_VERSION up to
# _WB_STATE_SCHEMA_VERSION_CURRENT in place. Called from `wb install`/`wb
# apply`, after _workbench_ensure_version_file (which only ever writes the
# file if one doesn't exist yet — this is what advances an existing one).
# No-op if the file doesn't exist yet (_workbench_ensure_version_file's job)
# or is already current. Migration steps are purely additive so far (new
# state files, never a changed/removed shape) — nothing here rewrites or
# deletes any existing per-module state.
_workbench_migrate_state_schema() {
    local file current
    file="$(_workbench_version_file_path)"
    [[ -f "${file}" ]] || return 0

    current="$(_workbench_state_schema_version)"
    [[ -z "${current}" ]] && current=1
    [[ "${current}" -ge "${_WB_STATE_SCHEMA_VERSION_CURRENT}" ]] && return 0

    if [[ "${current}" -lt 2 ]]; then
        log_info "workbench: migrating STATE_SCHEMA_VERSION 1 -> 2 (installers.list added — additive, no existing state touched)"
    fi
    _workbench_version_set_var STATE_SCHEMA_VERSION "${_WB_STATE_SCHEMA_VERSION_CURRENT}"
}

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
_workbench_release_version() {
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

# _workbench_register_script_version <path> <version>
# Called once near the top of every in-scope operational file (bin/wb,
# bootstrap.sh's own inline constant excepted, lib/loader.sh, and every file
# under lib/) with that file's own repo-relative path and version. Callers
# guard the call with `command -v _workbench_register_script_version
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
#
# The `${_WB_SCRIPT_VERSIONS[@]+"${_WB_SCRIPT_VERSIONS[@]}"}` expansion
# below (both loops) is deliberate, not decorative: on bash < 4.4 —
# includes bash 3.2, a platform this codebase explicitly commits to —
# expanding an EMPTY array as plain `"${arr[@]}"` under `set -u` (`bin/wb`
# runs `set -uo pipefail`) raises "unbound variable" and aborts the shell.
# The very first call to this function (from this file's own bottom-line
# self-registration, before any entry exists yet) hits exactly that empty-
# array case, so a plain `"${arr[@]}"` here would break every `wb` command
# at startup on bash 3.2. `${arr[@]+word}` only substitutes `word` when the
# array has at least one element, so an empty array correctly expands to
# nothing instead of triggering nounset. CI runs bash 4+ and would not have
# caught this.
_workbench_register_script_version() {
    local path="$1" version="$2" entry
    for entry in "${_WB_SCRIPT_VERSIONS[@]+"${_WB_SCRIPT_VERSIONS[@]}"}"; do
        [[ "${entry%%|*}" == "${path}" ]] && return 0
    done
    _WB_SCRIPT_VERSIONS+=("${path}|${version}")
}

# _workbench_print_script_versions
# One "  <path>  v<version>" line per registered entry, in registration
# (i.e. bin/wb's own source-order) order. Same bash-3.2-safe empty-array
# expansion as _workbench_register_script_version above — not a live
# failure today (only ever called with a populated array), but the same
# latent hazard if that ever changes.
_workbench_print_script_versions() {
    local entry
    for entry in "${_WB_SCRIPT_VERSIONS[@]+"${_WB_SCRIPT_VERSIONS[@]}"}"; do
        printf '  %s\n' "${entry/|/  v}"
    done
}

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/core/version.sh" "0.1.0" || true
