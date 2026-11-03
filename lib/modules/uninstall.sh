#!/usr/bin/env bash
# lib/modules/uninstall.sh — `wb uninstall` (docs/decisions-log.md D108).
#
# Removes core: the CLI, the shell loader lines, the sync timer and core's own
# state. Modules are left exactly as they are, because their config may be
# holding the user's working setup together (an ssh_config block, a git
# identity) and what to do with it is the user's call. The loader is part of
# core, so module shell content stops in new shells; config files and blocks
# keep applying.
#
# Before anything changes, this writes REMOVAL-NOTES.md from the host's real
# state: what stayed, per module; the commands to remove it; how to come back.
# After uninstall there is no 'wb' to ask, so those notes are the only guide.
#
# Deleting core's snapshot while bin/wb runs from it is safe: bash keeps the
# script open, and unlinking an open file leaves it readable. This file and
# everything it calls are already loaded by then, nothing is sourced after
# the delete, and the working directory has moved out of the tree first.

# SC2088: a literal ~/ in text for people to read, never expanded.
# shellcheck disable=SC2088

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/modules/uninstall.sh" "0.1.0" || true

_WB_UNINSTALL_MARKER="# workbench-core loader"

_wb_uninstall_data_root() { printf '%s/workbench\n' "${XDG_DATA_HOME:-${HOME}/.local/share}"; }
_wb_uninstall_config_root() { printf '%s/workbench\n' "${XDG_CONFIG_HOME:-${HOME}/.config}"; }
_wb_uninstall_cache_root() { printf '%s/workbench\n' "${XDG_CACHE_HOME:-${HOME}/.cache}"; }

# workbench_removal_notes_path
workbench_removal_notes_path() { printf '%s/REMOVAL-NOTES.md\n' "$(_wb_uninstall_data_root)"; }

# workbench_removal_notes_link
# Where the notes are linked from, so they're in plain sight in the home
# directory. One file, in workbench's data directory; this is only a link.
workbench_removal_notes_link() { printf '%s/workbench-removal-notes.md\n' "${HOME}"; }

# _wb_uninstall_can_link
# True when the link can be made: nothing is there yet, or it's already a link
# to the notes. Anything else there belongs to the user and is left alone.
_wb_uninstall_can_link() {
    local link
    link="$(workbench_removal_notes_link)"
    [[ ! -e "${link}" && ! -L "${link}" ]] && return 0
    [[ -L "${link}" && "$(readlink "${link}")" == "$(workbench_removal_notes_path)" ]]
}

# _wb_uninstall_notes_shown
# The path to give the user for the notes: the link in the home directory
# when it can be made, otherwise the file itself.
_wb_uninstall_notes_shown() {
    if _wb_uninstall_can_link; then
        _wb_uninstall_tilde "$(workbench_removal_notes_link)"
    else
        _wb_uninstall_tilde "$(workbench_removal_notes_path)"
    fi
}

# _wb_uninstall_rewrite_cmd <filter-command> <quoted-path>
# A command that runs <filter-command> on a file and writes the result back
# through it, so a symlinked file stays a symlink.
_wb_uninstall_rewrite_cmd() {
    local filter="$1" q="$2"
    printf '%s %s > %s.wb-tmp" && cat %s.wb-tmp" > %s && rm -f %s.wb-tmp"\n' \
        "${filter}" "${q}" "${q%\"}" "${q%\"}" "${q}" "${q%\"}"
}

_WB_UNINSTALL_SSH_INCLUDE="Include ~/.ssh/config.d/*.conf"
_wb_uninstall_ssh_conf() { printf '%s/.ssh/config.d/10-workbench.conf\n' "${HOME}"; }

# _wb_uninstall_kept_modules
# Every module with state on disk except core, deregistered ones included:
# 'wb remove' leaves their files behind too.
_wb_uninstall_kept_modules() {
    local name
    while IFS= read -r name; do
        [[ -n "${name}" && "${name}" != "core" ]] && printf '%s\n' "${name}"
    done < <(workbench_list_all_modules)
}

