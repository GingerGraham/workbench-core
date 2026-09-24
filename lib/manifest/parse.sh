#!/usr/bin/env bash
# lib/manifest/parse.sh — hot-path manifest reader.
#
# `wb add`/`wb apply`'s initial fetch, and the sync engine's own re-check of
# a module's manifest, need to read a `.dotfiles-sync.yml` without invoking
# Ansible or depending on yq/python3 (both are fine for the developer-time
# validator in lib/manifest/validate.sh, neither is fine here — this runs on
# every hot-path/timer invocation). Pure bash + awk, reusing the
# "flatten a known-shape YAML subset with an awk state machine" technique
# workbench-precursor's install.sh already established for
# _read_external_repos_from_host_vars().
#
# This is a targeted parser for exactly the schema in
# contracts/manifest-spec.md — not a general YAML parser. It assumes
# 2-space indentation and the field ordering/shape documented there; a
# manifest that violates that shape should be caught by
# lib/manifest/validate.sh (the developer-time, yq-based validator) before
# it ever reaches this code path.

_wb_manifest_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/manifest/parse.sh" "0.4.1" || true

# The manifest schema version(s) this running core knows how to sync.
# Independent of lib/manifest/validate.sh's own
# _WB_MANIFEST_SCHEMA_VERSIONS_SUPPORTED — that script runs standalone
# without this file loaded; this constant is the hot-path's own answer to
# "what do I actually know how to process," checked live at sync time
# rather than at manifest-authoring time. See docs/decisions-log.md D30/D46.
_WB_MANIFEST_SCHEMA_VERSIONS_SUPPORTED="1 2"

# _wb_manifest_schema_supported <version>
# True iff <version> (a manifest's own top-level `version:` scalar) is one
# this running core knows how to sync. Plain space-delimited membership
# test — bash-3.2-safe, matches the pattern _WB_SCRIPT_VERSIONS/prereqs
# lists already use elsewhere rather than an associative array.
_wb_manifest_schema_supported() {
    local version="$1"
    [[ " ${_WB_MANIFEST_SCHEMA_VERSIONS_SUPPORTED} " == *" ${version} "* ]]
}

# The manifest filenames this running core will discover, in the order
# they are checked. .dotfiles-sync.yml is always last and is never
# sniff-checked below — it has been the trusted, permanent name since
# before this function existed (docs/architecture.md §5.2). See docs/decisions-log.md D46.
_WB_MANIFEST_CANDIDATE_NAMES="workbench.yml workbench.yaml wb.yml wb.yaml .dotfiles-sync.yml"

# workbench_resolve_manifest_path <dir>
# Prints the path to the manifest this module uses, or nothing (exit 1)
# if none is present. Checks _WB_MANIFEST_CANDIDATE_NAMES in order. For
# any candidate other than .dotfiles-sync.yml, the file must contain a
# top-level `version:` key to be accepted — a workbench.yml/wb.yml with
# no recognisable version: is treated as belonging to something else
# entirely (D46) and skipped, not errored on; a *wrong* version value
# for a filename that does declare one becomes a loud error downstream
# (lib/manifest/validate.sh, or the engine's own version gate), never
# silently skipped.
workbench_resolve_manifest_path() {
    local dir="$1" name candidate version
    for name in ${_WB_MANIFEST_CANDIDATE_NAMES}; do
        candidate="${dir%/}/${name}"
        [[ -f "${candidate}" ]] || continue
        if [[ "${name}" == ".dotfiles-sync.yml" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
        version="$(workbench_manifest_scalar version "${candidate}")"
        [[ -n "${version}" ]] && { printf '%s\n' "${candidate}"; return 0; }
    done
    return 1
}

# workbench_manifest_expected_version <path>
# The version: value the filename at <path> is required to declare — 1
# for .dotfiles-sync.yml (permanent), 2 for any of the new candidate
# names. Bash-3.2-safe basename dispatch, matching the case-based
# portability idiom used elsewhere rather than an associative array.
workbench_manifest_expected_version() {
    case "$(basename -- "$1")" in
        .dotfiles-sync.yml) echo 1 ;;
        workbench.yml|workbench.yaml|wb.yml|wb.yaml) echo 2 ;;
        *) return 1 ;;
    esac
}

