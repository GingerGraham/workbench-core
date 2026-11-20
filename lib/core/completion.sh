#!/usr/bin/env bash
# lib/core/completion.sh — workbench-core
#
# Generates bash/zsh tab-completion scripts for the 'wb' CLI itself
# (Phase 1: top-level subcommand completion only — no argument-level
# completion of module/tool/bundle names yet; see docs/decisions-log.md
# D44 for the follow-up this deliberately defers). Command names are
# never hand-maintained here: they're introspected straight out of
# bin/wb's own dispatch case statement, the same plain-text-introspection
# technique _extract_function_names already uses for register.shell
# content (lib/core/functions.sh) — so this list can never drift from
# what 'wb' actually dispatches on.

# shellcheck source=lib/core/log.sh
_wb_completion_dir="$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
[[ -f "${_wb_completion_dir}/log.sh" ]] && source "${_wb_completion_dir}/log.sh"
unset _wb_completion_dir

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/core/completion.sh" "0.7.1" || true

# _wb_completion_dispatch_commands
# Prints one dispatch-case command per line, in source order, by reading
# bin/wb's own `case "${_wb_cmd}" in ... esac` block as plain text. Never
# sources bin/wb — introspection only. The regex requires a leading
# lowercase letter, which naturally excludes both the `-h|--help|"")`
# and `*)` branches without special-casing them.
_wb_completion_dispatch_commands() {
    local wb_src="${WB_ROOT}/bin/wb"
    if [[ ! -f "${wb_src}" ]]; then
        log_error "wb completion: can't find bin/wb at '${wb_src}' to introspect"
        return 1
    fi
    awk '
        /^case "\$\{_wb_cmd\}" in$/ { in_case=1; next }
        in_case && /^esac$/ { in_case=0 }
        in_case { print }
    ' "${wb_src}" \
        | grep -oE '^[[:space:]]*[a-z][a-zA-Z0-9_-]*\)' \
        | tr -d ' )'
}

# _wb_completion_subdispatch_commands <function-name>
# Prints one sub-command per line, in source order, by reading the named
# bin/wb function's own `case "${sub}" in ... esac` block as plain text —
# the same never-sourced, plain-text-introspection technique
# _wb_completion_dispatch_commands already uses for the top-level dispatch
# case, generalised to work on any of bin/wb's five sub-dispatchers
# (_wb_cmd_tools/_wb_cmd_module/_wb_cmd_files/_wb_cmd_sync/_wb_cmd_scheduler) instead of
# hand-listing each one's sub-commands a second time.
#
# Scoped to the named function's own body first — bin/wb has five
# separate `case "${sub}" in` blocks with identical opening text, one per
# sub-dispatcher, so matching on the case-open line alone would conflate
# them. Unlike the top-level dispatch, a label here can be pipe-combined
# on one line (_wb_cmd_sync's `enable|disable)` arm) — the regex captures
# the whole label text before splitting on `|`, so this handles both
# `list)`-style and `enable|disable)`-style arms without a second code
# path.
_wb_completion_subdispatch_commands() {
    local func_name="$1"
    local wb_src="${WB_ROOT}/bin/wb"
    if [[ ! -f "${wb_src}" ]]; then
        log_error "wb completion: can't find bin/wb at '${wb_src}' to introspect"
        return 1
    fi
    awk -v fn="${func_name}" '
        $0 == fn "() {" { in_fn=1 }
        in_fn && /^[[:space:]]*case "\$\{sub\}" in$/ { in_case=1; next }
        in_fn && in_case && /^[[:space:]]*esac$/ { in_case=0 }
        in_fn && in_case { print }
        in_fn && /^}$/ { in_fn=0 }
    ' "${wb_src}" \
        | grep -oE '^[[:space:]]*[a-z][a-zA-Z0-9_|-]*\)' \
        | tr -d ' )' \
        | tr '|' '\n'
}

