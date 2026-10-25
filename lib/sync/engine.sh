#!/usr/bin/env bash
# lib/sync/engine.sh — the unified sync loop (docs/architecture.md §9, principle
# 4). Core syncs itself through the exact same code path as any other
# module — no special-cased branch for module zero anywhere in this file.
#
# Per-module cycle: resolve the tracked ref to a commit (cheap — API lookup
# or `git ls-remote`, never a full fetch just to check), compare against
# what's already deployed, and only perform the full fetch + snapshot swap
# + deploy + hooks when the resolved commit actually changed. One module's
# failure at any stage is logged and never aborts any other module's sync —
# generalised from workbench-precursor's scripts/external-sync.sh, which
# already guaranteed this for its own narrower scope.

# distribution/{resolve,fetch-tarball,fetch-git-snapshot,snapshot}.sh are
# deliberately NOT in this eager dependency block (docs/decisions-log.md
# D65) — they're the heaviest, least-often-needed files this codebase has,
# and this file is in bin/wb's always-load list, so unconditionally
# sourcing them here would source them on every single `wb` invocation,
# including `wb __complete`/`wb functions`, exactly the cost Fix 3 exists
# to remove. workbench_sync_module (the only place in this file that
# actually needs them) sources them itself, lazily, the moment a real
# sync runs — see its own comment.
_wb_engine_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
for _wb_engine_dep in \
    "${_wb_engine_lib_dir}/../core/log.sh" \
    "${_wb_engine_lib_dir}/../core/functions.sh" \
    "${_wb_engine_lib_dir}/../core/semver.sh" \
    "${_wb_engine_lib_dir}/../core/version.sh" \
    "${_wb_engine_lib_dir}/../manifest/parse.sh" \
    "${_wb_engine_lib_dir}/state.sh"; do
    # shellcheck disable=SC1090
    [[ -f "${_wb_engine_dep}" ]] && source "${_wb_engine_dep}"
done
unset _wb_engine_dep

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/sync/engine.sh" "0.7.0" || true

# ── Cadence (docs/architecture.md §9.4/D8) ─────────────────────────────────────────
: "${WORKBENCH_CADENCE_DEFAULT_SECONDS:=604800}"   # weekly
: "${WORKBENCH_CADENCE_FAST_SECONDS:=300}"          # 5 minutes, any branch: module

# workbench_cadence_seconds
# One shared interval, computed fresh every call — not a value stored
# anywhere, so nothing ever needs to "re-fire" an OS-level timer when
# tracking state changes (see lib/sync/engine.sh's own OS-timer note below
# and contracts/tracking-spec.md §Cadence). Fast whenever ANY registered
# module (core included) is currently branch:-tracked.
workbench_cadence_seconds() {
    local name mode
    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        mode="$(workbench_module_conf_get "${name}" TRACK_MODE latest)"
        case "${mode}" in
            branch:*) printf '%s\n' "${WORKBENCH_CADENCE_FAST_SECONDS}"; return 0 ;;
        esac
    done < <(workbench_list_registered_modules)
    printf '%s\n' "${WORKBENCH_CADENCE_DEFAULT_SECONDS}"
}

# workbench_cadence_last_run_path
_wb_cadence_state_file() {
    printf '%s\n' "${XDG_DATA_HOME:-${HOME}/.local/share}/workbench/last-cadence-run"
}

# workbench_sync_due
# True iff enough time has elapsed since the last cadence-driven run for the
# CURRENT interval (which may have changed since that last run — always
# re-read fresh, never cached). This is what makes the "single shared
# timer" dynamic without ever touching the OS scheduler: the design here is
# a fixed, short-interval OS-level timer (systemd OnCalendar=*:0/5 /
# launchd StartInterval=300 — see lib/sync/scheduler.sh) that invokes `wb sync run-if-due` every 5 minutes
# unconditionally; THIS function is what decides, in userspace, whether that
# firing should actually do anything. Reconfiguring a live systemd timer's
# own interval requires a daemon-reload and timer restart, which is
# exactly the "restart of the timer infrastructure" docs/architecture.md §9.4
# says to avoid — polling cheaply and self-throttling sidesteps that
# entirely, at the cost of the OS timer firing (as a fast no-op check) more
# often than the content actually needs to be re-checked.
workbench_sync_due() {
    local state_file interval last now
    state_file="$(_wb_cadence_state_file)"
    interval="$(workbench_cadence_seconds)"
    now="$(date +%s)"
    if [[ ! -f "${state_file}" ]]; then
        return 0
    fi
    last="$(cat "${state_file}" 2>/dev/null || echo 0)"
    [[ "${last}" =~ ^[0-9]+$ ]] || last=0
    (( now - last >= interval ))
}

workbench_cadence_mark_ran() {
    local state_file
    state_file="$(_wb_cadence_state_file)"
    mkdir -p "$(dirname "${state_file}")"
    date +%s > "${state_file}"
}

# ── Release cooldown and adoption log (security review H3 tier 2; D77) ──────
# _wb_release_cooldown_days
# RELEASE_COOLDOWN_DAYS from scheduler.conf, read as data (never sourced).
# Default 3; 0 disables; anything non-numeric falls back to the default.
_wb_release_cooldown_days() {
    local file value=""
    file="${XDG_CONFIG_HOME:-${HOME}/.config}/workbench/core/scheduler.conf"
    [[ -f "${file}" ]] && value="$(grep -E '^RELEASE_COOLDOWN_DAYS=' "${file}" 2>/dev/null | tail -n 1 | cut -d= -f2-)"
    case "${value}" in
        ''|*[!0-9]*) value=3 ;;
    esac
    printf '%s\n' "${value}"
}