# _wb_uninstall_rc_files
# The rc files holding a loader line.
_wb_uninstall_rc_files() {
    local rc_file
    for rc_file in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.zshenv"; do
        grep -qF "${_WB_UNINSTALL_MARKER}" "${rc_file}" 2>/dev/null && printf '%s\n' "${rc_file}"
    done
    return 0
}

# _wb_uninstall_our_link
# True when ~/.local/bin/wb is a symlink into core's state. Anything else
# there belongs to someone else.
_wb_uninstall_our_link() {
    local link="${HOME}/.local/bin/wb"
    [[ -L "${link}" ]] || return 1
    case "$(readlink "${link}")" in
        "$(workbench_module_dir core)/"*) return 0 ;;
    esac
    return 1
}

# _wb_uninstall_q <path>
# <path> (~/-form or absolute) as a double-quoted shell word, using $HOME
# when it's under the home directory so the notes read naturally.
_wb_uninstall_q() {
    local path="$1" prefix=""
    case "${path}" in
        "~/"*) path="${HOME}/${path#\~/}" ;;
    esac
    case "${path}" in
        "${HOME}/"*)
            # shellcheck disable=SC2016  # $HOME is for the reader's shell
            prefix='$HOME/'
            path="${path#"${HOME}"/}"
            ;;
    esac
    # shellcheck disable=SC2016  # the characters being escaped, not expansions
    path="$(printf '%s' "${path}" | sed 's/[\\"$`]/\\&/g')"
    printf '"%s%s"\n' "${prefix}" "${path}"
}

# _wb_uninstall_tilde <path>
# <path> for reading: ~/ in place of the home directory.
_wb_uninstall_tilde() {
    case "$1" in
        "${HOME}/"*) printf '~/%s\n' "${1#"${HOME}"/}" ;;
        *)           printf '%s\n' "$1" ;;
    esac
}

# _wb_uninstall_tools_of <module> <collected>
# Comma-separated tools of <module> that report installed. <collected> is one
# workbench_tools_collect run, so a collision warning fires only once. That run
# covers registered modules only; a module 'wb remove' deregistered still has
# its installers.list on disk, so its tools are read from there.
_wb_uninstall_tools_of() {
    local module="$1" collected="$2" lines instlist name abs_path func friendly found=""
    lines="$(printf '%s\n' "${collected}" | grep -F "${module}|" | awk -F'|' -v m="${module}" '$1 == m')"
    instlist="$(workbench_module_dir "${module}")/installers.list"
    if [[ -z "${lines}" ]] && ! workbench_is_registered "${module}" && [[ -f "${instlist}" ]]; then
        lines="$(awk -v m="${module}" 'NF { print m "|" $0 }' "${instlist}")"
    fi
    while IFS='|' read -r name abs_path func friendly; do
        [[ -n "${friendly}" ]] || continue
        if [[ "$(_wb_tools_check_installed "${name}" "${abs_path}" "${func}" "${friendly}")" == "installed" ]]; then
            found="${found:+${found}, }${friendly}"
        fi
    done <<< "${lines}"
    printf '%s\n' "${found}"
}

# _wb_uninstall_notes_module <module> <collected-tools>
# One module's section of the notes, from its own ledger — what is really on
# this host, not what the manifest declares.
_wb_uninstall_notes_module() {
    local module="$1" collected="$2" module_dir mode ref url private registered
    module_dir="$(workbench_module_dir "${module}")"
    mode="$(workbench_module_conf_get "${module}" TRACK_MODE latest)"
    ref="$(workbench_module_conf_get "${module}" TRACK_REF "")"
    url="$(workbench_module_conf_get "${module}" REPO_URL "")"
    private="$(workbench_module_conf_get "${module}" PRIVATE false)"
    registered="$(workbench_module_conf_get "${module}" REGISTERED true)"

    local active="" saved="" commands=""
    local dest kind state sha original real q target position tool start end backup
    while IFS='|' read -r dest kind state sha original _ _; do
        [[ -z "${dest}" || "${kind}" == "overrides" ]] && continue
        case "${state}" in
            active|held) ;;
            *) continue ;;
        esac
        if [[ "${kind}" == "layer" ]]; then
            target="${dest%#*}"
            position="${dest##*#}"
            real="$(_wb_expand_dest "${target}")"
            tool="$(_wb_layers_tool_for_target "${target}")"
            start="$(workbench_layers_marker_start "${module}" "${tool}" "${position}")"
            end="$(workbench_layers_marker_end "${module}" "${tool}" "${position}")"
            grep -qF "${start}" "${real}" 2>/dev/null || continue
            q="$(_wb_uninstall_q "${target}")"
            if [[ "${position}" == "over" ]]; then
                active="${active}  - \`${target}\`: a marked workbench block, placed so it wins over your settings.
"
            else
                active="${active}  - \`${target}\`: a marked workbench block. Your own settings in that file win over it.
"
            fi
            commands="${commands}# Delete the workbench block from ${target}
sed '\\|${start}|,\\|${end}|d' ${q} > ${q%\"}.wb-tmp\" && cat ${q%\"}.wb-tmp\" > ${q} && rm -f ${q%\"}.wb-tmp\"
"
            if [[ "${original}" == "+created" ]]; then
                commands="${commands}# Workbench created ${target}: delete it if nothing else is in it now.
"
            elif [[ -n "${original}" && "${original}" != "-" ]]; then
                saved="${saved}  - \`${target}\`, as it was before you switched to this module's version: \`$(_wb_uninstall_tilde "${original}")\`
"
            fi
            continue
        fi

        real="$(_wb_expand_dest "${dest%/}")"
        case "${real}" in
            "${module_dir}/"*) continue ;;  # goes when the module's directory does
        esac
        q="$(_wb_uninstall_q "${dest%/}")"
        if [[ "${sha}" == link:* ]]; then
            _wb_files_is_our_link "${module}" "${real}" || continue
            active="${active}  - \`${dest%/}\`: a link into this module's directory. It breaks if that directory is deleted.
"
            commands="${commands}rm -f ${q}
"
        elif [[ -f "${real}" && ! -L "${real}" ]]; then
            if [[ "$(_wb_sha256 "${real}")" == "${sha}" ]]; then
                active="${active}  - \`${dest%/}\`: a copied file.
"
                commands="${commands}rm -f ${q}
"
            else
                active="${active}  - \`${dest%/}\`: a copied file you've changed since workbench wrote it.
"
                commands="${commands}rm -f ${q}  # holds your changes: check it first
"
            fi
        else
            continue
        fi
        if [[ -n "${original}" && "${original}" != "-" && -e "${original}" ]]; then
            backup="$(_wb_uninstall_q "${original}")"
            saved="${saved}  - \`${dest%/}\`, as it was before workbench: \`$(_wb_uninstall_tilde "${original}")\`
"
            commands="${commands}cp -a ${backup} ${q}  # puts back your original
"
        fi
    done < <(workbench_files_ledger_rows "${module}")

    local displaced_file put_back from
    displaced_file="$(workbench_files_displaced_path "${module}")"
    if [[ -f "${displaced_file}" ]]; then
        while IFS='|' read -r _ put_back from; do
            [[ -n "${put_back}" && -e "${from}" ]] || continue
            saved="${saved}  - \`${put_back}\`, moved aside for this module: \`$(_wb_uninstall_tilde "${from}")\`
"
            commands="${commands}cp -a $(_wb_uninstall_q "${from}") $(_wb_uninstall_q "${put_back}")  # puts back your own file
"
        done < <(grep -v '^#' "${displaced_file}")
    fi

    local reglist getters filepath shell_files="" label labels="" tools key_file="" has_key="false"
    reglist="${module_dir}/register.list"
    if [[ -f "${reglist}" ]]; then
        while IFS='|' read -r filepath _; do
            [[ -n "${filepath}" ]] && shell_files="${shell_files:+${shell_files}, }$(basename "${filepath}")"
        done < "${reglist}"
    fi
    getters="${module_dir}/getters.list"
    if [[ -f "${getters}" ]]; then
        while IFS='|' read -r _ label; do
            [[ -n "${label}" ]] && labels="${labels:+${labels}; }${label}"
        done < "${getters}"
    fi
    tools="$(_wb_uninstall_tools_of "${module}" "${collected}")"
    key_file="${HOME}/.ssh/workbench-${module}"
    [[ "${private}" == "true" && -e "${key_file}" ]] && has_key="true"
    local has_host="false" ssh_conf
    ssh_conf="$(_wb_uninstall_ssh_conf)"
    grep -qx "Host workbench-${module}" "${ssh_conf}" 2>/dev/null && has_host="true"

    echo "### ${module}"
    echo
    if [[ "${mode}" == "latest" ]]; then
        echo "Version: ${ref:-unknown}, following the latest release."
    else
        echo "Version: ${ref:-unknown}, pinned (${mode})."
    fi
    [[ -n "${url}" ]] && echo "Source: ${url}"
    [[ "${registered}" == "true" ]] || echo "You had already deregistered this module with 'wb remove'."
    echo
    if [[ -n "${shell_files}" && "${registered}" == "true" ]]; then
        echo "- **Stopped in new shells:** ${shell_files}"
        [[ -n "${labels}" ]] && echo "  (${labels})"
    fi
    if [[ -n "${active}" ]]; then
        echo "- **Still applying:**"
        printf '%s' "${active}"
    fi
    if [[ -n "${saved}" ]]; then
        echo "- **Your originals, saved in backups:**"
        printf '%s' "${saved}"
    fi
    if [[ -n "${tools}" ]]; then
        echo "- **Software this module can install, found on this machine:** ${tools}."
        echo "  Workbench didn't remove it, and some of it may predate workbench."
    fi
    if [[ "${has_key}" == "true" ]]; then
        echo "- **SSH deploy key:** \`~/.ssh/workbench-${module}\`, with a \`Host workbench-${module}\` entry in \`~/.ssh/config.d/10-workbench.conf\`."
    fi
    echo
    echo "To remove what this module left behind:"
    echo
    echo '```sh'
    printf '%s' "${commands}"
    if [[ "${has_key}" == "true" ]]; then
        # shellcheck disable=SC2016  # $HOME is for the reader's shell
        printf 'rm -f "$HOME/.ssh/workbench-%s" "$HOME/.ssh/workbench-%s.pub"  # also revoke this deploy key on the repo\n' "${module}" "${module}"
    fi
    if [[ "${has_host}" == "true" ]]; then
        echo "# Delete the Host workbench-${module} entry from ~/.ssh/config.d/10-workbench.conf"
        _wb_uninstall_rewrite_cmd "awk '/^Host / { skip = (\$2 == \"workbench-${module}\") } !skip'" "$(_wb_uninstall_q "${ssh_conf}")"
    fi
    echo "rm -rf $(_wb_uninstall_q "${module_dir}")"
    echo '```'
    echo
}