# workbench_manifest_scalar <key> <file>
# Reads a bare top-level scalar (version, branch, core_api). Strips
# surrounding quotes and whitespace. Ported from install.sh's
# _read_yaml_scalar(), unchanged.
workbench_manifest_scalar() {
    local key="$1" file="$2"
    [[ -f "${file}" ]] || return 1
    grep "^${key}:" "${file}" 2>/dev/null \
        | head -n 1 \
        | sed "s/^${key}: *//" \
        | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/' \
        | sed -E 's/[[:space:]]+$//'
}

# workbench_manifest_sync_enabled <file>
# Reads sync.enabled — a nested scalar under a top-level `sync:` block.
# Defaults to "true" when the field or the whole block is absent (§5.3).
workbench_manifest_sync_enabled() {
    local file="$1"
    [[ -f "${file}" ]] || { echo "true"; return 0; }
    local val
    val="$(awk '
        /^sync:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[A-Za-z]/ { in_block = 0 }
        in_block && /^[[:space:]]+enabled:/ {
            line = $0
            sub(/^[[:space:]]+enabled:[[:space:]]*/, "", line)
            print line
            exit
        }
    ' "${file}")"
    val="$(printf '%s' "${val}" | tr -d '"'"'"'' | sed -E 's/[[:space:]]+$//')"
    printf '%s\n' "${val:-true}"
}

# workbench_manifest_info_description <file>
# Reads info.description — a nested scalar under a top-level `info:`
# block, same shape as sync.enabled. Unlike sync.enabled there is no
# default: an absent block, an absent field, or an absent manifest all
# just print nothing — callers (bin/wb's _wb_cmd_module_info) treat "no
# output" uniformly as "not published," not as an error.
workbench_manifest_info_description() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    awk '
        function clean(s) {
            sub(/[[:space:]]+#.*$/, "", s)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            gsub(/^"|"$/, "", s)
            gsub(/^'"'"'|'"'"'$/, "", s)
            return s
        }
        /^info:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[A-Za-z]/ { in_block = 0 }
        in_block && /^[[:space:]]+description:/ {
            line = $0
            sub(/^[[:space:]]+description:[[:space:]]*/, "", line)
            print clean(line)
            exit
        }
    ' "${file}"
}

# workbench_manifest_deploy_entries <file>
# Emits one line per deploy[] entry: src|dest|dest_macos|mode|force|platforms
# (platforms comma-joined, empty if unset). Mirrors the field set
# ansible/roles/sync-external's deploy.list.j2 already renders, minus
# Ansible-side path expansion — dest/dest_macos here are still the raw
# manifest strings (with a literal leading ~), expanded by the caller.
workbench_manifest_deploy_entries() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    awk '
        function clean(s) {
            sub(/[[:space:]]+#.*$/, "", s)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            gsub(/^"|"$/, "", s)
            gsub(/^'"'"'|'"'"'$/, "", s)
            return s
        }
        function flush() {
            if (have_item) print src "|" dest "|" dest_macos "|" mode "|" force "|" platforms
            have_item = 0; src = ""; dest = ""; dest_macos = ""; mode = "copy"; force = "false"; platforms = ""
        }
        /^deploy:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[A-Za-z]/ { flush(); in_block = 0 }
        in_block && /^[[:space:]]+-[[:space:]]*src:/ {
            flush()
            line = $0
            sub(/^[[:space:]]+-[[:space:]]*src:[[:space:]]*/, "", line)
            src = clean(line)
            have_item = 1
            next
        }
        in_block && have_item && /^[[:space:]]+dest_macos:/ {
            line = $0; sub(/^[[:space:]]+dest_macos:[[:space:]]*/, "", line); dest_macos = clean(line); next
        }
        in_block && have_item && /^[[:space:]]+dest:/ {
            line = $0; sub(/^[[:space:]]+dest:[[:space:]]*/, "", line); dest = clean(line); next
        }
        in_block && have_item && /^[[:space:]]+mode:/ {
            line = $0; sub(/^[[:space:]]+mode:[[:space:]]*/, "", line); mode = clean(line); next
        }
        in_block && have_item && /^[[:space:]]+force:/ {
            line = $0; sub(/^[[:space:]]+force:[[:space:]]*/, "", line); force = clean(line); next
        }
        in_block && have_item && /^[[:space:]]+platforms:/ {
            # Flow-sequence form only: platforms: [linux, macos]
            line = $0
            sub(/^[[:space:]]+platforms:[[:space:]]*\[/, "", line)
            sub(/\][[:space:]]*$/, "", line)
            gsub(/[[:space:]]/, "", line)
            platforms = line
            next
        }
        END { flush() }
    ' "${file}"
}