# _wb_adoption_log_event <event> <module> <old_sha> <new_sha> <ref> <reason>
# Append-only record of what this host adopted and ran, and when. Never fatal.
_wb_adoption_log_event() {
    local log_file="${XDG_DATA_HOME:-${HOME}/.local/share}/workbench/adoption.log"
    mkdir -p "$(dirname "${log_file}")" 2>/dev/null || return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${3:-none}" "${4:-none}" "${5:-}" "${6:-}" \
        >> "${log_file}" 2>/dev/null || true
}

# ── Track-mode parsing ────────────────────────────────────────────────────────
# workbench_track_mode_parts <TRACK_MODE_VALUE>
# Prints "<ref-form> <ref-value>" — ref-form one of latest|branch|tag|commit.
# "latest" has no ref-value yet (resolved fresh every cycle); the others
# carry it after the ':'.
workbench_track_mode_parts() {
    local mode="$1"
    case "${mode}" in
        latest)       printf 'latest \n' ;;
        branch:*)     printf 'branch %s\n' "${mode#branch:}" ;;
        tag:*)        printf 'tag %s\n' "${mode#tag:}" ;;
        commit:*)     printf 'commit %s\n' "${mode#commit:}" ;;
        *)            printf 'latest \n' ;;
    esac
}

# ── Per-module resolve ────────────────────────────────────────────────────────
# workbench_resolve_module <name>
# Prints "<tag-or-ref-label>|<sha>" on success. Uses the GitHub API for a
# public repo on latest/tag/commit, `git ls-remote` for a private repo (any
# mode) or ANY branch:-tracked repo — docs/architecture.md §9.1.
workbench_resolve_module() {
    local name="$1"
    local url private mode ref_form ref_value
    url="$(workbench_module_conf_get "${name}" REPO_URL "")"
    private="$(workbench_module_conf_get "${name}" PRIVATE false)"
    mode="$(workbench_module_conf_get "${name}" TRACK_MODE latest)"
    [[ -z "${url}" ]] && { log_warn "workbench_resolve_module: ${name}: no REPO_URL in sync.conf"; return 1; }
    workbench_valid_repo_url "${url}" || { log_warn "workbench_resolve_module: ${name}: REPO_URL '${url}' fails validation — skipping"; return 1; }

    read -r ref_form ref_value < <(workbench_track_mode_parts "${mode}")

    if [[ "${private}" == "true" || "${ref_form}" == "branch" ]]; then
        case "${ref_form}" in
            latest) workbench_resolve_latest_tag_ls_remote "${url}" ;;
            branch) local sha; sha="$(workbench_resolve_branch_ls_remote "${url}" "${ref_value}")"
                    [[ -n "${sha}" ]] && printf '%s|%s\n' "branch:${ref_value}" "${sha}" ;;
            tag)    local sha; sha="$(workbench_resolve_tag_ls_remote "${url}" "${ref_value}")"
                    [[ -n "${sha}" ]] && printf '%s|%s\n' "${ref_value}" "${sha}" ;;
            commit) printf '%s|%s\n' "${ref_value}" "${ref_value}" ;;
        esac
    else
        local owner repo
        read -r owner repo < <(workbench_parse_github_url "${url}") || {
            log_warn "workbench_resolve_module: ${name}: REPO_URL '${url}' is not a GitHub URL — public-repo resolution requires GitHub"
            return 1
        }
        case "${ref_form}" in
            latest) workbench_resolve_latest_tag_public "${owner}" "${repo}" ;;
            tag)    local sha; sha="$(workbench_resolve_tag_public "${owner}" "${repo}" "${ref_value}")"
                    [[ -n "${sha}" ]] && printf '%s|%s\n' "${ref_value}" "${sha}" ;;
            commit) local sha; sha="$(workbench_resolve_commit_public "${owner}" "${repo}" "${ref_value}")"
                    [[ -n "${sha}" ]] && printf '%s|%s\n' "${ref_value}" "${sha}" ;;
        esac
    fi
}

# ── Deploy (ported/generalised from external-sync.sh) ────────────────────────
_wb_expand_dest() {
    local d="$1"
    printf '%s\n' "${d/#\~/${HOME}}"
}

# _wb_backup_path_new <path> [<module>]
# Prints a fresh, unused path under the backup root for a backup of <path>,
# creating its parent directory:
#   ${XDG_DATA_HOME}/workbench/backups/<YYYY-MM-DD>/<HH00>/<module>-<basename>.<HHMMSS>[.<n>]
# The one naming scheme for every backup — workbench_backup_existing_file
# copies to it; lib/files/lifecycle.sh (D81) moves things to it when the
# user asks core to put their own config aside.
_wb_backup_path_new() {
    local dest="$1" module="${2:-}"
    local backup_root="${XDG_DATA_HOME:-${HOME}/.local/share}/workbench/backups"
    local backup_dir backup_base backup_path n=2
    backup_dir="${backup_root}/$(date +%Y-%m-%d)/$(date +%H00)"
    backup_base="${module:+${module}-}$(basename "${dest}").$(date +%H%M%S)"
    backup_path="${backup_dir}/${backup_base}"

    # Same-second collision inside one hour bucket — unlikely at the volume
    # this exists for, but a counter suffix is nearly free and beats silently
    # clobbering an earlier backup.
    while [[ -e "${backup_path}" || -L "${backup_path}" ]]; do
        backup_path="${backup_dir}/${backup_base}.${n}"
        n=$((n + 1))
    done
    mkdir -p "${backup_dir}" || return 1
    printf '%s\n' "${backup_path}"
}