# _wb_uninstall_kept_ssh
# Prints what workbench put in SSH config that is still there, one word per
# line: 'include' for the Include line in ~/.ssh/config, 'conf' for
# ~/.ssh/config.d/10-workbench.conf.
_wb_uninstall_kept_ssh() {
    grep -qxF "${_WB_UNINSTALL_SSH_INCLUDE}" "${HOME}/.ssh/config" 2>/dev/null && echo include
    [[ -f "$(_wb_uninstall_ssh_conf)" ]] && echo conf
    return 0
}

# _wb_uninstall_notes_ssh
# The SSH part of "Left behind on purpose": what is there, why it stayed, and
# commands that remove it without taking anything of the user's with it.
_wb_uninstall_notes_ssh() {
    local kept="$1" dir others="" entry q_conf q_dir q_config
    dir="${HOME}/.ssh/config.d"
    for entry in "${dir}"/*; do
        [[ -e "${entry}" && "${entry}" != "$(_wb_uninstall_ssh_conf)" ]] || continue
        others="${others:+${others}, }\`$(basename "${entry}")\`"
    done
    q_conf="$(_wb_uninstall_q "$(_wb_uninstall_ssh_conf)")"
    q_dir="$(_wb_uninstall_q "${dir}")"
    q_config="$(_wb_uninstall_q "${HOME}/.ssh/config")"

    echo "### SSH configuration"
    echo
    case "${kept}" in
        *conf*) echo "- \`~/.ssh/config.d/10-workbench.conf\` holds the SSH settings for private modules' deploy keys." ;;
    esac
    case "${kept}" in
        *include*) echo "- The line \`${_WB_UNINSTALL_SSH_INCLUDE}\` in \`~/.ssh/config\` makes SSH read every file in \`~/.ssh/config.d/\`." ;;
    esac
    echo
    echo "**Why it was left:** SSH reads the whole of \`~/.ssh/config.d/\`, not just workbench's file. Other tools, or you, may keep SSH settings there too, and taking the \`Include\` line out would quietly stop SSH using them, which can break connections you rely on."
    if [[ -n "${others}" ]]; then
        echo "Right now that folder also holds: ${others}."
    fi
    echo
    echo "**If you don't want it:**"
    echo
    echo '```sh'
    case "${kept}" in
        *conf*) echo "rm -f ${q_conf}" ;;
    esac
    case "${kept}" in
        *include*)
            if [[ -d "${dir}" ]]; then
                echo "# Removes the folder and the Include line, but only if nothing else is in the folder."
                echo "if rmdir ${q_dir} 2>/dev/null; then"
                printf '    %s' "$(_wb_uninstall_rewrite_cmd "sed '\\|^Include ~/\\.ssh/config\\.d/\\*\\.conf\$|d'" "${q_config}")"
                echo
                echo "else"
                echo "    echo \"~/.ssh/config.d still has other files in it, so it and the Include line stay\""
                echo "fi"
            else
                _wb_uninstall_rewrite_cmd "sed '\\|^Include ~/\\.ssh/config\\.d/\\*\\.conf\$|d'" "${q_config}"
            fi
            ;;
    esac
    echo '```'
    echo
}

# _wb_uninstall_write_notes <file>
_wb_uninstall_write_notes() {
    local file="$1" module collected any="false" rc_file tools all_tools="" kept_ssh shown_link
    collected="$(workbench_tools_collect 2>/dev/null)"
    tools="$(_wb_uninstall_tools_of core "${collected}")"
    [[ -n "${tools}" ]] && all_tools="${tools} (core)"
    while IFS= read -r module; do
        [[ -z "${module}" ]] && continue
        tools="$(_wb_uninstall_tools_of "${module}" "${collected}")"
        [[ -n "${tools}" ]] && all_tools="${all_tools:+${all_tools}; }${tools} (${module})"
    done < <(_wb_uninstall_kept_modules)
    kept_ssh="$(_wb_uninstall_kept_ssh | paste -sd' ' -)"
    shown_link="$(_wb_uninstall_tilde "$(workbench_removal_notes_link)")"
    {
        echo "# Workbench removal notes"
        echo
        echo "Written by \`wb uninstall\` on $(date +%Y-%m-%d), from what was on this machine at the time."
        echo
        echo "## What was removed"
        echo
        echo "- The \`wb\` command (\`~/.local/bin/wb\`)."
        while IFS= read -r rc_file; do
            [[ -n "${rc_file}" ]] && echo "- The workbench loader line in \`$(_wb_uninstall_tilde "${rc_file}")\`."
        done < <(_wb_uninstall_rc_files)
        if workbench_scheduler_enabled; then
            echo "- The scheduled sync timer."
        fi
        echo "- Core's own files: \`$(_wb_uninstall_tilde "$(workbench_module_dir core)")\`, \`$(_wb_uninstall_tilde "$(_wb_uninstall_config_root)/core")\` and \`$(_wb_uninstall_tilde "$(_wb_uninstall_cache_root)")\`."
        echo
        echo "## What this changes"
        echo
        echo "- New shells no longer load anything from workbench. That covers every module's functions, aliases, prompt setup and completions, plus any \`PATH\` entries and environment variables they set."
        echo "- Workbench no longer makes sure \`~/.local/bin\` is on your \`PATH\`. If a tool stops being found, add \`export PATH=\"\$HOME/.local/bin:\$PATH\"\` to your shell's rc file."
        echo "- Nothing updates any more."
        echo "- Config files and config blocks left by modules still apply, listed below."
        echo
        echo "Terminals that were already open keep workbench's functions until you close them."
        echo
        echo "## Left behind on purpose"
        echo
        echo "Some things were left where they are on purpose, so that removing workbench didn't break anything you might still be using. Each one below says where it is, why it was left, and how to remove it if you don't want it."
        echo
        if [[ "$(_wb_uninstall_kept_modules)" != "" ]]; then
            echo "### Your modules' config"
            echo
            echo "Each module under **Modules left in place** below lists the config files and blocks it put on this machine."
            echo
            echo "**Why it was left:** your tools may be relying on it right now: a git identity, an SSH host, an editor or terminal setup. Taking it out without asking could break something you depend on."
            echo
            echo "**If you don't want it:** each module's section ends with the commands that take its config out and put back what it replaced."
            echo
        fi
        echo "### Backups of your files"
        echo
        echo "\`$(_wb_uninstall_tilde "$(_wb_uninstall_data_root)/backups")\`"
        echo
        echo "**Why it was left:** it holds your own files as they were before workbench changed them. The module commands below use it to put them back."
        echo
        echo "**If you don't want it:** run the module commands you want first, because they put your files back from here. Then check it for anything you want to keep, and run:"
        echo
        echo '```sh'
        echo "rm -rf $(_wb_uninstall_q "$(_wb_uninstall_data_root)/backups")"
        echo '```'
        echo
        echo "### Your workbench settings"
        echo
        echo "\`$(_wb_uninstall_tilde "$(_wb_uninstall_config_root)")\`"
        echo
        echo "**Why it was left:** it holds your overrides and any custom catalog, so reinstalling picks them up as you left them."
        echo
        echo "**If you don't want it:**"
        echo
        echo '```sh'
        echo "rm -rf $(_wb_uninstall_q "$(_wb_uninstall_config_root)")"
        echo '```'
        echo
        [[ -n "${kept_ssh}" ]] && _wb_uninstall_notes_ssh "${kept_ssh}"
        if [[ -n "${all_tools}" ]]; then
            echo "### Software installed through workbench"
            echo
            echo "Found on this machine: ${all_tools}."
            echo
            echo "**Why it was left:** you may be using it, and some of it may have been here before workbench. Workbench can't tell which it installed, so it left all of it."
            echo
            echo "**If you don't want it:** remove it the way you'd remove any other software, for example \`sudo dnf remove <name>\` or \`sudo apt remove <name>\`. Tools installed from an upstream release, not a package, are files in \`~/.local/bin\`: delete the file there."
            echo
        fi
        echo "### These notes"
        echo
        echo "\`${shown_link}\` is a link to \`$(_wb_uninstall_tilde "$(workbench_removal_notes_path)")\`, so it's easy to find. Reinstalling workbench removes both."
        echo
        echo "## Modules left in place"
        echo
        while IFS= read -r module; do
            [[ -z "${module}" ]] && continue
            any="true"
            _wb_uninstall_notes_module "${module}" "${collected}"
        done < <(_wb_uninstall_kept_modules)
        [[ "${any}" == "true" ]] || { echo "None: you had no modules installed besides core."; echo; }
        echo "## Coming back"
        echo
        echo '```sh'
        echo 'curl -fsSLO https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh'
        echo 'bash bootstrap.sh'
        echo '```'
        echo
        echo "Modules still listed above load again as they were, on the same versions. For one whose directory you deleted, run \`wb add <name>\`. If it wasn't in workbench's catalog, use \`wb add <name> <url>\`, with \`--private\` for a private repo."
        if workbench_scheduler_enabled; then
            echo
            echo "Scheduled sync was on. It stays off after reinstalling until you run \`wb scheduler enable\`."
        fi
        echo
        echo "## Removing everything"
        echo
        echo "1. Run the commands under each module above. Do this first, because they use the backups."
        [[ -n "${kept_ssh}" ]] && echo "1. Run the SSH commands above, if you don't want those either."
        echo "1. Check the backups for anything you want to keep, then run:"
        echo
        echo '```sh'
        echo "rm -rf $(_wb_uninstall_q "$(_wb_uninstall_data_root)")  # includes the backups and these notes"
        echo "rm -rf $(_wb_uninstall_q "$(_wb_uninstall_config_root)")"
        echo "rm -f $(_wb_uninstall_q "$(workbench_removal_notes_link)")"
        echo '```'
    } > "${file}"
}

# _wb_uninstall_preview <modules-csv>
_wb_uninstall_preview() {
    local modules="$1" module rc_file
    echo
    echo "wb uninstall removes:"
    echo "  - the wb command"
    while IFS= read -r rc_file; do
        [[ -n "${rc_file}" ]] && echo "  - the loader line in $(_wb_uninstall_tilde "${rc_file}")"
    done < <(_wb_uninstall_rc_files)
    workbench_scheduler_enabled && echo "  - the scheduled sync timer"
    echo "  - core's own files"
    echo
    if [[ -z "${modules}" ]]; then
        echo "You have no other modules installed."
    else
        echo "Your modules stay in place: ${modules}"
        echo "Their config files and blocks keep applying, but their functions, aliases and"
        echo "prompt setup stop in new shells. Those are loaded by the part being removed."
        echo
        echo "To take a module's config out as well, stop here and run this first, because"
        echo "it won't be available afterwards:"
        while IFS= read -r module; do
            [[ -n "${module}" ]] && echo "  wb remove ${module} --restore"
        done < <(workbench_list_registered_modules | grep -vx core)
    fi
    echo
    echo "Some things are left behind on purpose, so nothing you still use breaks."
    echo "Afterwards, $(_wb_uninstall_notes_shown) says what they are, why"
    echo "they were left, how to remove them, and how to come back."
    echo
}

# _wb_uninstall_strip_rc <rc-file>
# Removes each loader line and the blank line _wb_write_rc_stub put before it,
# leaving every other line alone. Never restores a D64 backup: the user may
# have edited the file since. Writes through the existing file, so a symlinked
# rc file stays a symlink.
_wb_uninstall_strip_rc() {
    local rc_file="$1" tmp
    tmp="$(mktemp)" || return 1
    awk -v m="${_WB_UNINSTALL_MARKER}" '
        index($0, m) { pending = 0; next }
        pending { print ""; pending = 0 }
        $0 == "" { pending = 1; next }
        { print }
        END { if (pending) print "" }
    ' "${rc_file}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
    cat "${tmp}" > "${rc_file}" || { rm -f "${tmp}"; return 1; }
    rm -f "${tmp}"
}

# _wb_uninstall_stop_scheduler
# Stops the timer and any sync it has already started, whether or not the
# host-wide switch is on: a timer left behind would keep calling a command
# that no longer exists, and a running sync could recreate what's being
# deleted. Stopping the oneshot service ends that sync without needing a lock.
_wb_uninstall_stop_scheduler() {
    if [[ "${WORKBENCH_OS:-}" == "Mac" ]]; then
        _workbench_scheduler_uninstall_macos
    else
        if command -v systemctl &>/dev/null; then
            systemctl --user stop workbench-sync.service &>/dev/null || true
        fi
        _workbench_scheduler_uninstall_linux
    fi
}

# workbench_cmd_uninstall [--yes] [--dry-run]
workbench_cmd_uninstall() {
    local yes="false" dry_run="false" rc
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y)  yes="true" ;;
            --dry-run) dry_run="true" ;;
            *)
                log_error "wb uninstall: unknown argument '$1'"
                return 2
                ;;
        esac
        shift
    done

    _wb_engine_require_files
    _wb_require sync/scheduler.sh

    local data_root notes tmp_notes modules="" module
    data_root="$(_wb_uninstall_data_root)"
    notes="$(workbench_removal_notes_path)"
    while IFS= read -r module; do
        [[ -n "${module}" ]] && modules="${modules:+${modules}, }${module}"
    done < <(_wb_uninstall_kept_modules)

    # Written first, and required: never remove anything the notes can't
    # account for.
    tmp_notes="$(mktemp)" || { log_error "wb uninstall: couldn't create a temp file — nothing was changed"; return 1; }
    if ! _wb_uninstall_write_notes "${tmp_notes}"; then
        log_error "wb uninstall: couldn't write the removal notes — nothing was changed"
        rm -f "${tmp_notes}"
        return 1
    fi

    _wb_uninstall_preview "${modules}"
    if [[ "${dry_run}" == "true" ]]; then
        echo "Dry run: nothing was changed. The notes would say:"
        echo
        cat "${tmp_notes}"
        rm -f "${tmp_notes}"
        return 0
    fi

    rc=0
    _wb_files_confirm "${yes}" "wb uninstall" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        rm -f "${tmp_notes}"
        [[ "${rc}" -eq 2 ]] && return 0
        return "${rc}"
    fi

    mkdir -p "${data_root}"
    if ! cat "${tmp_notes}" > "${notes}"; then
        log_error "wb uninstall: couldn't write ${notes} — nothing was changed"
        rm -f "${tmp_notes}"
        return 1
    fi
    rm -f "${tmp_notes}"

    # One file, linked from the home directory so it's in plain sight. A file
    # of the user's already at that path is left alone (D108).
    local shown link
    link="$(workbench_removal_notes_link)"
    shown="$(_wb_uninstall_tilde "${notes}")"
    if _wb_uninstall_can_link; then
        ln -sfn "${notes}" "${link}" && shown="$(_wb_uninstall_tilde "${link}")"
    else
        log_warn "wb uninstall: $(_wb_uninstall_tilde "${link}") already exists and isn't workbench's, so it was left alone — the notes are at ${shown}"
    fi

    cd "${HOME}" || cd / || true

    # From here every step runs even if an earlier one fails. Each failure is
    # recorded in the notes, and a leftover is harmless: the loader line
    # checks the file exists before sourcing it.
    local -a problems=()
    _wb_uninstall_stop_scheduler >/dev/null 2>&1

    local rc_file
    while IFS= read -r rc_file; do
        [[ -z "${rc_file}" ]] && continue
        _wb_uninstall_strip_rc "${rc_file}" || problems+=("the loader line in $(_wb_uninstall_tilde "${rc_file}") — delete the line ending '${_WB_UNINSTALL_MARKER}'")
    done < <(_wb_uninstall_rc_files)

    if _wb_uninstall_our_link; then
        rm -f "${HOME}/.local/bin/wb" || problems+=("~/.local/bin/wb")
    fi
    rm -rf "$(_wb_uninstall_config_root)/core" || problems+=("$(_wb_uninstall_tilde "$(_wb_uninstall_config_root)/core")")
    rm -rf "$(_wb_uninstall_cache_root)" || problems+=("$(_wb_uninstall_tilde "$(_wb_uninstall_cache_root)")")
    rm -rf "$(workbench_module_dir core)" || problems+=("$(_wb_uninstall_tilde "$(workbench_module_dir core)")")

    echo
    echo "Workbench and the wb command have been removed."
    echo
    if [[ -n "${modules}" ]]; then
        echo "You had these modules installed: ${modules}."
        echo "They're still in place and their config still applies, but their functions and"
        echo "aliases stop in new shells."
        echo
    fi
    echo "Some things were left behind on purpose, so nothing you still use breaks."
    echo "What they are, why each one was left, how to remove it, and how to come"
    echo "back are in:"
    echo "  ${shown}"
    echo
    echo "Open a new terminal to finish. This one still has workbench loaded."

    if [[ "${#problems[@]}" -gt 0 ]]; then
        local problem
        {
            echo
            echo "## Couldn't be removed"
            echo
            for problem in "${problems[@]}"; do
                echo "- ${problem}"
            done
        } >> "${notes}"
        echo
        for problem in "${problems[@]}"; do
            log_warn "wb uninstall: couldn't remove ${problem}"
        done
        return 1
    fi
    return 0
}