# workbench_manifest_register_shell_entries <file>
# Emits src|tier per register.shell[] entry. tier defaults to "tools" (§5.3).
workbench_manifest_register_shell_entries() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    awk '
        function clean(s) {
            sub(/[[:space:]]+#.*$/, "", s)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            gsub(/^"|"$/, "", s)
            gsub(/^'"'"'|'"'"'$/, "", s)
            return s
        }
        function flush() {
            if (have_item) print src "|" tier
            have_item = 0; src = ""; tier = "tools"
        }
        /^register:[[:space:]]*$/ { in_register = 1; next }
        in_register && /^[A-Za-z]/ { flush(); in_register = 0; in_shell = 0 }
        in_register && /^[[:space:]]{2}shell:[[:space:]]*$/ { in_shell = 1; next }
        in_register && in_shell && /^[[:space:]]{2}[A-Za-z]/ && !/^[[:space:]]{2}shell:/ { flush(); in_shell = 0 }
        in_register && in_shell && /^[[:space:]]+-[[:space:]]*src:/ {
            flush()
            line = $0
            sub(/^[[:space:]]+-[[:space:]]*src:[[:space:]]*/, "", line)
            src = clean(line)
            have_item = 1
            next
        }
        in_register && in_shell && have_item && /^[[:space:]]+tier:/ {
            line = $0; sub(/^[[:space:]]+tier:[[:space:]]*/, "", line); tier = clean(line); next
        }
        END { flush() }
    ' "${file}"
}

# workbench_manifest_register_installer_entries <file>
# Emits src per register.installers[] entry.
workbench_manifest_register_installer_entries() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    awk '
        function clean(s) {
            sub(/[[:space:]]+#.*$/, "", s)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            gsub(/^"|"$/, "", s)
            gsub(/^'"'"'|'"'"'$/, "", s)
            return s
        }
        /^register:[[:space:]]*$/ { in_register = 1; next }
        in_register && /^[A-Za-z]/ { in_register = 0; in_installers = 0 }
        in_register && /^[[:space:]]{2}installers:[[:space:]]*$/ { in_installers = 1; next }
        in_register && in_installers && /^[[:space:]]{2}[A-Za-z]/ && !/^[[:space:]]{2}installers:/ { in_installers = 0 }
        in_register && in_installers && /^[[:space:]]+-[[:space:]]*src:/ {
            line = $0
            sub(/^[[:space:]]+-[[:space:]]*src:[[:space:]]*/, "", line)
            print clean(line)
        }
    ' "${file}"
}

# workbench_manifest_register_getter_entries <file>
# Emits name|function|label per register.getters[] entry.
workbench_manifest_register_getter_entries() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    awk '
        function clean(s) {
            sub(/[[:space:]]+#.*$/, "", s)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            gsub(/^"|"$/, "", s)
            gsub(/^'"'"'|'"'"'$/, "", s)
            return s
        }
        function flush() {
            if (have_item) print name "|" fn "|" label
            have_item = 0; name = ""; fn = ""; label = ""
        }
        /^register:[[:space:]]*$/ { in_register = 1; next }
        in_register && /^[A-Za-z]/ { flush(); in_register = 0; in_getters = 0 }
        in_register && /^[[:space:]]{2}getters:[[:space:]]*$/ { in_getters = 1; next }
        in_register && in_getters && /^[[:space:]]{2}[A-Za-z]/ && !/^[[:space:]]{2}getters:/ { flush(); in_getters = 0 }
        in_register && in_getters && /^[[:space:]]+-[[:space:]]*name:/ {
            flush()
            line = $0
            sub(/^[[:space:]]+-[[:space:]]*name:[[:space:]]*/, "", line)
            name = clean(line)
            have_item = 1
            next
        }
        in_register && in_getters && have_item && /^[[:space:]]+function:/ {
            line = $0; sub(/^[[:space:]]+function:[[:space:]]*/, "", line); fn = clean(line); next
        }
        in_register && in_getters && have_item && /^[[:space:]]+label:/ {
            line = $0; sub(/^[[:space:]]+label:[[:space:]]*/, "", line); label = clean(line); next
        }
        END { flush() }
    ' "${file}"
}

