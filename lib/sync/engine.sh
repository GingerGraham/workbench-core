#!/usr/bin/env bash
# lib/sync/engine.sh — the unified sync loop (ARCHITECTURE.md §9, principle
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

_wb_engine_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
for _wb_engine_dep in \
    "${_wb_engine_lib_dir}/../core/log.sh" \
    "${_wb_engine_lib_dir}/../core/functions.sh" \
    "${_wb_engine_lib_dir}/../core/semver.sh" \
    "${_wb_engine_lib_dir}/../core/version.sh" \
    "${_wb_engine_lib_dir}/../manifest/parse.sh" \
    "${_wb_engine_lib_dir}/../distribution/resolve.sh" \
    "${_wb_engine_lib_dir}/../distribution/fetch-tarball.sh" \
    "${_wb_engine_lib_dir}/../distribution/fetch-git-snapshot.sh" \
    "${_wb_engine_lib_dir}/../distribution/snapshot.sh" \
    "${_wb_engine_lib_dir}/state.sh"; do
    # shellcheck disable=SC1090
    [[ -f "${_wb_engine_dep}" ]] && source "${_wb_engine_dep}"
done
unset _wb_engine_dep

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/sync/engine.sh" "0.1.0" || true

# ── Cadence (ARCHITECTURE.md §9.4/D8) ─────────────────────────────────────────
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
# launchd StartInterval=300 — see ansible/roles/module_sync's timer
# templates) that invokes `wb sync run-if-due` every 5 minutes
# unconditionally; THIS function is what decides, in userspace, whether that
# firing should actually do anything. Reconfiguring a live systemd timer's
# own interval requires a daemon-reload and timer restart, which is
# exactly the "restart of the timer infrastructure" ARCHITECTURE.md §9.4
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
# mode) or ANY branch:-tracked repo — ARCHITECTURE.md §9.1.
workbench_resolve_module() {
    local name="$1"
    local url private mode ref_form ref_value
    url="$(workbench_module_conf_get "${name}" REPO_URL "")"
    private="$(workbench_module_conf_get "${name}" PRIVATE false)"
    mode="$(workbench_module_conf_get "${name}" TRACK_MODE latest)"
    [[ -z "${url}" ]] && { log_warn "workbench_resolve_module: ${name}: no REPO_URL in sync.conf"; return 1; }

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

workbench_deploy_copy_file() {
    local src="$1" dest="$2" force="$3"
    mkdir -p "$(dirname "${dest}")"
    [[ -e "${dest}" && "${force}" != "true" ]] && return 0
    cp -f "${src}" "${dest}"
    log_info "  deployed (copy): ${dest}"
}

workbench_deploy_link_file() {
    local src="$1" dest="$2" force="$3"
    mkdir -p "$(dirname "${dest}")"
    if [[ -L "${dest}" ]]; then
        [[ "$(readlink "${dest}")" == "${src}" ]] && return 0
        rm -f "${dest}"; ln -s "${src}" "${dest}"
        log_info "  relinked: ${dest} -> ${src}"
    elif [[ -e "${dest}" ]]; then
        [[ "${force}" != "true" ]] && { log_warn "  ${dest} exists and is not a symlink — skipping"; return 0; }
        rm -rf "${dest}"; ln -s "${src}" "${dest}"
        log_info "  deployed (link): ${dest} -> ${src}"
    else
        ln -s "${src}" "${dest}"
        log_info "  deployed (link): ${dest} -> ${src}"
    fi
}

workbench_deploy_module() {
    local name="$1"
    local current_dir src dest dest_macos mode force platforms
    current_dir="$(workbench_module_current_dir "${name}")"
    [[ -d "${current_dir}" ]] || { log_warn "workbench_deploy_module: ${name}: no current snapshot yet"; return 1; }

    while IFS='|' read -r src dest dest_macos mode force platforms; do
        [[ -z "${src}" ]] && continue
        if [[ -n "${platforms}" ]]; then
            case "${WORKBENCH_OS:-}" in
                Mac)   printf '%s\n' "${platforms}" | tr ',' '\n' | grep -qx macos || continue ;;
                Linux) printf '%s\n' "${platforms}" | tr ',' '\n' | grep -qx linux || continue ;;
            esac
        fi
        local real_dest="${dest}"
        [[ "${WORKBENCH_OS:-}" == "Mac" && -n "${dest_macos}" ]] && real_dest="${dest_macos}"
        real_dest="$(_wb_expand_dest "${real_dest}")"
        local abs_src="${current_dir}/${src%/}"

        if [[ -d "${abs_src}" ]]; then
            local file rel target
            while IFS= read -r -d '' file; do
                rel="${file#"${abs_src}"/}"
                target="${real_dest%/}/${rel}"
                if [[ "${mode}" == "link" ]]; then
                    workbench_deploy_link_file "${file}" "${target}" "${force}"
                else
                    workbench_deploy_copy_file "${file}" "${target}" "${force}"
                fi
            done < <(find "${abs_src}" -name .git -prune -o -type f -print0)
        elif [[ -e "${abs_src}" ]]; then
            if [[ "${mode}" == "link" ]]; then
                workbench_deploy_link_file "${abs_src}" "${real_dest}" "${force}"
            else
                workbench_deploy_copy_file "${abs_src}" "${real_dest}" "${force}"
            fi
        else
            log_warn "workbench_deploy_module: ${name}: deploy src not found: ${abs_src}"
        fi
    done < <(workbench_manifest_deploy_entries "${current_dir}/.dotfiles-sync.yml")
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
    manifest="${current_dir}/.dotfiles-sync.yml"
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
        printf '%s|%s\n' "${current_dir}/${src}" "${tier}" >> "${reglist}"
    done < <(workbench_manifest_register_shell_entries "${manifest}")
}

