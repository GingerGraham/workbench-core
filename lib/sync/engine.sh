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
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/sync/engine.sh" "0.4.1" || true

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
# launchd StartInterval=300 — see ansible/roles/module_sync's timer
# templates) that invokes `wb sync run-if-due` every 5 minutes
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

# workbench_backup_existing_file <dest> [<module>]
# Copies whatever currently exists at <dest> into the engine-computed
# backup root before a force overwrite replaces or removes it
# (docs/decisions-log.md D53) — the single choke point both
# workbench_deploy_copy_file's and workbench_deploy_link_file's force
# branches call through, so nothing that overwrites real content via
# either path can do so unbacked-up.
#
# No-ops (returns 0) when there's nothing worth preserving: dest doesn't
# exist, or dest is a symlink — a symlink is the engine's own pointer,
# never user content, exactly the same distinction
# workbench_deploy_copy_file's own D51 fix already draws just below this.
# A real file OR a real directory (workbench_deploy_link_file's rm -rf
# case) is handled identically — cp -a copies either.
#
# A failed backup aborts the caller's overwrite (non-zero return) rather
# than proceeding unprotected: a backup that silently didn't happen is a
# worse outcome than refusing the whole operation and saying so.
workbench_backup_existing_file() {
    local dest="$1" module="${2:-}"
    [[ -e "${dest}" ]] || return 0
    [[ -L "${dest}" ]] && return 0

    local backup_root="${XDG_DATA_HOME:-${HOME}/.local/share}/workbench/backups"
    local backup_dir
    backup_dir="${backup_root}/$(date +%Y-%m-%d)/$(date +%H00)"
    local backup_base
    backup_base="${module:+${module}-}$(basename "${dest}").$(date +%H%M%S)"
    local backup_path="${backup_dir}/${backup_base}"

    # Same-second collision inside one hour bucket (two overwrites of the
    # same file within a second) — unlikely at the volume this exists
    # for, but a counter suffix is nearly free and beats silently
    # clobbering an earlier backup.
    local n=2
    while [[ -e "${backup_path}" ]]; do
        backup_path="${backup_dir}/${backup_base}.${n}"
        n=$((n + 1))
    done

    mkdir -p "${backup_dir}"
    if cp -a "${dest}" "${backup_path}"; then
        log_info "  backed up existing ${dest} -> ${backup_path}"
    else
        log_error "  failed to back up ${dest} before overwrite — leaving it in place, not proceeding"
        return 1
    fi
}

workbench_deploy_copy_file() {
    local src="$1" dest="$2" force="$3" module="${4:-}"
    mkdir -p "$(dirname "${dest}")"
    [[ -e "${dest}" && "${force}" != "true" ]] && return 0
    # A symlink counts as existing for the check above, so this only runs
    # when force=true — but `cp -f` on a destination that's a symlink
    # follows it and overwrites whatever it points at, not the symlink
    # itself. For a stale `mode: link` destination migrating to `mode:
    # copy` (docs/decisions-log.md D51), that target is the module's own
    # immutable snapshot file — silently corrupting it, not the user's
    # file, while leaving the destination still a symlink afterwards.
    # Remove the symlink first so cp always writes a real, detached file.
    [[ -L "${dest}" ]] && rm -f "${dest}"
    # Back up a real pre-existing file before a force overwrite actually
    # changes its content (docs/decisions-log.md D53) — skipped when the
    # incoming content is byte-identical, so a re-deploy of an unchanged
    # force: true entry (e.g. workbench-git's generated direnv context
    # file, redeployed whenever that module's commit changes) never
    # produces a backup with nothing new in it.
    if [[ -e "${dest}" ]] && ! cmp -s "${src}" "${dest}"; then
        workbench_backup_existing_file "${dest}" "${module}" || return 1
    fi
    if cp -f "${src}" "${dest}"; then
        log_info "  deployed (copy): ${dest}"
    else
        log_error "  failed to deploy (copy): ${dest}"
        return 1
    fi
}

