#!/usr/bin/env bash
# lib/core/pager.sh — optional pager for wb's own long, read-only listing
# output. `wb functions` is the first consumer; any future read-only
# listing command (`wb status`, `wb tools list`, ...) can reuse the same
# primitive rather than growing its own paging logic. Bash 3.2 / zsh safe:
# no associative arrays, no ${var,,}, no mapfile.

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/core/pager.sh" "0.1.0" || true

# _wb_resolve_pager
# Decides which pager command (if any) should wrap output, without
# touching stdin/stdout/a terminal itself — pure enough to unit-test
# directly, unlike _wb_maybe_page below.
#
# Prints the resolved pager command line on stdout, or nothing at all
# when no paging should happen (caller falls back to cat). Precedence:
#   1. WORKBENCH_PAGER — wb-specific override, checked for by presence
#      (not just non-empty value), so WORKBENCH_PAGER="" explicitly
#      forces "no pager" rather than falling through to PAGER/less.
#      "cat" and "none" are accepted synonyms for the same explicit
#      disable.
#   2. PAGER — whatever the environment already has set (workbench-shell's
#      editors.sh exports this when that module is installed, but core
#      must work with it unset — module zero, no dependency on any other
#      module).
#   3. `less`, if present on PATH, with -F -R -X: -F prints nothing and
#      exits immediately when the content already fits on one screen (so
#      a short 'wb functions' listing is never wrapped in a pager
#      session at all), -R passes raw control characters through
#      unmangled, -X leaves the scrollback in place on quit instead of
#      restoring the alternate screen.
#   4. Nothing — the caller falls back to cat.
#
# A WORKBENCH_PAGER/PAGER value that already names its own flags (e.g.
# "less -S", "bat --paging=always") is trusted and used exactly as given
# — flags are only added for the bare, unconfigured "less" this function
# picks as its own default.
_wb_resolve_pager() {
    if [[ -n "${WORKBENCH_PAGER+set}" ]]; then
        case "${WORKBENCH_PAGER}" in
            ""|cat|none) return 0 ;;
            *) printf '%s\n' "${WORKBENCH_PAGER}"; return 0 ;;
        esac
    fi

    if [[ -n "${PAGER:-}" ]]; then
        printf '%s\n' "${PAGER}"
        return 0
    fi

    if command -v less &>/dev/null; then
        printf '%s\n' "less -F -R -X"
        return 0
    fi
}

# _wb_maybe_page
# Reads stdin, writes stdout — either straight through (cat) or via
# whatever _wb_resolve_pager picked. Never pages when stdout isn't a
# terminal: every existing caller and test that captures a paged
# command's output via redirection or $(...) keeps seeing raw output,
# unchanged, since that's exactly the "not a tty" case.
_wb_maybe_page() {
    if [[ ! -t 1 ]]; then
        cat
        return 0
    fi

    local _pager
    _pager="$(_wb_resolve_pager)"
    if [[ -z "${_pager}" ]]; then
        cat
        return 0
    fi

    # shellcheck disable=SC2086  # deliberate word-splitting: _pager may be
    # a multi-word command line ("less -S", "bat --paging=always"), the
    # same convention every tool that honours $PAGER already follows.
    ${_pager}
}