# ── installers.list rendering (ARCHITECTURE.md §12 D23) ───────────────────────
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
    manifest="${current_dir}/.dotfiles-sync.yml"
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
# workbench_run_post_deploy_hook <name> <reason> <changed> <is_first_sync>
# run_on semantics (contracts/manifest-spec.md §Hook contract): changed
# (default) fires when <changed> is true OR this is the module's first
# successful sync ever; always fires every cycle regardless; initial fires
# only on the first successful sync. Gated first by ALLOW_HOOKS — an
# undeclared or ungated hook is a no-op, not an error.
workbench_run_post_deploy_hook() {
    local name="$1" reason="$2" changed="$3" is_first="$4"
    local current_dir allow_hooks hook_line run_on timeout_s
    current_dir="$(workbench_module_current_dir "${name}")"
    allow_hooks="$(workbench_module_conf_get "${name}" ALLOW_HOOKS false)"
    [[ "${allow_hooks}" == "true" ]] || return 0

    hook_line="$(workbench_manifest_hook_post_deploy "${current_dir}/.dotfiles-sync.yml")"
    [[ -z "${hook_line}" ]] && return 0

    local -a fields argv
    IFS='|' read -r -a fields <<< "${hook_line}"
    run_on="${fields[0]}"
    timeout_s="${fields[1]}"
    argv=("${fields[@]:2}")

    case "${run_on}" in
        always)  : ;;
        initial) [[ "${is_first}" == "true" ]] || return 0 ;;
        *)       [[ "${changed}" == "true" || "${is_first}" == "true" ]] || return 0 ;;
    esac

    local script_path="${current_dir}/${argv[0]}"
    local -a hook_args=()
    [[ "${#argv[@]}" -gt 1 ]] && hook_args=("${argv[@]:1}")

    local timeout_bin=""
    command -v timeout &>/dev/null && timeout_bin="timeout"
    command -v gtimeout &>/dev/null && timeout_bin="gtimeout"

    log_info "${name}: running post_deploy hook (reason: ${reason})"
    (
        cd "${current_dir}" || exit 1
        export WORKBENCH_MODULE_NAME="${name}"
        export WORKBENCH_MODULE_DIR="${current_dir}"
        export WORKBENCH_SYNC_REASON="${reason}"
        if [[ -n "${timeout_bin}" ]]; then
            "${timeout_bin}" "${timeout_s}" bash "${script_path}" "${hook_args[@]}"
        else
            bash "${script_path}" "${hook_args[@]}"
        fi
    )
    local rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        log_info "${name}: post_deploy hook succeeded"
    else
        log_warn "${name}: post_deploy hook failed (exit ${rc}) — non-fatal, this module's sync still counts as successful"
    fi
    return 0
}