workbench_deploy_link_file() {
    local src="$1" dest="$2" force="$3" module="${4:-}"
    mkdir -p "$(dirname "${dest}")"
    if [[ -L "${dest}" ]]; then
        [[ "$(readlink "${dest}")" == "${src}" ]] && return 0
        rm -f "${dest}"; ln -s "${src}" "${dest}"
        log_info "  relinked: ${dest} -> ${src}"
    elif [[ -e "${dest}" ]]; then
        [[ "${force}" != "true" ]] && { log_warn "  ${dest} exists and is not a symlink — skipping"; return 0; }
        # rm -rf below can destroy a real file OR an entire real
        # directory — back it up first (docs/decisions-log.md D53).
        # Unconditional, no content comparison: replacing a real path
        # with a symlink is a type change worth preserving even when the
        # content happened to match, unlike the copy-mode case above.
        workbench_backup_existing_file "${dest}" "${module}" || return 1
        rm -rf "${dest}"; ln -s "${src}" "${dest}"
        log_info "  deployed (link): ${dest} -> ${src}"
    else
        ln -s "${src}" "${dest}"
        log_info "  deployed (link): ${dest} -> ${src}"
    fi
}

workbench_deploy_module() {
    local name="$1"
    local current_dir src dest dest_macos mode force platforms manifest
    current_dir="$(workbench_module_current_dir "${name}")"
    [[ -d "${current_dir}" ]] || { log_warn "workbench_deploy_module: ${name}: no current snapshot yet"; return 1; }
    manifest="$(workbench_resolve_manifest_path "${current_dir}")"

    while IFS='|' read -r src dest dest_macos mode force platforms; do
        [[ -z "${src}" ]] && continue
        if [[ -n "${platforms}" ]]; then
            case "${WORKBENCH_OS:-}" in
                Mac)   printf '%s\n' "${platforms}" | tr ',' '\n' | grep -qx macos || continue ;;
                Linux) printf '%s\n' "${platforms}" | tr ',' '\n' | grep -qx linux || continue ;;
            esac
        fi
        local chosen_dest="${dest}"
        [[ "${WORKBENCH_OS:-}" == "Mac" && -n "${dest_macos}" ]] && chosen_dest="${dest_macos}"

        # D75: lexical checks first, then a symlink-aware check per target.
        if ! _wb_path_is_safe_relative "${src}" || ! _wb_dest_is_safe "${chosen_dest}" "${name}"; then
            log_error "workbench_deploy_module: ${name}: refusing unsafe deploy entry (src: ${src}, dest: ${chosen_dest})"
            continue
        fi

        local real_dest
        real_dest="$(_wb_expand_dest "${chosen_dest}")"
        local abs_src="${current_dir}/${src%/}"

        # A symlink in the snapshot can point anywhere, including outside
        # $HOME. Never deploy one — as a single-file src, or as the source a
        # link-mode entry would point at.
        if [[ -L "${abs_src}" ]]; then
            log_error "workbench_deploy_module: ${name}: refusing deploy src '${src}' — it is a symlink"
            continue
        fi

        if [[ -d "${abs_src}" ]]; then
            local file rel target
            while IFS= read -r -d '' file; do
                rel="${file#"${abs_src}"/}"
                target="${real_dest%/}/${rel}"
                if ! _wb_dest_physical_is_safe "${target}" "${name}"; then
                    log_error "workbench_deploy_module: ${name}: refusing ${target} — resolves through a symlink to a denied location"
                    continue
                fi
                if [[ "${mode}" == "link" ]]; then
                    workbench_deploy_link_file "${file}" "${target}" "${force}" "${name}"
                else
                    workbench_deploy_copy_file "${file}" "${target}" "${force}" "${name}"
                fi
            done < <(find "${abs_src}" -name .git -prune -o -type f -print0)
        elif [[ -e "${abs_src}" ]]; then
            if ! _wb_dest_physical_is_safe "${real_dest}" "${name}"; then
                log_error "workbench_deploy_module: ${name}: refusing ${real_dest} — resolves through a symlink to a denied location"
                continue
            fi
            if [[ "${mode}" == "link" ]]; then
                workbench_deploy_link_file "${abs_src}" "${real_dest}" "${force}" "${name}"
            else
                workbench_deploy_copy_file "${abs_src}" "${real_dest}" "${force}" "${name}"
            fi
        else
            log_warn "workbench_deploy_module: ${name}: deploy src not found: ${abs_src}"
        fi
    done < <(workbench_manifest_deploy_entries "${manifest}")

    # ── overrides_src (docs/decisions-log.md D48) ───────────────────────────
    # Engine-computed destination, always — never a manifest-declared
    # dest, same reasoning as register.shell[]'s engine-computed path
    # (docs/decisions-log.md D16). force is hardcoded "false", never read from the
    # manifest: this file is deployed once and is the user's from that
    # point on, permanently — there is deliberately no force: true
    # escape hatch for it, unlike an ordinary deploy[] entry.
    local overrides_src
    overrides_src="$(workbench_manifest_scalar overrides_src "${manifest}")"
    if [[ -n "${overrides_src}" ]]; then
        local abs_overrides_src="${current_dir}/${overrides_src}"
        local overrides_dest="${XDG_CONFIG_HOME:-${HOME}/.config}/workbench/local/overrides/${name}.sh"
        if [[ -f "${abs_overrides_src}" ]]; then
            workbench_deploy_copy_file "${abs_overrides_src}" "${overrides_dest}" "false" "${name}"
        else
            log_warn "workbench_deploy_module: ${name}: overrides_src not found: ${abs_overrides_src}"
        fi
    fi
}

