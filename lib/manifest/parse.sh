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
            if (have_item) print name "|" func "|" label
            have_item = 0; name = ""; func = ""; label = ""
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
            line = $0; sub(/^[[:space:]]+function:[[:space:]]*/, "", line); func = clean(line); next
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