# workbench_backup_existing_file <dest> [<module>]
# Copies whatever currently exists at <dest> into the backup root before
# core replaces or removes it (docs/decisions-log.md D53, D81). A real file
# or a real directory is handled identically — cp -a copies either.
#
# No-ops (returns 0) when dest doesn't exist or is a symlink. A symlink at a
# dest core is about to replace is either core's own link (nothing to
# keep) or one the user made — and lib/files/lifecycle.sh never replaces
# one of those with this function: it moves it aside whole instead
# (_wb_backup_path_new + mv), so the link itself is what's kept.
#
# A failed backup aborts the caller's overwrite (non-zero return) rather
# than proceeding unprotected: a backup that silently didn't happen is a
# worse outcome than refusing the whole operation and saying so.
#
# Sets WB_LAST_BACKUP_PATH (empty when nothing was backed up) — a global,
# not stdout, because every caller runs this in the current shell and must
# keep seeing only the log line. lib/files/lifecycle.sh records it as an
# entry's pre-workbench "original".
workbench_backup_existing_file() {
    local dest="$1" module="${2:-}" backup_path
    # shellcheck disable=SC2034  # read by lib/files/lifecycle.sh
    WB_LAST_BACKUP_PATH=""
    [[ -e "${dest}" ]] || return 0
    [[ -L "${dest}" ]] && return 0

    backup_path="$(_wb_backup_path_new "${dest}" "${module}")" || {
        log_error "  failed to create a backup location for ${dest} — leaving it in place, not proceeding"
        return 1
    }
    if cp -a "${dest}" "${backup_path}"; then
        # shellcheck disable=SC2034  # read by lib/files/lifecycle.sh
        WB_LAST_BACKUP_PATH="${backup_path}"
        log_info "  backed up existing ${dest} -> ${backup_path}"
    else
        log_error "  failed to back up ${dest} before overwrite — leaving it in place, not proceeding"
        return 1
    fi
}

# workbench_deploy_module <name>
# Deploys every target workbench_files_targets derives from the module's
# current manifest — the one derivation, shared with 'wb files' (D81).
# Whether and how each target is written, linked, left alone or held is
# decided in lib/files/lifecycle.sh; this loop only adds D75's physical
# (symlink-resolved) safety check immediately before each write.
# overrides_src (kind 'overrides') skips that check: its destination is
# engine-computed under ~/.config/workbench/local/, a denylisted root by
# design, and never module-declared (D48).
workbench_deploy_module() {
    _wb_engine_require_files
    local name="$1" current_dir
    local src dest kind lifecycle yield mode source
    current_dir="$(workbench_module_current_dir "${name}")"
    [[ -d "${current_dir}" ]] || { log_warn "workbench_deploy_module: ${name}: no current snapshot yet"; return 1; }

    local base
    while IFS='|' read -r base src dest kind lifecycle yield mode source; do
        [[ -z "${dest}" ]] && continue
        # Layers run their own physical check: their targets (~/.gitconfig,
        # ~/.ssh/config) are engine-computed and sit on the deploy denylist
        # by design (D82).
        if [[ "${mode}" == "layer" ]]; then
            workbench_layers_apply "${name}" "${base}" "${base}|${src}|${dest}|${kind}|${lifecycle}|${yield}|${mode}|${source}"
            continue
        fi
        if [[ "${kind}" != "overrides" ]] && ! _wb_dest_physical_is_safe "$(_wb_expand_dest "${dest%/}")" "${name}"; then
            log_error "workbench_deploy_module: ${name}: refusing ${dest} — resolves through a symlink to a denied location"
            continue
        fi
        case "${mode}" in
            copy)           workbench_files_apply "${name}" "${dest}" "${source}" "${src}" "${kind}" "${lifecycle}" "${yield}" ;;
            link|link_tree) workbench_files_apply_link "${name}" "${dest}" "${source}" "${src}" "${kind}" "${yield}" ;;
        esac
    done < <(workbench_files_targets "${name}" --log)

    workbench_files_write_pending "${name}"
    return 0
}