# workbench_manifest_hook_post_deploy <file>
# Emits a single line: run_on|timeout|argv0|argv1|... — empty output if no
# hooks.post_deploy block is declared. command: is a YAML flow sequence
# (["a", "b"]), parsed by stripping brackets/quotes and splitting on commas.
workbench_manifest_hook_post_deploy() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    awk '
        function clean(s) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            gsub(/^"|"$/, "", s)
            gsub(/^'"'"'|'"'"'$/, "", s)
            return s
        }
        /^hooks:[[:space:]]*$/ { in_hooks = 1; next }
        in_hooks && /^[A-Za-z]/ { in_hooks = 0; in_pd = 0 }
        in_hooks && /^[[:space:]]{2}post_deploy:[[:space:]]*$/ { in_pd = 1; next }
        in_hooks && in_pd && /^[[:space:]]{2}[A-Za-z]/ && !/^[[:space:]]{2}post_deploy:/ { in_pd = 0 }
        in_hooks && in_pd && /^[[:space:]]+command:/ {
            line = $0
            sub(/^[[:space:]]+command:[[:space:]]*\[/, "", line)
            sub(/\][[:space:]]*$/, "", line)
            n = split(line, parts, ",")
            argv = ""
            for (i = 1; i <= n; i++) {
                v = clean(parts[i])
                if (v == "") continue
                argv = (argv == "" ? v : argv "|" v)
            }
            next
        }
        in_hooks && in_pd && /^[[:space:]]+run_on:/ {
            line = $0; sub(/^[[:space:]]+run_on:[[:space:]]*/, "", line); run_on = clean(line); next
        }
        in_hooks && in_pd && /^[[:space:]]+timeout:/ {
            line = $0; sub(/^[[:space:]]+timeout:[[:space:]]*/, "", line); timeout = clean(line); next
        }
        END {
            if (argv != "") print (run_on == "" ? "changed" : run_on) "|" (timeout == "" ? "300" : timeout) "|" argv
        }
    ' "${file}"
}

# ── Path safety — runtime enforcement (security review H1; D75) ──────────────
# contracts/manifest-spec.md §dest validation, enforced on the hot path. Until
# D75 these rules lived only in lib/manifest/validate.sh (developer/CI time),
# so any manifest that never went through a canonical repo's CI — every
# `wb add <n> <url>` — was deployed verbatim.
#
# The two denylist constants are deliberately duplicated in validate.sh, which
# must run standalone (same precedent as D30/D46). tests/check-dest-denylist-
# sync.sh fails if the two copies drift. Space-separated, not arrays, so the
# drift test can compare single lines.
_WB_DEST_DENYLIST_DIRS_REL=".ssh/ .gnupg/ .config/shell/ .config/git/ .config/dotfiles/ .config/workbench/ .config/external-sync/ .config/systemd/user/ library/launchagents/ .local/bin/ .local/share/workbench/ .config/autostart/ .config/environment.d/"
_WB_DEST_DENYLIST_FILES_REL=".bashrc .zshrc .profile .gitconfig .bash_profile .bash_login .bash_logout .zshenv .zprofile .zlogin .zlogout"

# _wb_path_is_safe_relative <path>
# True iff <path> is non-empty, not absolute, and has no ".." segment.
_wb_path_is_safe_relative() {
    local p="$1" rest seg
    [[ -z "${p}" ]] && return 1
    [[ "${p}" == /* ]] && return 1
    rest="${p}"
    while [[ -n "${rest}" ]]; do
        seg="${rest%%/*}"
        [[ "${seg}" == ".." ]] && return 1
        [[ "${rest}" == */* ]] || break
        rest="${rest#*/}"
    done
    return 0
}

# _wb_dest_is_safe <dest> <module-name>
# Lexical dest check. <dest> must start with ~/, have no "..", "." or empty
# segments, and not fall under the denylist. Compared lowercase so a
# case-insensitive filesystem (macOS default) can't be used to slip past it.
#
# The single exception to the .local/share/workbench/ entry is the module's own
# modules/<module-name>/files/ subtree (workbench-git deploys its excludes and
# attributes files there) — never that module's sync.conf, snapshots/, current
# or rendered lists, and never another module's directory.
_wb_dest_is_safe() {
    local d="$1" module="$2" rel lower entry
    [[ -z "${d}" ]] && return 1
    # shellcheck disable=SC2088
    [[ "${d}" == "~/"* ]] || return 1
    rel="${d#\~/}"
    [[ -z "${rel}" ]] && return 1
    case "${rel}" in
        */../*|../*|*/..|..) return 1 ;;
        *//*) return 1 ;;
        ./*|*/./*|*/.|.) return 1 ;;
    esac
    _wb_path_is_safe_relative "${rel}" || return 1

    lower="$(printf '%s' "${rel}" | tr '[:upper:]' '[:lower:]')"
    if [[ -n "${module}" && "${lower}" == ".local/share/workbench/modules/${module}/files/"?* ]]; then
        return 0
    fi
    for entry in ${_WB_DEST_DENYLIST_DIRS_REL}; do
        [[ "${lower}" == "${entry}"* ]] && return 1
    done
    for entry in ${_WB_DEST_DENYLIST_FILES_REL}; do
        [[ "${lower}" == "${entry}" ]] && return 1
    done
    return 0
}