# _wb_completion_function_flags <function-name> [<depth>]
# Prints the long flags (--name) the named function parses, one per line, by
# reading its `case` arms as plain text — never sourced. The function can be
# defined in bin/wb or any lib/modules/*.sh. An arm counts when its label
# list contains a `--flag`; labels are split on '|'. Left out on purpose:
#   --help      every command has it
#   --*, -*     catch-all arms
#   an arm whose whole body is `;;` — a flag that is accepted but does
#     nothing (a retired one, like `wb install --skip-ansible`), which a
#     person shouldn't be offered
# A function that only forwards to another (`_wb_cmd_module_reset() {
# _wb_cmd_files_use "$@"; }`) reports that function's flags.
_wb_completion_function_flags() {
    local func_name="$1" depth="${2:-0}" files body target
    files="${WB_ROOT}/bin/wb"
    local f
    for f in "${WB_ROOT}"/lib/modules/*.sh; do
        [[ -f "${f}" ]] && files="${files} ${f}"
    done
    # shellcheck disable=SC2086  # files is a space-separated list of paths without spaces
    body="$(awk -v fn="${func_name}" '
        $0 == fn "() {" { in_fn=1; next }
        in_fn && /^}$/ { in_fn=0 }
        in_fn { print }
    ' ${files})"
    [[ -z "${body}" ]] && return 0

    # Forwarder: one statement, `<function> "$@"`.
    if [[ "${depth}" -lt 3 ]]; then
        target="$(printf '%s\n' "${body}" | grep -vE '^[[:space:]]*(#|$)' | awk 'NR == 1 { first = $0 } END { if (NR == 1 && first ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]+"\$@"[[:space:]]*$/) { gsub(/^[[:space:]]+|[[:space:]]+"\$@"[[:space:]]*$/, "", first); print first } }')"
        if [[ -n "${target}" ]]; then
            _wb_completion_function_flags "${target}" $((depth + 1))
            return 0
        fi
    fi

    printf '%s\n' "${body}" | awk '
        /^[[:space:]]*-[^)]*\)/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            label = line; sub(/\).*$/, "", label)
            rest = line; sub(/^[^)]*\)[[:space:]]*/, "", rest)
            if (rest ~ /^;;[[:space:]]*$/) next
            n = split(label, parts, "|")
            for (i = 1; i <= n; i++)
                if (parts[i] ~ /^--[a-z][a-z0-9-]*$/ && parts[i] != "--help" && !(parts[i] in seen)) {
                    seen[parts[i]] = 1
                    print parts[i]
                }
        }
    '
}