# ── register.list / deploy.list rendering ─────────────────────────────────────
# workbench_render_register_list <name>
# Rewrites <module>/register.list from the module's manifest, resolving
# each register.shell[].src against the module's current snapshot. Called
# after every successful fetch (new snapshot) so register.list always
# points into the snapshot actually deployed — this IS the hot-path
# convergence-constraint writer `wb add` and the sync engine share (§8).
workbench_render_register_list() {
    local name="$1"
    local current_dir manifest reglist src tier
    current_dir="$(workbench_module_current_dir "${name}")"
    manifest="$(workbench_resolve_manifest_path "${current_dir}")"
    reglist="$(workbench_module_dir "${name}")/register.list"

    : > "${reglist}"
    [[ -f "${manifest}" ]] || return 0

    local core_api
    core_api="$(workbench_manifest_scalar core_api "${manifest}")"
    [[ -z "${core_api}" ]] && return 0

    if command -v _workbench_core_api_version &>/dev/null; then
        local running
        running="$(_workbench_core_api_version)"
        if [[ -n "${running}" ]] && ! _wb_version_satisfies "${running}" "${core_api}"; then
            log_error "workbench_render_register_list: ${name}: declares core_api '${core_api}', running Core API is ${running} — refusing to register its shell content"
            return 1
        fi
    fi

    while IFS='|' read -r src tier; do
        [[ -z "${src}" ]] && continue
        _wb_path_is_safe_relative "${src}" || { log_error "workbench_render_register_list: ${name}: refusing register.shell src '${src}'"; continue; }
        printf '%s|%s\n' "${current_dir}/${src}" "${tier}" >> "${reglist}"
    done < <(workbench_manifest_register_shell_entries "${manifest}")
}

# ── getters.list rendering (docs/decisions-log.md D89) ──────────────────────────
# workbench_render_getters_list <name>
# Rewrites <module>/getters.list from the module's manifest
# register.getters[] entries, one "function|label" line each. The loader
# reads it to define every declared getter the module didn't define itself
# (lib/loader.sh), and _wb_module_getter (lib/core/functions.sh) reads the
# label back from it. Rendered at exactly the points register.list and
# installers.list are.
#
# The loader `eval`s the function name, so a name that is empty, starts
# with `_`, or contains anything outside [A-Za-z0-9_-] is skipped here with
# a warning (and again by the loader). The label is never evaluated; `|`,
# tabs and newlines are stripped from it so it stays one field on one line.
#
# A core_api refusal leaves an existing getters.list in place: the list is
# only truncated once the check has passed, so a re-render after core was
# pinned back doesn't strip a module's getters (docs/decisions-log.md D89).
workbench_render_getters_list() {
    local name="$1"
    local current_dir manifest getlist getter_name getter_fn getter_label
    current_dir="$(workbench_module_current_dir "${name}")"
    manifest="$(workbench_resolve_manifest_path "${current_dir}")"
    getlist="$(workbench_module_dir "${name}")/getters.list"

    if [[ ! -f "${manifest}" ]]; then
        : > "${getlist}"
        return 0
    fi

    local core_api
    core_api="$(workbench_manifest_scalar core_api "${manifest}")"
    if [[ -z "${core_api}" ]]; then
        : > "${getlist}"
        return 0
    fi

    if command -v _workbench_core_api_version &>/dev/null; then
        local running
        running="$(_workbench_core_api_version)"
        if [[ -n "${running}" ]] && ! _wb_version_satisfies "${running}" "${core_api}"; then
            log_error "workbench_render_getters_list: ${name}: declares core_api '${core_api}', running Core API is ${running} — refusing to register its getters"
            return 1
        fi
    fi

    : > "${getlist}"
    while IFS='|' read -r getter_name getter_fn getter_label; do
        [[ -z "${getter_name}" && -z "${getter_fn}" ]] && continue
        case "${getter_fn}" in
            ''|_*|*[!A-Za-z0-9_-]*)
                log_warn "workbench_render_getters_list: ${name}: skipping register.getters[] entry '${getter_name}' — function '${getter_fn}' must be non-empty, not start with '_', and use only A-Z a-z 0-9 _ -"
                continue
                ;;
        esac
        getter_label="$(printf '%s' "${getter_label}" | tr -d '|\t\n')"
        printf '%s|%s\n' "${getter_fn}" "${getter_label}" >> "${getlist}"
    done < <(workbench_manifest_register_getter_entries "${manifest}")
}

# ── installers.list rendering (docs/decisions-log.md D23) ───────────────────────
# workbench_render_installers_list <name>
# The tool-registry framework's discovery half: rewrites
# <module>/installers.list from the module's manifest register.installers[]
# entries, resolved against that module's current snapshot. Called at
# exactly the same point workbench_render_register_list is (every
# successful fetch, and the unconditional wb install/apply convergence
# pass) — see bin/wb's _wb_converge_module_registrations.
#
# Each declared file is introspected as plain text via
# _extract_function_names (lib/core/functions.sh — the same primitive
# get-functions already uses for register.shell[] files), never sourced:
# core only needs the *names* of the install-<x> functions a module
# declares, not to actually run any of them yet, and text introspection
# can't have side effects the way sourcing an arbitrary module file could.
workbench_render_installers_list() {
    local name="$1"
    local current_dir manifest instlist src abs_path func_name
    current_dir="$(workbench_module_current_dir "${name}")"
    manifest="$(workbench_resolve_manifest_path "${current_dir}")"
    instlist="$(workbench_module_dir "${name}")/installers.list"

    : > "${instlist}"
    [[ -f "${manifest}" ]] || return 0

    local core_api
    core_api="$(workbench_manifest_scalar core_api "${manifest}")"
    [[ -z "${core_api}" ]] && return 0

    if command -v _workbench_core_api_version &>/dev/null; then
        local running
        running="$(_workbench_core_api_version)"
        if [[ -n "${running}" ]] && ! _wb_version_satisfies "${running}" "${core_api}"; then
            log_error "workbench_render_installers_list: ${name}: declares core_api '${core_api}', running Core API is ${running} — refusing to register its installers"
            return 1
        fi
    fi

    while IFS= read -r src; do
        [[ -z "${src}" ]] && continue
        _wb_path_is_safe_relative "${src}" || { log_error "workbench_render_installers_list: ${name}: refusing register.installers src '${src}'"; continue; }
        abs_path="${current_dir}/${src}"
        if [[ ! -f "${abs_path}" ]]; then
            log_warn "workbench_render_installers_list: ${name}: register.installers[] src not found: ${abs_path}"
            continue
        fi

        while IFS= read -r func_name; do
            [[ -z "${func_name}" ]] && continue
            case "${func_name}" in
                install-?*)
                    printf '%s|%s|%s\n' "${abs_path}" "${func_name}" "${func_name#install-}" >> "${instlist}"
                    ;;
            esac
        done < <(_extract_function_names "${abs_path}")
    done < <(workbench_manifest_register_installer_entries "${manifest}")
}

