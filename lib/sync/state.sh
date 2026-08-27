#!/usr/bin/env bash
# lib/sync/state.sh — module state directory layout & sync.conf access
# (ARCHITECTURE.md §9.3/§9.5).
#
# Single root, replacing dotfiles' scattered ~/.config/dotfiles,
# ~/.config/shell, ~/.config/external-sync, etc.:
#
#   ${XDG_DATA_HOME}/workbench/modules/<name>/
#   ├── sync.conf                  TRACK_MODE, TRACK_REF, RESOLVED_SHA,
#   │                               SYNC_ENABLED, REGISTERED
#   ├── snapshots/<ref-slug>-<shortsha>/   immutable, one dir per fetch
#   ├── current -> snapshots/<ref-slug>-<shortsha>
#   └── deploy.list / register.list / hooks.list / manifest-hash / last-sync
#
# Core occupies <name> = core — no special-cased directory shape (principle
# 4: core is "module zero").
#
# This file owns the *shape* (paths, sync.conf read/write, module
# enumeration) that both the loader (lib/loader.sh) and the sync engine
# (lib/sync/engine.sh) build on — kept as one shared implementation so
# "what does 'registered' mean" is answered in exactly one place.

_wb_state_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

workbench_modules_dir() {
    printf '%s\n' "${WORKBENCH_MODULES_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/workbench/modules}"
}

workbench_module_dir() {
    printf '%s\n' "$(workbench_modules_dir)/$1"
}

workbench_module_conf_path() {
    printf '%s\n' "$(workbench_module_dir "$1")/sync.conf"
}

workbench_module_current_dir() {
    printf '%s\n' "$(workbench_module_dir "$1")/current"
}

# workbench_module_conf_get <name> <VAR> [default]
# Reads one KEY from a module's sync.conf without polluting the caller's
# environment (sourced in a subshell). Prints [default] (or nothing) if the
# module, its sync.conf, or the key is absent.
workbench_module_conf_get() {
    local name="$1" var="$2" default="${3:-}"
    local conf
    conf="$(workbench_module_conf_path "${name}")"
    [[ -f "${conf}" ]] || { printf '%s\n' "${default}"; return 0; }
    (
        # shellcheck disable=SC1090
        source "${conf}"
        eval "printf '%s\n' \"\${${var}:-${default}}\""
    )
}

# workbench_module_conf_set <name> <VAR> <value>
# Idempotent single-key update: rewrites sync.conf with VAR=value, leaving
# every other assignment as-is. Creates the file (and module dir) if absent.
workbench_module_conf_set() {
    local name="$1" var="$2" value="$3"
    local dir conf
    dir="$(workbench_module_dir "${name}")"
    conf="$(workbench_module_conf_path "${name}")"
    mkdir -p "${dir}"

    if [[ -f "${conf}" ]] && grep -q "^${var}=" "${conf}" 2>/dev/null; then
        local tmp
        tmp="$(mktemp "${conf}.XXXXXX")"
        awk -v var="${var}" -v val="${value}" '
            BEGIN { key = var "=" }
            index($0, key) == 1 { print var "=" val; next }
            { print }
        ' "${conf}" > "${tmp}"
        mv "${tmp}" "${conf}"
    else
        printf '%s=%s\n' "${var}" "${value}" >> "${conf}"
    fi
}

# workbench_is_registered <name>
# True iff this module has ever been registered and has not been removed.
# REGISTERED defaults to "true" the moment sync.conf exists at all — wb add
# writes it explicitly; wb remove flips it to "false" without deleting
# anything (idempotent, non-destructive deregistration — ARCHITECTURE.md
# §10/build brief Phase 7).
workbench_is_registered() {
    local name="$1"
    local conf
    conf="$(workbench_module_conf_path "${name}")"
    [[ -f "${conf}" ]] || return 1
    [[ "$(workbench_module_conf_get "${name}" REGISTERED true)" == "true" ]]
}

# workbench_is_sync_enabled <name>
# Independent of TRACK_MODE/TRACK_REF (ARCHITECTURE.md §9.7) — defaults to
# true.
workbench_is_sync_enabled() {
    local name="$1"
    [[ "$(workbench_module_conf_get "${name}" SYNC_ENABLED true)" == "true" ]]
}

# workbench_list_all_modules
# Every module directory under the modules root that has a sync.conf, i.e.
# has been added at least once — registered or not, sync-enabled or not.
# One name per line, sorted for determinism.
workbench_list_all_modules() {
    local root d name
    root="$(workbench_modules_dir)"
    [[ -d "${root}" ]] || return 0
    for d in "${root}"/*/; do
        [[ -d "${d}" ]] || continue
        name="$(basename "${d}")"
        [[ -f "${d}sync.conf" ]] && printf '%s\n' "${name}"
    done | sort
}

# workbench_list_registered_modules
# Subset of workbench_list_all_modules that is currently REGISTERED=true.
workbench_list_registered_modules() {
    local name
    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        workbench_is_registered "${name}" && printf '%s\n' "${name}"
    done < <(workbench_list_all_modules)
}

# workbench_list_loadable_modules
# The set the loader actually sources from: registered AND sync-enabled.
# (ARCHITECTURE.md §3 — "every registered, sync-enabled module's state
# directory.") A module with sync paused via `wb sync disable <name>` is
# frozen at its last-deployed snapshot and its register.list is not
# re-sourced into new shells until sync is re-enabled; this is a deliberate
# choice, not an oversight — see contracts/state-schema.md.
workbench_list_loadable_modules() {
    local name
    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        workbench_is_sync_enabled "${name}" && printf '%s\n' "${name}"
    done < <(workbench_list_registered_modules)
}