# ── Per-module sync ────────────────────────────────────────────────────────────
# workbench_sync_module <name> [reason]
# Returns 0 on a successful cycle (whether or not anything actually
# changed), 1 on a resolution/fetch failure (logged, never fatal to the
# caller's loop over other modules).
workbench_sync_module() {
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
        workbench_run_post_deploy_hook "${name}" "${reason}" "false" "${is_first}"
        return 0
    fi

    log_info "${name}: change detected (${current_sha:-none} -> ${new_sha:0:7}) — fetching"

    local shortsha="${new_sha:0:7}"
    local new_snapshot
    new_snapshot="$(workbench_snapshot_path "${name}" "${ref_label}" "${shortsha}")"
    if [[ -d "${new_snapshot}" ]]; then
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
            workbench_fetch_git_snapshot "${url}" "${git_form}" "${git_ref}" "${new_snapshot}" && ok=0
        else
            local owner repo
            read -r owner repo < <(workbench_parse_github_url "${url}")
            local tarball_form="${ref_form}"
            local tarball_ref="${ref_value}"
            [[ "${ref_form}" == "latest" ]] && { tarball_form="tag"; tarball_ref="${ref_label}"; }
            workbench_fetch_tarball_public "${owner}" "${repo}" "${tarball_form}" "${tarball_ref}" "${new_snapshot}" && ok=0
        fi

        if [[ "${ok}" -ne 0 ]]; then
            log_warn "${name}: fetch failed — skipping this cycle, previous snapshot (if any) stays deployed"
            return 1
        fi
    fi

    # Checked against the newly-fetched snapshot itself, before it becomes
    # `current` — a refusal here must leave whatever was previously synced
    # (current symlink, RESOLVED_SHA) untouched, not swap unsupported
    # content live and then merely skip re-rendering it (ARCHITECTURE.md
    # §12 D30). Deliberately re-checked every cycle a mismatch persists
    # (RESOLVED_SHA is never advanced past it), unlike the core_api gate's
    # once-per-change frequency — going quiet on a module stuck on an
    # unsupported version would be a worse silence than a repeated log line.
    local new_manifest manifest_version
    new_manifest="${new_snapshot}/.dotfiles-sync.yml"
    if [[ -f "${new_manifest}" ]]; then
        manifest_version="$(workbench_manifest_scalar version "${new_manifest}")"
        if ! _wb_manifest_schema_supported "${manifest_version}"; then
            log_error "${name}: declares version '${manifest_version:-<missing>}', this core only supports schema version(s) ${_WB_MANIFEST_SCHEMA_VERSIONS_SUPPORTED} — refusing to sync (previous snapshot, if any, stays current)"
            return 1
        fi
    fi

    workbench_snapshot_swap "${name}" "${new_snapshot}"
    workbench_snapshot_prune "${name}"
    workbench_module_conf_set "${name}" RESOLVED_SHA "${new_sha}"
    workbench_module_conf_set "${name}" TRACK_REF "${ref_value:-${ref_label}}"

    workbench_render_register_list "${name}"
    workbench_render_installers_list "${name}"
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