# ── Hooks ──────────────────────────────────────────────────────────────────────
# _wb_hook_describe_change <name> <approved_sha> <current_sha> <hook_argv0>
# What the user is being asked to approve: the hook path and, for GitHub
# remotes, a compare URL covering every change since the last approval.
_wb_hook_describe_change() {
    local name="$1" approved="$2" current="$3" hook="$4" url owner repo
    url="$(workbench_module_conf_get "${name}" REPO_URL "")"
    if [[ -n "${approved}" ]]; then
        printf '\n%s: post_deploy hook %s has changed since you last approved it.\n' "${name}" "${hook}"
    else
        printf '\n%s: post_deploy hook %s has not been approved on this host yet.\n' "${name}" "${hook}"
    fi
    if read -r owner repo < <(workbench_parse_github_url "${url}"); then
        if [[ -n "${approved}" ]]; then
            printf '  Review: https://github.com/%s/%s/compare/%s...%s\n\n' "${owner}" "${repo}" "${approved}" "${current}"
        else
            printf '  Review: https://github.com/%s/%s/tree/%s\n\n' "${owner}" "${repo}" "${current}"
        fi
    else
        printf '  Commit: %s (%s)\n\n' "${current}" "${url}"
    fi
}

# workbench_run_post_deploy_hook <name> <reason> <changed> <is_first_sync>
# run_on semantics (contracts/manifest-spec.md §Hook contract): changed
# (default) fires when <changed> is true OR this is the module's first
# successful sync ever; always fires every cycle regardless; initial fires
# only on the first successful sync. Gated first by ALLOW_HOOKS — an
# undeclared or ungated hook is a no-op, not an error.
workbench_run_post_deploy_hook() {
    local name="$1" reason="$2" changed="$3" is_first="$4"
    local current_dir allow_hooks hook_line run_on timeout_s
    local current_sha approved_sha pending
    current_dir="$(workbench_module_current_dir "${name}")"
    allow_hooks="$(workbench_module_conf_get "${name}" ALLOW_HOOKS false)"
    [[ "${allow_hooks}" == "true" ]] || return 0

    hook_line="$(workbench_manifest_hook_post_deploy "$(workbench_resolve_manifest_path "${current_dir}")")"
    [[ -z "${hook_line}" ]] && return 0

    local -a fields argv
    IFS='|' read -r -a fields <<< "${hook_line}"
    run_on="${fields[0]}"
    timeout_s="${fields[1]}"
    argv=("${fields[@]:2}")
    _wb_path_is_safe_relative "${argv[0]}" || { log_error "${name}: refusing post_deploy hook '${argv[0]}' — absolute or contains '..'"; return 0; }

    # A hook deferred by an earlier unattended cycle is still owed a run.
    pending="$(workbench_module_conf_get "${name}" HOOKS_PENDING false)"
    [[ "${pending}" == "true" ]] && changed="true"

    case "${run_on}" in
        always)  : ;;
        initial) [[ "${is_first}" == "true" ]] || return 0 ;;
        *)       [[ "${changed}" == "true" || "${is_first}" == "true" ]] || return 0 ;;
    esac

    # ── Consent binding (security review M1; D76) ────────────────────────────
    current_sha="$(workbench_module_conf_get "${name}" RESOLVED_SHA "")"
    approved_sha="$(workbench_module_conf_get "${name}" HOOKS_APPROVED_SHA "")"

    if [[ -z "${approved_sha}" && "${changed}" != "true" && "${is_first}" != "true" ]]; then
        # Migration from pre-D76 consent: this commit already ran under the
        # old model; approve it without prompting.
        workbench_module_conf_set "${name}" HOOKS_APPROVED_SHA "${current_sha}"
        approved_sha="${current_sha}"
    fi

    if [[ "${current_sha}" != "${approved_sha}" ]]; then
        case "${reason}" in
            add)
                : # --allow-hooks on this very command is the consent
                ;;
            manual|track)
                # /dev/tty, not stdin: a person can be asked even when stdin
                # is a pipe (docs/decisions-log.md D84).
                if command -v _wb_have_tty &>/dev/null && _wb_have_tty; then
                    _wb_hook_describe_change "${name}" "${approved_sha}" "${current_sha}" "${argv[0]}" >/dev/tty
                    local answer=""
                    printf "Run %s's post_deploy hook for %s? [y/N]: " "${name}" "${current_sha:0:7}" >/dev/tty
                    IFS= read -r answer </dev/tty || answer=""
                    case "${answer}" in
                        y|Y|yes|YES) : ;;
                        *)
                            workbench_module_conf_set "${name}" HOOKS_PENDING true
                            log_info "${name}: post_deploy hook left pending — run 'wb update ${name}' to review again"
                            return 0
                            ;;
                    esac
                fi
                ;;
            *)
                workbench_module_conf_set "${name}" HOOKS_PENDING true
                log_warn "${name}: post_deploy hook not run — ${current_sha:0:7} is not approved for unattended hook execution (approved: ${approved_sha:0:7}). Run 'wb update ${name}' to review and run it."
                _wb_adoption_log_event "hook-deferred" "${name}" "${approved_sha}" "${current_sha}" "" "${reason}"
                return 0
                ;;
        esac
        workbench_module_conf_set "${name}" HOOKS_APPROVED_SHA "${current_sha}"
    fi
    workbench_module_conf_set "${name}" HOOKS_PENDING false

    local script_path="${current_dir}/${argv[0]}"
    local -a hook_args=()
    [[ "${#argv[@]}" -gt 1 ]] && hook_args=("${argv[@]:1}")

    local timeout_bin=""
    command -v timeout &>/dev/null && timeout_bin="timeout"
    command -v gtimeout &>/dev/null && timeout_bin="gtimeout"

    local -a cmd=()
    if [[ -n "${timeout_bin}" ]]; then
        cmd=("${timeout_bin}" "${timeout_s}" bash "${script_path}")
    else
        cmd=(bash "${script_path}")
    fi
    # Appended only when non-empty: under macOS's stock bash 3.2, "${arr[@]}"
    # on a declared-but-empty array trips `set -u`'s unbound-variable check
    # (fixed in bash 4.4+, but 3.2 is this repo's floor) — this sidesteps
    # the expansion entirely rather than reaching for a set -u workaround.
    [[ "${#hook_args[@]}" -gt 0 ]] && cmd+=("${hook_args[@]}")

    log_info "${name}: running post_deploy hook (reason: ${reason})"
    (
        cd "${current_dir}" || exit 1
        export WORKBENCH_MODULE_NAME="${name}"
        export WORKBENCH_MODULE_DIR="${current_dir}"
        export WORKBENCH_SYNC_REASON="${reason}"
        "${cmd[@]}"
    )
    local rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        log_info "${name}: post_deploy hook succeeded"
        _wb_adoption_log_event "hook-run" "${name}" "${approved_sha}" "${current_sha}" "" "${reason}"
    else
        log_warn "${name}: post_deploy hook failed (exit ${rc}) — non-fatal, this module's sync still counts as successful"
        _wb_adoption_log_event "hook-failed" "${name}" "${approved_sha}" "${current_sha}" "" "${reason}"
    fi
    return 0
}