# workbench_module_reset_targets <name>
# Lists every deploy[] entry eligible for `wb module reset`
# (docs/decisions-log.md D51) — one line per entry, `basename(real_dest)|src|real_dest`.
# Copy-mode only (mode: copy, or mode omitted — copy is the deploy[]
# default): a `mode: link` destination is already kept in sync on every
# update, so there is nothing to "reset" for it. Single-file entries only
# — a directory src is skipped; resetting an entire directory tree by one
# name is ambiguous in a way a single file isn't, and no module currently
# needs it (documented limitation, not an oversight).
#
# Deliberately re-derives real_dest (platform filter, macOS dest_macos
# override, ~-expansion) rather than calling a shared helper with
# workbench_deploy_module's own loop — that loop is the tested, hot sync
# path; duplicating this much smaller amount of logic here was judged
# lower-risk than refactoring it to share. Keep the two in sync by hand if
# either changes.
workbench_module_reset_targets() {
    local name="$1"
    local current_dir manifest
    current_dir="$(workbench_module_current_dir "${name}")"
    [[ -d "${current_dir}" ]] || return 1
    manifest="$(workbench_resolve_manifest_path "${current_dir}")"

    local src dest dest_macos mode force platforms
    while IFS='|' read -r src dest dest_macos mode force platforms; do
        [[ -z "${src}" ]] && continue
        [[ "${mode}" == "link" ]] && continue
        # D75: same lexical checks as workbench_deploy_module — reset only
        # lists targets, so an unsafe entry is skipped silently here.
        _wb_path_is_safe_relative "${src}" || continue
        local chosen_dest="${dest}"
        [[ "${WORKBENCH_OS:-}" == "Mac" && -n "${dest_macos}" ]] && chosen_dest="${dest_macos}"
        _wb_dest_is_safe "${chosen_dest}" "${name}" || continue
        local abs_src="${current_dir}/${src%/}"
        [[ -d "${abs_src}" ]] && continue

        if [[ -n "${platforms}" ]]; then
            case "${WORKBENCH_OS:-}" in
                Mac)   printf '%s\n' "${platforms}" | tr ',' '\n' | grep -qx macos || continue ;;
                Linux) printf '%s\n' "${platforms}" | tr ',' '\n' | grep -qx linux || continue ;;
            esac
        fi

        local real_dest="${dest}"
        [[ "${WORKBENCH_OS:-}" == "Mac" && -n "${dest_macos}" ]] && real_dest="${dest_macos}"
        real_dest="$(_wb_expand_dest "${real_dest}")"

        printf '%s|%s|%s\n' "$(basename "${real_dest}")" "${src}" "${real_dest}"
    done < <(workbench_manifest_deploy_entries "${manifest}")
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

# _wb_adoption_log_event stub — the real implementation lands in D77 (WP7).
# Guarded so this WP's consent-binding code can call it before WP7 merges;
# WP7 replaces this with the real append-only adoption-log writer.
command -v _wb_adoption_log_event &>/dev/null || _wb_adoption_log_event() { :; }

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
                if [[ -t 0 && -t 1 ]]; then
                    _wb_hook_describe_change "${name}" "${approved_sha}" "${current_sha}" "${argv[0]}"
                    local answer=""
                    read -r -p "Run ${name}'s post_deploy hook for ${current_sha:0:7}? [y/N]: " answer
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
