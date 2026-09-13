#!/usr/bin/env bash
# lib/core/completion.sh — workbench-core
#
# Generates bash/zsh tab-completion scripts for the 'wb' CLI itself
# (Phase 1: top-level subcommand completion only — no argument-level
# completion of module/tool/bundle names yet; see ARCHITECTURE.md §12
# D44 for the follow-up this deliberately defers). Command names are
# never hand-maintained here: they're introspected straight out of
# bin/wb's own dispatch case statement, the same plain-text-introspection
# technique _extract_function_names already uses for register.shell
# content (lib/core/functions.sh) — so this list can never drift from
# what 'wb' actually dispatches on.

# shellcheck source=lib/core/log.sh
_wb_completion_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[[ -f "${_wb_completion_dir}/log.sh" ]] && source "${_wb_completion_dir}/log.sh"
unset _wb_completion_dir

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/core/completion.sh" "0.2.0" || true

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
# case, generalised to work on any of bin/wb's four sub-dispatchers
# (_wb_cmd_tools/_wb_cmd_module/_wb_cmd_sync/_wb_cmd_scheduler) instead of
# hand-listing each one's sub-commands a second time.
#
# Scoped to the named function's own body first — bin/wb has four
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

# _wb_cmd_complete <kind>
# Hidden, internal-only fast path consumed by the generated bash/zsh
# completion scripts at keystroke time (Phase 2, ARCHITECTURE.md §12
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
        catalog-modules)    workbench_catalog_list_modules ;;
        catalog-bundles)    workbench_catalog_list_bundles ;;
        tools)              workbench_tools_collect 2>/dev/null | cut -d'|' -f4 ;;
        *)                  return 1 ;;
    esac
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
    local commands sync_subs tools_subs module_subs scheduler_subs
    # paste -s (not `tr '\n' ' '`) so the joined list has no trailing
    # space — a trailing space would leave compgen -W an empty extra word.
    commands="$(_wb_completion_dispatch_commands | paste -sd' ' -)"
    sync_subs="$(_wb_completion_subdispatch_commands _wb_cmd_sync | paste -sd' ' -)"
    tools_subs="$(_wb_completion_subdispatch_commands _wb_cmd_tools | paste -sd' ' -)"
    module_subs="$(_wb_completion_subdispatch_commands _wb_cmd_module | paste -sd' ' -)"
    scheduler_subs="$(_wb_completion_subdispatch_commands _wb_cmd_scheduler | paste -sd' ' -)"
    cat <<EOF
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

    command -v wb &>/dev/null || return 0

    case "\${cmd}" in
        add)
            [[ \${COMP_CWORD} -eq 2 ]] && COMPREPLY=( \$(compgen -W "\$(wb __complete catalog-modules 2>/dev/null)" -- "\${cur}") )
            ;;
        remove|track|dev|update)
            [[ \${COMP_CWORD} -eq 2 ]] && COMPREPLY=( \$(compgen -W "\$(wb __complete registered-modules 2>/dev/null)" -- "\${cur}") )
            ;;
        install)
            [[ "\${COMP_WORDS[COMP_CWORD-1]}" == "--bundle" ]] && COMPREPLY=( \$(compgen -W "\$(wb __complete catalog-bundles 2>/dev/null)" -- "\${cur}") )
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
            fi
            ;;
        module)
            if [[ \${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( \$(compgen -W "${module_subs}" -- "\${cur}") )
            elif [[ \${COMP_CWORD} -eq 3 && ( "\${COMP_WORDS[2]}" == "info" || "\${COMP_WORDS[2]}" == "docs" || "\${COMP_WORDS[2]}" == "reset" ) ]]; then
                COMPREPLY=( \$(compgen -W "\$(wb __complete registered-modules 2>/dev/null)" -- "\${cur}") )
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
    local commands sync_subs tools_subs module_subs scheduler_subs
    commands="$(_wb_completion_dispatch_commands | paste -sd' ' -)"
    sync_subs="$(_wb_completion_subdispatch_commands _wb_cmd_sync | paste -sd' ' -)"
    tools_subs="$(_wb_completion_subdispatch_commands _wb_cmd_tools | paste -sd' ' -)"
    module_subs="$(_wb_completion_subdispatch_commands _wb_cmd_module | paste -sd' ' -)"
    scheduler_subs="$(_wb_completion_subdispatch_commands _wb_cmd_scheduler | paste -sd' ' -)"
    cat <<EOF
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

    command -v wb &>/dev/null || return 0

    case "\${cmd}" in
        add)
            if [[ \${CURRENT} -eq 3 ]]; then
                local -a _wb_catalog_mods
                _wb_catalog_mods=(\${(f)"\$(wb __complete catalog-modules 2>/dev/null)"})
                _describe 'module' _wb_catalog_mods
            fi
            ;;
        remove|track|dev|update)
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
            log_error "wb completion: unsupported shell '${shell}' — only bash and zsh are supported (ARCHITECTURE.md D4: no Windows/PowerShell)"
            return 2
            ;;
    esac
}