# ── Per-module sync ────────────────────────────────────────────────────────────
# _wb_engine_require_files
# Lazy-loads lib/files/lifecycle.sh (D81), lib/files/layers.sh (D82) and
# their one dependency,
# core/installers-common.sh (_wb_sha256), at first deploy — same
# _wb_require-or-private-fallback shape as workbench_sync_module below, so
# this file still works sourced standalone with no bin/wb in the picture.
_wb_engine_require_files() {
    if command -v _wb_require &>/dev/null; then
        _wb_require core/installers-common.sh files/lifecycle.sh files/layers.sh
        return 0
    fi
    local _wb_ef_dep
    for _wb_ef_dep in core/installers-common.sh files/lifecycle.sh files/layers.sh; do
        if command -v _workbench_script_version_registered &>/dev/null \
            && _workbench_script_version_registered "lib/${_wb_ef_dep}"; then
            continue
        fi
        # shellcheck disable=SC1090
        source "${_wb_engine_lib_dir}/../${_wb_ef_dep}"
    done
}

# workbench_sync_module <name> [reason]
# Returns 0 on a successful cycle (whether or not anything actually
# changed), 1 on a resolution/fetch failure (logged, never fatal to the
# caller's loop over other modules).
workbench_sync_module() {
    # Lazy-load the distribution primitives here, not at this file's own
    # top (see the comment on the dependency block above) — the instant a
    # real sync actually runs, not before. bin/wb's own _wb_require
    # (lazy-source, idempotent per process, backed by the same
    # _WB_SCRIPT_VERSIONS dedup core/version.sh already maintains) is used
    # when available; when this file is sourced standalone — e.g.
    # tests/check-sync-engine-isolation.sh, which exercises this function
    # with no bin/wb in the picture at all — a private fallback sources
    # them directly by path instead, keyed off the same dedup array, so
    # this function keeps working with no dependency on bin/wb ever having
    # run (module zero stays self-contained).
    if command -v _wb_require &>/dev/null; then
        _wb_require distribution/resolve.sh distribution/fetch-tarball.sh distribution/fetch-git-snapshot.sh distribution/snapshot.sh
    else
        local _wb_sm_dep
        for _wb_sm_dep in resolve.sh fetch-tarball.sh fetch-git-snapshot.sh snapshot.sh; do
            if command -v _workbench_script_version_registered &>/dev/null \
                && _workbench_script_version_registered "lib/distribution/${_wb_sm_dep}"; then
                continue
            fi
            # shellcheck disable=SC1090
            source "${_wb_engine_lib_dir}/../distribution/${_wb_sm_dep}"
        done
    fi

    _wb_engine_require_files

    local name="$1" reason="${2:-scheduled}"
    local mode resolved current_sha module_dir

    module_dir="$(workbench_module_dir "${name}")"
    mode="$(workbench_module_conf_get "${name}" TRACK_MODE latest)"

    resolved="$(workbench_resolve_module "${name}")"
    if [[ -z "${resolved}" ]]; then
        log_warn "${name}: could not resolve tracked ref this cycle — skipping (will retry)"
        return 1
    fi
    local ref_label new_sha
    IFS='|' read -r ref_label new_sha <<< "${resolved}"

    current_sha="$(workbench_module_conf_get "${name}" RESOLVED_SHA "")"
    local ref_form ref_value
    read -r ref_form ref_value < <(workbench_track_mode_parts "${mode}")

    local is_first="false"
    [[ -z "${current_sha}" ]] && is_first="true"

    if [[ "${new_sha}" == "${current_sha}" && -d "${module_dir}/current" ]]; then
        log_info "${name}: up to date (${new_sha:0:7})"
        # A pending release that upstream withdrew (latest resolves back to
        # what is deployed) is no longer pending.
        if [[ -n "$(workbench_module_conf_get "${name}" PENDING_SHA "")" ]]; then
            workbench_module_conf_set "${name}" PENDING_SHA ""
            workbench_module_conf_set "${name}" PENDING_SINCE ""
        fi
        workbench_run_post_deploy_hook "${name}" "${reason}" "false" "${is_first}"
        return 0
    fi

    # ── Release cooldown (security review H3 tier 2; D77) ────────────────────
    # Unattended syncs adopt a new latest release only after it has been seen
    # continuously for RELEASE_COOLDOWN_DAYS. Gives the maintainer a window to
    # delete a bad tag before it reaches every host. Interactive commands
    # (wb update/add/track) are unaffected.
    if [[ "${reason}" == "scheduled" && "${ref_form}" == "latest" && -n "${current_sha}" ]]; then
        local cooldown_days
        cooldown_days="$(_wb_release_cooldown_days)"
        if [[ "${cooldown_days}" -gt 0 ]]; then
            local pending_sha pending_since now held_for needed
            pending_sha="$(workbench_module_conf_get "${name}" PENDING_SHA "")"
            pending_since="$(workbench_module_conf_get "${name}" PENDING_SINCE "")"
            now="$(date +%s)"
            if [[ "${pending_sha}" != "${new_sha}" ]]; then
                workbench_module_conf_set "${name}" PENDING_SHA "${new_sha}"
                workbench_module_conf_set "${name}" PENDING_SINCE "${now}"
                log_info "${name}: new release ${ref_label} (${new_sha:0:7}) first seen — holding ${cooldown_days}d before unattended adoption ('wb update ${name}' adopts it now)"
                _wb_adoption_log_event "cooldown-start" "${name}" "${current_sha}" "${new_sha}" "${ref_label}" "${reason}"
                workbench_run_post_deploy_hook "${name}" "${reason}" "false" "${is_first}"
                return 0
            fi
            case "${pending_since}" in
                ''|*[!0-9]*) pending_since="${now}" ;;
            esac
            held_for=$((now - pending_since))
            needed=$((cooldown_days * 86400))
            if [[ "${held_for}" -lt "${needed}" ]]; then
                log_info "${name}: ${ref_label} (${new_sha:0:7}) in cooldown — $(( (needed - held_for + 3599) / 3600 ))h remaining"
                workbench_run_post_deploy_hook "${name}" "${reason}" "false" "${is_first}"
                return 0
            fi
        fi
    fi

    log_info "${name}: change detected (${current_sha:-none} -> ${new_sha:0:7}) — fetching"

    local shortsha="${new_sha:0:7}"
    local new_snapshot
    new_snapshot="$(workbench_snapshot_path "${name}" "${ref_label}" "${shortsha}")"
    if [[ -d "${new_snapshot}" ]] && ! workbench_files_snapshot_reusable "${name}" "${new_snapshot}"; then
        # D81: a snapshot a held file is pinned to, or one changed through a
        # link since it was fetched, carries the user's changes — never make
        # it current again as if it were the module's content.
        log_error "${name}: snapshot ${shortsha} on disk holds changes made through linked files — resolve them first ('wb files status'), then update again"
        return 1
    elif [[ -d "${new_snapshot}" ]]; then
        log_info "${name}: snapshot ${shortsha} already present on disk — re-using, not re-fetching"
    else
        local url private ok=1
        url="$(workbench_module_conf_get "${name}" REPO_URL "")"
        private="$(workbench_module_conf_get "${name}" PRIVATE false)"

        if [[ "${private}" == "true" || "${ref_form}" == "branch" ]]; then
            # "latest" has no branch/tag/commit form of its own — the
            # resolved tag name (ref_label) is what to fetch, same
            # normalisation the public/tarball branch below already does.
            local git_form="${ref_form}" git_ref="${ref_value}"
            if [[ "${ref_form}" == "latest" ]]; then
                git_form="tag"; git_ref="${ref_label}"
            fi
            workbench_fetch_git_snapshot "${url}" "${git_form}" "${git_ref}" "${new_snapshot}" "${new_sha}" && ok=0
        else
            local owner repo
            read -r owner repo < <(workbench_parse_github_url "${url}")
            # Always fetch by the resolved commit sha, never by tag or branch
            # name. The sha is what RESOLVED_SHA and the snapshot dirname
            # record; a name can move between resolve and fetch (security
            # review L1). codeload serves tar.gz/<sha> for any commit.
            workbench_fetch_tarball_public "${owner}" "${repo}" "commit" "${new_sha}" "${new_snapshot}" && ok=0
        fi

        if [[ "${ok}" -ne 0 ]]; then
            log_warn "${name}: fetch failed — skipping this cycle, previous snapshot (if any) stays deployed"
            return 1
        fi
    fi

    # Checked against the newly-fetched snapshot itself, before it becomes
    # `current` — a refusal here must leave whatever was previously synced
    # (current symlink, RESOLVED_SHA) untouched, not swap unsupported
    # content live and then merely skip re-rendering it
    # (docs/decisions-log.md D30). Deliberately re-checked every cycle a mismatch persists
    # (RESOLVED_SHA is never advanced past it), unlike the core_api gate's
    # once-per-change frequency — going quiet on a module stuck on an
    # unsupported version would be a worse silence than a repeated log line.
    local new_manifest manifest_version expected_version
    new_manifest="$(workbench_resolve_manifest_path "${new_snapshot}")"
    if [[ -n "${new_manifest}" ]]; then
        manifest_version="$(workbench_manifest_scalar version "${new_manifest}")"
        expected_version="$(workbench_manifest_expected_version "${new_manifest}")"
        if ! _wb_manifest_schema_supported "${manifest_version}" || [[ "${manifest_version}" != "${expected_version}" ]]; then
            log_error "${name}: $(basename -- "${new_manifest}") declares version '${manifest_version:-<missing>}', expected ${expected_version} for that filename — refusing to sync (previous snapshot, if any, stays current)"
            return 1
        fi
        # Same refuse-before-swap semantics as the version gate above (D75).
        if ! workbench_manifest_paths_safe "${new_manifest}" "${name}"; then
            log_error "${name}: $(basename -- "${new_manifest}") failed path-safety validation — refusing to sync (previous snapshot, if any, stays current)"
            return 1
        fi
    fi

    # D81: record the new snapshot's checksums, then make sure no change
    # made through a linked file is discarded by the swap — such entries
    # are held at the snapshot they're on, which prune then keeps.
    # Checked explicitly, not left to set -e: workbench_sync_run_one's
    # 'if ! ( set -e; ... )' context disables errexit, and the interactive
    # callers don't set it at all.
    if ! workbench_files_record_sums "${name}" "${new_snapshot}" || ! workbench_files_before_swap "${name}"; then
        log_error "${name}: couldn't secure changes made through linked files — not updating this module this time (previous snapshot stays current)"
        return 1
    fi

    workbench_snapshot_swap "${name}" "${new_snapshot}"
    workbench_snapshot_prune "${name}"

    # D84: 'wb add', 'wb install --bundle' and bootstrap stage the first
    # sync — fetched and current, nothing deployed, no hook run — so the
    # user can be asked about their existing config before anything outside
    # workbench's own directories changes. RESOLVED_SHA stays unset: the
    # next sync of any kind finds this snapshot on disk and completes the
    # cycle (deploy, hook), unattended ones with the default answer, keep.
    if [[ "${reason}" == "stage" ]]; then
        log_info "${name}: fetched ${ref_label} (${shortsha}) — nothing deployed yet"
        return 0
    fi

    workbench_module_conf_set "${name}" RESOLVED_SHA "${new_sha}"
    workbench_module_conf_set "${name}" TRACK_REF "${ref_value:-${ref_label}}"
    workbench_module_conf_set "${name}" PENDING_SHA ""
    workbench_module_conf_set "${name}" PENDING_SINCE ""
    _wb_adoption_log_event "adopt" "${name}" "${current_sha}" "${new_sha}" "${ref_label}" "${reason}"

    workbench_render_register_list "${name}"
    workbench_render_installers_list "${name}"
    workbench_render_getters_list "${name}"
    workbench_deploy_module "${name}"
    workbench_run_post_deploy_hook "${name}" "${reason}" "true" "${is_first}"

    return 0
}

# ── Bulk sync ──────────────────────────────────────────────────────────────────
# workbench_sync_run_one <name> <reason>
# Isolation wrapper: a module's own function running under `set -e` in a
# subshell cannot take down the caller's loop over every other module, no
# matter what fails partway through.
workbench_sync_run_one() {
    local name="$1" reason="$2"
    if ! ( set -e; workbench_sync_module "${name}" "${reason}" ); then
        log_error "${name}: sync failed — see warnings above. Other modules are unaffected."
        return 1
    fi
}

# workbench_sync_all [reason]
# Every registered, sync-enabled module (core included), each isolated per
# workbench_sync_run_one. Always updates the last-run timestamp for the
# next workbench_sync_due() check, win or lose.
workbench_sync_all() {
    local reason="${1:-scheduled}"
    local name failures=0
    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        workbench_sync_run_one "${name}" "${reason}" || failures=$((failures + 1))
    done < <(workbench_list_loadable_modules)
    workbench_cadence_mark_ran
    return "${failures}"
}