# _wb_dest_physical_is_safe <absolute-target> <module-name>
# Symlink-aware re-check, run immediately before each write. Resolves the
# nearest existing ancestor of <target> with `pwd -P`, rebuilds the path from
# there, and re-applies _wb_dest_is_safe to the result. Catches a dest whose
# parent is (or passes through) a symlink into ~/.ssh or anywhere outside $HOME.
_wb_dest_physical_is_safe() {
    local target="$1" module="$2"
    local probe suffix phys_probe phys_home phys_target rel

    probe="$(dirname "${target}")"
    suffix="/$(basename "${target}")"
    while [[ ! -d "${probe}" ]]; do
        suffix="/$(basename "${probe}")${suffix}"
        probe="$(dirname "${probe}")"
    done
    phys_probe="$(cd "${probe}" 2>/dev/null && pwd -P)" || return 1
    phys_home="$(cd "${HOME}" 2>/dev/null && pwd -P)" || return 1
    phys_target="${phys_probe}${suffix}"

    case "${phys_target}" in
        "${phys_home}"/*) rel="${phys_target#"${phys_home}"/}" ;;
        *) return 1 ;;
    esac
    # shellcheck disable=SC2088
    _wb_dest_is_safe "~/${rel}" "${module}"
}

# workbench_manifest_paths_safe <manifest> <module-name>
# Checks every path-shaped field in a manifest. Logs one error per violation
# and returns 1 if there were any. Used as a pre-swap gate by the sync engine,
# alongside the D30 version gate.
workbench_manifest_paths_safe() {
    local file="$1" module="$2" bad=0
    local src dest dest_macos mode force platforms tier overrides_src hook_line argv0
    [[ -f "${file}" ]] || return 0

    # shellcheck disable=SC2034 # mode/force/platforms unused — only src/dest need checking here
    while IFS='|' read -r src dest dest_macos mode force platforms; do
        [[ -z "${src}" && -z "${dest}" ]] && continue
        if ! _wb_path_is_safe_relative "${src}"; then
            log_error "manifest: deploy src '${src}' is absolute or contains '..'"
            bad=1
        fi
        if ! _wb_dest_is_safe "${dest}" "${module}"; then
            log_error "manifest: deploy dest '${dest}' violates dest validation (contracts/manifest-spec.md §dest validation)"
            bad=1
        fi
        if [[ -n "${dest_macos}" ]] && ! _wb_dest_is_safe "${dest_macos}" "${module}"; then
            log_error "manifest: deploy dest_macos '${dest_macos}' violates dest validation"
            bad=1
        fi
    done < <(workbench_manifest_deploy_entries "${file}")

    overrides_src="$(workbench_manifest_scalar overrides_src "${file}")"
    if [[ -n "${overrides_src}" ]] && ! _wb_path_is_safe_relative "${overrides_src}"; then
        log_error "manifest: overrides_src '${overrides_src}' is absolute or contains '..'"
        bad=1
    fi

    # shellcheck disable=SC2034 # tier unused — only src needs checking here
    while IFS='|' read -r src tier; do
        [[ -z "${src}" ]] && continue
        if ! _wb_path_is_safe_relative "${src}"; then
            log_error "manifest: register.shell src '${src}' is absolute or contains '..'"
            bad=1
        fi
    done < <(workbench_manifest_register_shell_entries "${file}")

    while IFS= read -r src; do
        [[ -z "${src}" ]] && continue
        if ! _wb_path_is_safe_relative "${src}"; then
            log_error "manifest: register.installers src '${src}' is absolute or contains '..'"
            bad=1
        fi
    done < <(workbench_manifest_register_installer_entries "${file}")

    hook_line="$(workbench_manifest_hook_post_deploy "${file}")"
    if [[ -n "${hook_line}" ]]; then
        argv0="$(printf '%s' "${hook_line}" | cut -d'|' -f3)"
        if ! _wb_path_is_safe_relative "${argv0}"; then
            log_error "manifest: hooks.post_deploy.command[0] '${argv0}' is absolute or contains '..'"
            bad=1
        fi
    fi

    return "${bad}"
}
