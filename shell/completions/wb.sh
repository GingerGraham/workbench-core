#!/usr/bin/env bash
# shell/completions/wb.sh — workbench-core
#
# wb's own bash/zsh completions — version-stamped cache, same pattern as
# the tool-completion wrappers other modules ship (workbench-git's gh.sh/
# glab.sh, workbench-devtools' uv.sh/terraform.sh), except keyed on
# workbench-core's own release version (_workbench_release_version,
# lib/core/version.sh — already sourced by the time this runs, tier: core
# loads before tier: tools) rather than an external tool's --version
# output. Generation is local only ('wb completion' never touches the
# network), so — like those wrappers — this sits outside any offline
# gate.

_wb_completion_cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/workbench/completions"
_wb_completion_version="$(_workbench_release_version 2>/dev/null)"

if [[ -n "${_wb_completion_version}" ]]; then
    _wb_completion_cache="${_wb_completion_cache_dir}/wb.${WORKBENCH_SHELL}.${_wb_completion_version}.sh"

    if [[ ! -f "${_wb_completion_cache}" ]]; then
        mkdir -p "${_wb_completion_cache_dir}"
        if [[ -n "${ZSH_VERSION:-}" ]]; then
            setopt nullglob
        else
            shopt -s nullglob
        fi
        for _stale in "${_wb_completion_cache_dir}"/wb."${WORKBENCH_SHELL}".*.sh; do
            [[ "${_stale}" != "${_wb_completion_cache}" ]] && rm -f "${_stale}"
        done
        if [[ -n "${ZSH_VERSION:-}" ]]; then
            unsetopt nullglob
        else
            shopt -u nullglob
        fi
        unset _stale
        wb completion "${WORKBENCH_SHELL}" 2>/dev/null > "${_wb_completion_cache}" \
            || rm -f "${_wb_completion_cache}"
    fi

    # zsh's completion system (compdef) has to be initialised before the
    # cached script below can wire itself up. workbench-shell's zsh.sh
    # already does this, but core has no dependency on workbench-shell,
    # so a core-only install needs its own defensive, idempotent guard.
    # -C reuses the existing dump (same technique zsh.sh uses), so this
    # is a cheap no-op if compinit already ran.
    if [[ -n "${ZSH_VERSION:-}" ]] && ! command -v compdef &>/dev/null; then
        autoload -Uz compinit
        compinit -C
    fi

    # shellcheck disable=SC1090
    [[ -f "${_wb_completion_cache}" ]] && source "${_wb_completion_cache}"
fi

unset _wb_completion_cache_dir _wb_completion_version _wb_completion_cache