# _wb_completion_command_flags <command> [<sub-command>]
# The long flags of a flat command (`wb add`), or of one sub-command of a
# group (`wb files use`). Flat commands read `_wb_cmd_<command>` and
# `workbench_cmd_<command>` plus any helper function that extends one of
# those names (`_wb_cmd_functions_impl`); a sub-command reads
# `_wb_cmd_<command>_<sub-command>`. Sorted, one per line, no duplicates.
_wb_completion_command_flags() {
    local cmd="$1" sub="${2:-}" fn funcs src
    if [[ -n "${sub}" ]]; then
        funcs="_wb_cmd_${cmd}_${sub//-/_}"
    else
        funcs=""
        for src in "${WB_ROOT}/bin/wb" "${WB_ROOT}"/lib/modules/*.sh; do
            [[ -f "${src}" ]] || continue
            funcs="${funcs} $(grep -oE "^(_wb_cmd_|workbench_cmd_)${cmd//-/_}(_[a-z_]+)?\(\)" "${src}" | tr -d '()')"
        done
    fi
    for fn in ${funcs}; do
        _wb_completion_function_flags "${fn}"
    done | sort -u
}

# _wb_completion_flag_case <sub-command-expression>
# Prints a `case` statement for the generated scripts that sets _wb_flags to
# the space-separated flags of the command on the line. <sub-command-
# expression> is how that shell reads the word after the command (bash and
# zsh index their word arrays differently). Group commands get a nested case
# per sub-command; commands with no flags get no arm.
_wb_completion_flag_case() {
    local sub_expr="$1" cmd subs sub flags sub_flags dispatch group
    dispatch="$(_wb_completion_dispatch_commands)"
    # shellcheck disable=SC2016  # ${cmd} is for the generated script to expand
    printf '        case "${cmd}" in\n'
    while IFS= read -r cmd; do
        [[ -z "${cmd}" ]] && continue
        subs="$(_wb_completion_subdispatch_commands "_wb_cmd_${cmd}" 2>/dev/null)"
        if [[ -n "${subs}" ]]; then
            group=""
            while IFS= read -r sub; do
                [[ -z "${sub}" ]] && continue
                sub_flags="$(_wb_completion_command_flags "${cmd}" "${sub}" | paste -sd' ' -)"
                [[ -z "${sub_flags}" ]] && continue
                group="${group}                ${sub}) _wb_flags=\"${sub_flags}\" ;;"$'\n'
            done <<< "${subs}"
            if [[ -n "${group}" ]]; then
                printf '            %s)\n                case "%s" in\n%s                esac\n                ;;\n' "${cmd}" "${sub_expr}" "${group}"
            fi
        else
            flags="$(_wb_completion_command_flags "${cmd}" | paste -sd' ' -)"
            [[ -n "${flags}" ]] && printf '            %s) _wb_flags="%s" ;;\n' "${cmd}" "${flags}"
        fi
    done <<< "${dispatch}"
    printf '        esac\n'
}

# _wb_cmd_complete <kind>
# Hidden, internal-only fast path consumed by the generated bash/zsh
# completion scripts at keystroke time (Phase 2, docs/decisions-log.md
# D54) — never meant to be typed by a person, and deliberately absent
# from any help text. An identifier starting with '_' can't match
# _wb_completion_dispatch_commands' own '[a-z]'-leading regex, so
# 'wb <TAB>' itself never offers it — no separate exclusion list needed
# to keep it hidden.
#
# Prints one candidate per line on success; prints and returns nothing
# on an unrecognised kind. Never log_error/log_warn here — this runs
# inside a completion context on every keystroke, and anything written
# to stderr would corrupt what the person sees while typing.
_wb_cmd_complete() {
    local kind="${1:-}"
    case "${kind}" in
        registered-modules) workbench_list_registered_modules ;;
        catalog-modules)    _wb_require modules/catalog.sh; workbench_catalog_list_modules ;;
        catalog-bundles)    _wb_require modules/catalog.sh; workbench_catalog_list_bundles ;;
        tools)              workbench_tools_collect 2>/dev/null | cut -d'|' -f4 ;;
        layer-ids)          _wb_complete_layer_ids "${2:-}" ;;
        reset-targets)      _wb_complete_reset_targets "${2:-}" ;;
        *)                  return 1 ;;
    esac
}

# _wb_complete_reset_targets <module>
# 'wb module reset <module> <TAB>' and 'wb files use <module> <TAB>' (D122):
# the module's own deploy targets, as the dest each declares — the one form
# the resolver always accepts, where a basename can be ambiguous. Read fresh
# from the module's current manifest every time, so they follow what the
# module ships now. Nothing for a module that isn't registered or has no
# synced snapshot: a name that would fail is never offered.
_wb_complete_reset_targets() {
    local module="$1" dest
    [[ -n "${module}" ]] && workbench_valid_module_name "${module}" 2>/dev/null || return 0
    workbench_is_registered "${module}" 2>/dev/null || return 0
    [[ -d "$(workbench_module_current_dir "${module}")" ]] || return 0
    _wb_engine_require_files >/dev/null 2>&1 || return 0
    while IFS='|' read -r _ _ dest _; do
        [[ -n "${dest}" ]] && printf '%s\n' "${dest}"
    done < <(workbench_files_targets "${module}" 2>/dev/null)
    return 0
}

# _wb_complete_layer_ids [<module>]
# 'wb add <module> --skip-layer <TAB>' (docs/decisions-log.md D82): the
# module's own layer ids when it has a synced snapshot here, otherwise
# every id a layer can have — before 'wb add', its manifest isn't on disk.
_wb_complete_layer_ids() {
    local module="$1" current_dir manifest tool position
    if [[ -n "${module}" ]] && workbench_valid_module_name "${module}" 2>/dev/null; then
        current_dir="$(workbench_module_current_dir "${module}")"
        manifest="$(workbench_resolve_manifest_path "${current_dir}" 2>/dev/null)"
        if [[ -n "${manifest}" ]]; then
            while IFS='|' read -r tool _ position _; do
                [[ -z "${tool}" ]] && continue
                if [[ "${position}" == "over" ]]; then printf '%s:over\n' "${tool}"; else printf '%s\n' "${tool}"; fi
            done < <(workbench_manifest_layer_entries "${manifest}")
            return 0
        fi
    fi
    for tool in ${_WB_LAYER_ADAPTERS}; do
        printf '%s\n%s:over\n' "${tool}" "${tool}"
    done
}

# _wb_completion_generate_bash
# Emits wb's full bash completion function: top-level commands (Phase 1),
# plus Phase 2's sub-command and argument-level completion. The
# sub-command word-lists (tools/module/sync/scheduler) are static —
# introspected once, at generation time, and baked into the cached
# script exactly like the top-level list, since they never change
# between workbench-core releases. Module/tool/catalog names are NOT
# baked in — they change on every wb add/remove/track/tools install, so
# the generated function calls 'wb __complete <kind>' fresh on every
# keystroke instead (same principle as any dynamic bash completion that
# shells out to its own binary for live state).
_wb_completion_generate_bash() {
    local commands sync_subs load_subs tools_subs module_subs files_subs scheduler_subs
    # paste -s (not `tr '\n' ' '`) so the joined list has no trailing
    # space — a trailing space would leave compgen -W an empty extra word.
    commands="$(_wb_completion_dispatch_commands | paste -sd' ' -)"
    sync_subs="$(_wb_completion_subdispatch_commands _wb_cmd_sync | paste -sd' ' -)"
    load_subs="$(_wb_completion_subdispatch_commands _wb_cmd_load | paste -sd' ' -)"
    tools_subs="$(_wb_completion_subdispatch_commands _wb_cmd_tools | paste -sd' ' -)"
    module_subs="$(_wb_completion_subdispatch_commands _wb_cmd_module | paste -sd' ' -)"
    files_subs="$(_wb_completion_subdispatch_commands _wb_cmd_files | paste -sd' ' -)"
    scheduler_subs="$(_wb_completion_subdispatch_commands _wb_cmd_scheduler | paste -sd' ' -)"
    local flag_case
    # shellcheck disable=SC2016  # the expression is for the generated script to expand
    flag_case="$(_wb_completion_flag_case '${COMP_WORDS[2]:-}')"
    command cat <<EOF
# Generated by 'wb completion bash' — do not hand-edit, re-run to refresh.
_wb_completions() {
    local cur cmd
    cur="\${COMP_WORDS[COMP_CWORD]}"
    cmd="\${COMP_WORDS[1]:-}"
    COMPREPLY=()

    if [[ \${COMP_CWORD} -eq 1 ]]; then
        # shellcheck disable=SC2207
        COMPREPLY=( \$(compgen -W "${commands}" -- "\${cur}") )
        return 0
    fi

    # Flag names (Phase 3, D122): baked in at generation time, like the
    # sub-command lists, from the case arms each command parses.
    if [[ "\${cur}" == -* ]]; then
        local _wb_flags=""
${flag_case}
        COMPREPLY=( \$(compgen -W "\${_wb_flags}" -- "\${cur}") )
        return 0
    fi

    command -v wb &>/dev/null || return 0

    case "\${cmd}" in
        add)
            if [[ "\${COMP_WORDS[COMP_CWORD-1]}" == "--skip-layer" ]]; then
                COMPREPLY=( \$(compgen -W "\$(wb __complete layer-ids "\${COMP_WORDS[2]}" 2>/dev/null)" -- "\${cur}") )
            elif [[ "\${cur}" != -* ]]; then
                COMPREPLY=( \$(compgen -W "\$(wb __complete catalog-modules 2>/dev/null)" -- "\${cur}") )
            fi
            ;;
        remove|revert|track|dev|update)
            [[ \${COMP_CWORD} -eq 2 ]] && COMPREPLY=( \$(compgen -W "\$(wb __complete registered-modules 2>/dev/null)" -- "\${cur}") )
            ;;
        install)
            [[ "\${COMP_WORDS[COMP_CWORD-1]}" == "--bundle" ]] && COMPREPLY=( \$(compgen -W "\$(wb __complete catalog-bundles 2>/dev/null)" -- "\${cur}") )
            ;;
        load)
            if [[ \${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( \$(compgen -W "${load_subs}" -- "\${cur}") )
            elif [[ \${COMP_CWORD} -eq 3 ]]; then
                COMPREPLY=( \$(compgen -W "\$(wb __complete registered-modules 2>/dev/null)" -- "\${cur}") )
            fi
            ;;
        sync)
            if [[ \${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( \$(compgen -W "${sync_subs}" -- "\${cur}") )
            elif [[ \${COMP_CWORD} -eq 3 && ( "\${COMP_WORDS[2]}" == "enable" || "\${COMP_WORDS[2]}" == "disable" ) ]]; then
                COMPREPLY=( \$(compgen -W "\$(wb __complete registered-modules 2>/dev/null)" -- "\${cur}") )
            fi
            ;;
        tools)
            if [[ \${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( \$(compgen -W "${tools_subs}" -- "\${cur}") )
            elif [[ \${COMP_CWORD} -eq 3 && ( "\${COMP_WORDS[2]}" == "install" || "\${COMP_WORDS[2]}" == "upgrade" ) ]]; then
                COMPREPLY=( \$(compgen -W "\$(wb __complete tools 2>/dev/null) all" -- "\${cur}") )
            elif [[ \${COMP_CWORD} -gt 3 && "\${COMP_WORDS[3]}" != "all" && ( "\${COMP_WORDS[2]}" == "install" || "\${COMP_WORDS[2]}" == "upgrade" ) ]]; then
                COMPREPLY=( \$(compgen -W "\$(wb __complete tools 2>/dev/null)" -- "\${cur}") )
            fi
            ;;
        module)
            if [[ \${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( \$(compgen -W "${module_subs}" -- "\${cur}") )
            elif [[ \${COMP_CWORD} -eq 3 && ( "\${COMP_WORDS[2]}" == "info" || "\${COMP_WORDS[2]}" == "docs" || "\${COMP_WORDS[2]}" == "reset" ) ]]; then
                COMPREPLY=( \$(compgen -W "\$(wb __complete registered-modules 2>/dev/null)" -- "\${cur}") )
            elif [[ \${COMP_CWORD} -eq 4 && "\${COMP_WORDS[2]}" == "reset" ]]; then
                COMPREPLY=( \$(compgen -W "\$(wb __complete reset-targets "\${COMP_WORDS[3]}" 2>/dev/null) all" -- "\${cur}") )
            fi
            ;;
        files)
            if [[ \${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( \$(compgen -W "${files_subs}" -- "\${cur}") )
            elif [[ \${COMP_CWORD} -eq 3 ]]; then
                COMPREPLY=( \$(compgen -W "\$(wb __complete registered-modules 2>/dev/null)" -- "\${cur}") )
            elif [[ \${COMP_CWORD} -eq 4 && "\${COMP_WORDS[2]}" == "use" ]]; then
                COMPREPLY=( \$(compgen -W "\$(wb __complete reset-targets "\${COMP_WORDS[3]}" 2>/dev/null) all" -- "\${cur}") )
            fi
            ;;
        scheduler)
            [[ \${COMP_CWORD} -eq 2 ]] && COMPREPLY=( \$(compgen -W "${scheduler_subs}" -- "\${cur}") )
            ;;
        *)
            ;;
    esac
}
complete -F _wb_completions wb
EOF
}

# _wb_completion_generate_zsh
# zsh's $words/$CURRENT are 1-indexed ($words[1]="wb"), unlike bash's
# 0-indexed $COMP_WORDS — so $CURRENT -eq 2 (completing the command
# itself) maps to bash's $COMP_CWORD -eq 1, $CURRENT -eq 3 maps to
# $COMP_CWORD -eq 2, and so on. Otherwise identical structure/logic to
# the bash generator above — one source of positional logic per shell,
# not a shared abstraction, since the completion primitives themselves
# (COMPREPLY/compgen vs _describe/compadd) are irreducibly different.
_wb_completion_generate_zsh() {
    local commands sync_subs load_subs tools_subs module_subs files_subs scheduler_subs
    commands="$(_wb_completion_dispatch_commands | paste -sd' ' -)"
    sync_subs="$(_wb_completion_subdispatch_commands _wb_cmd_sync | paste -sd' ' -)"
    load_subs="$(_wb_completion_subdispatch_commands _wb_cmd_load | paste -sd' ' -)"
    tools_subs="$(_wb_completion_subdispatch_commands _wb_cmd_tools | paste -sd' ' -)"
    module_subs="$(_wb_completion_subdispatch_commands _wb_cmd_module | paste -sd' ' -)"
    files_subs="$(_wb_completion_subdispatch_commands _wb_cmd_files | paste -sd' ' -)"
    scheduler_subs="$(_wb_completion_subdispatch_commands _wb_cmd_scheduler | paste -sd' ' -)"
    local flag_case
    # shellcheck disable=SC2016  # the expression is for the generated script to expand
    flag_case="$(_wb_completion_flag_case '${words[3]:-}')"
    command cat <<EOF
# Generated by 'wb completion zsh' — do not hand-edit, re-run to refresh.
_wb_completions() {
    local cmd
    cmd="\${words[2]:-}"

    if [[ \${CURRENT} -eq 2 ]]; then
        local -a commands
        commands=(${commands})
        _describe 'wb command' commands
        return 0
    fi

    # Flag names (Phase 3, D122): baked in at generation time, like the
    # sub-command lists, from the case arms each command parses.
    if [[ "\${words[CURRENT]}" == -* ]]; then
        local _wb_flags=""
${flag_case}
        local -a _wb_flag_list
        _wb_flag_list=(\${=_wb_flags})
        compadd -- "\${_wb_flag_list[@]}"
        return 0
    fi

    command -v wb &>/dev/null || return 0

    case "\${cmd}" in
        add)
            if [[ "\${words[CURRENT-1]}" == "--skip-layer" ]]; then
                local -a _wb_layer_ids
                _wb_layer_ids=(\${(f)"\$(wb __complete layer-ids "\${words[3]}" 2>/dev/null)"})
                _describe 'layer' _wb_layer_ids
            elif [[ "\${words[CURRENT]}" != -* ]]; then
                local -a _wb_catalog_mods
                _wb_catalog_mods=(\${(f)"\$(wb __complete catalog-modules 2>/dev/null)"})
                _describe 'module' _wb_catalog_mods
            fi
            ;;
        remove|revert|track|dev|update)
            if [[ \${CURRENT} -eq 3 ]]; then
                local -a _wb_reg_mods
                _wb_reg_mods=(\${(f)"\$(wb __complete registered-modules 2>/dev/null)"})
                _describe 'module' _wb_reg_mods
            fi
            ;;
        install)
            if [[ "\${words[CURRENT-1]}" == "--bundle" ]]; then
                local -a _wb_catalog_bundles
                _wb_catalog_bundles=(\${(f)"\$(wb __complete catalog-bundles 2>/dev/null)"})
                _describe 'bundle' _wb_catalog_bundles
            fi
            ;;
        load)
            if [[ \${CURRENT} -eq 3 ]]; then
                local -a load_subs; load_subs=(${load_subs})
                _describe 'wb load subcommand' load_subs
            elif [[ \${CURRENT} -eq 4 ]]; then
                local -a _wb_reg_mods
                _wb_reg_mods=(\${(f)"\$(wb __complete registered-modules 2>/dev/null)"})
                _describe 'module' _wb_reg_mods
            fi
            ;;
        sync)
            if [[ \${CURRENT} -eq 3 ]]; then
                local -a sync_subs; sync_subs=(${sync_subs})
                _describe 'wb sync subcommand' sync_subs
            elif [[ \${CURRENT} -eq 4 && ( "\${words[3]}" == "enable" || "\${words[3]}" == "disable" ) ]]; then
                local -a _wb_reg_mods
                _wb_reg_mods=(\${(f)"\$(wb __complete registered-modules 2>/dev/null)"})
                _describe 'module' _wb_reg_mods
            fi
            ;;
        tools)
            if [[ \${CURRENT} -eq 3 ]]; then
                local -a tools_subs; tools_subs=(${tools_subs})
                _describe 'wb tools subcommand' tools_subs
            elif [[ \${CURRENT} -eq 4 && ( "\${words[3]}" == "install" || "\${words[3]}" == "upgrade" ) ]]; then
                local -a _wb_tools
                _wb_tools=(\${(f)"\$(wb __complete tools 2>/dev/null)"} all)
                _describe 'tool' _wb_tools
            elif [[ \${CURRENT} -gt 4 && "\${words[4]}" != "all" && ( "\${words[3]}" == "install" || "\${words[3]}" == "upgrade" ) ]]; then
                local -a _wb_tools
                _wb_tools=(\${(f)"\$(wb __complete tools 2>/dev/null)"})
                _describe 'tool' _wb_tools
            fi
            ;;
        module)
            if [[ \${CURRENT} -eq 3 ]]; then
                local -a module_subs; module_subs=(${module_subs})
                _describe 'wb module subcommand' module_subs
            elif [[ \${CURRENT} -eq 4 && ( "\${words[3]}" == "info" || "\${words[3]}" == "docs" || "\${words[3]}" == "reset" ) ]]; then
                local -a _wb_reg_mods
                _wb_reg_mods=(\${(f)"\$(wb __complete registered-modules 2>/dev/null)"})
                _describe 'module' _wb_reg_mods
            elif [[ \${CURRENT} -eq 5 && "\${words[3]}" == "reset" ]]; then
                local -a _wb_targets
                _wb_targets=(\${(f)"\$(wb __complete reset-targets "\${words[4]}" 2>/dev/null)"} all)
                _describe 'file' _wb_targets
            fi
            ;;
        files)
            if [[ \${CURRENT} -eq 3 ]]; then
                local -a files_subs; files_subs=(${files_subs})
                _describe 'wb files subcommand' files_subs
            elif [[ \${CURRENT} -eq 4 ]]; then
                local -a _wb_reg_mods
                _wb_reg_mods=(\${(f)"\$(wb __complete registered-modules 2>/dev/null)"})
                _describe 'module' _wb_reg_mods
            elif [[ \${CURRENT} -eq 5 && "\${words[3]}" == "use" ]]; then
                local -a _wb_targets
                _wb_targets=(\${(f)"\$(wb __complete reset-targets "\${words[4]}" 2>/dev/null)"} all)
                _describe 'file' _wb_targets
            fi
            ;;
        scheduler)
            if [[ \${CURRENT} -eq 3 ]]; then
                local -a scheduler_subs; scheduler_subs=(${scheduler_subs})
                _describe 'wb scheduler subcommand' scheduler_subs
            fi
            ;;
        *)
            ;;
    esac
}
if command -v compdef &>/dev/null; then
    compdef _wb_completions wb
fi
EOF
}

# _wb_cmd_completion <bash|zsh>
_wb_cmd_completion() {
    local shell="${1:-}"
    case "${shell}" in
        bash) _wb_completion_generate_bash ;;
        zsh)  _wb_completion_generate_zsh ;;
        "")
            log_error "wb completion: usage: wb completion bash|zsh"
            return 2
            ;;
        *)
            log_error "wb completion: unsupported shell '${shell}' — only bash and zsh are supported (docs/architecture.md D4: no Windows/PowerShell)"
            return 2
            ;;
    esac
}
