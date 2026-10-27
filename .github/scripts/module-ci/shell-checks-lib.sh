#!/usr/bin/env bash
# .github/scripts/module-ci/shell-checks-lib.sh
#
# Shared by the clean-shell checks: module CI's check-clean-shell.sh (D94)
# and the ecosystem smoke test, .github/scripts/ecosystem/check-ecosystem.sh
# (D99). Sourced, never run. Needs core's lib/core/prereqs.sh and
# lib/core/functions.sh sourced first (for _WB_SHELL_PREREQS_REQUIRED,
# _extract_function_names and _extract_alias_names), and HOME and the XDG_*
# variables pointing at the isolated install under test.
#
# GitHub-runner-only (Bash 4+ allowed per AGENTS.md), but kept to bash 3.2
# like the scripts that source it.

# _wb_ci_make_bare_bin <dir>
# Fills <dir> with symlinks to core's required prereqs, baseline utilities
# and both shells: a PATH on which every optional tool is absent.
_wb_ci_make_bare_bin() {
    local dir="$1" bin path
    local -a baseline=(
        bash zsh uname sleep kill
        cat cp mv rm mkdir rmdir ln ls touch chmod readlink basename dirname
        head tail sort uniq wc cut tee date env mktemp id groups printf test expr
        find xargs stat hostname tput
        # macOS's /etc/zshrc runs `locale` in every interactive zsh (D95).
        locale
    )
    mkdir -p "${dir}"
    for bin in "${_WB_SHELL_PREREQS_REQUIRED[@]}" "${baseline[@]}"; do
        path="$(command -v "${bin}" 2>/dev/null)"
        [[ -n "${path}" && "${path}" == /* ]] && ln -sf "${path}" "${dir}/${bin}"
    done
}

# _wb_ci_shell_start <shell-path> <PATH> <commands> <stderr-file>
# An interactive shell, through the rc stubs, in a clean environment.
# skip_global_compinit: Ubuntu's /etc/zsh/zshrc runs compinit in every
# interactive zsh, and on a GitHub runner compinit finds an fpath directory
# it calls insecure and, with no terminal to ask on, prints "compinit:
# initialization aborted" — runner noise, not a module's.
_wb_ci_shell_start() {
    local shell="$1" path="$2" cmds="$3" err="$4"
    env -i \
        HOME="${HOME}" \
        XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}" \
        USER="${USER:-runner}" \
        TERM=dumb \
        skip_global_compinit=1 \
        PATH="${path}" \
        "${shell}" -i -c "${cmds}" 2>"${err}" </dev/null
}

# _wb_ci_filtered_stderr <file>
# Bash prints two job-control lines when -i has no terminal; nothing else
# on stderr is acceptable.
_wb_ci_filtered_stderr() {
    grep -vE 'cannot set terminal process group|no job control in this shell' "$1"
}

# _wb_ci_loader_path_check
# Shell commands that fail, by name, when the loader's own path didn't
# survive the start (a chpwd hook or CDPATH output captured into it, D96).
# Not 'exit': an interactive bash prints "exit" to stderr when it runs.
# shellcheck disable=SC2016  # expanded by the shell under test, not here
_WB_CI_LOADER_PATH_CHECK='[[ -f "${WORKBENCH_LOADER_PATH:-}" ]] || echo "bad WORKBENCH_LOADER_PATH: [${WORKBENCH_LOADER_PATH:-}]" >&2'

# _wb_ci_module_names <module-name>
# The module's own public function and alias names, from the shell files
# it registered (its register.list): what any working getter of that
# module must show, either as usable or under "available once tooling is
# installed". Prints nothing when the module registers no shell files.
_wb_ci_module_names() {
    local list="${XDG_DATA_HOME}/workbench/modules/$1/register.list" f _tier
    local -a files=()
    [[ -f "${list}" ]] || return 0
    while IFS='|' read -r f _tier; do
        [[ -n "${f}" && -f "${f}" ]] && files+=("${f}")
    done < "${list}"
    [[ ${#files[@]} -gt 0 ]] || return 0
    { _extract_function_names "${files[@]}"; _extract_alias_names "${files[@]}"; } | sort -u
}

# _wb_ci_lists_a_module_name <getter-output-file> <names>
# True when the getter's output names at least one of <names> (one per
# line) as a whole word. With no names (a completions-only module), any
# [INFO] header is enough.
_wb_ci_lists_a_module_name() {
    local out="$1" names="$2" n
    if [[ -z "${names}" ]]; then
        grep -q '\[INFO\]' "${out}"
        return
    fi
    while IFS= read -r n; do
        [[ -z "${n}" ]] && continue
        grep -qwF -- "${n}" "${out}" && return 0
    done <<< "${names}"
    return 1
}
