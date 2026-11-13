#!/usr/bin/env bash
# lib/core/pager.sh — paging for wb's own long, read-only listing output.
# Bash 3.2 safe: no associative arrays, no ${var,,}, no mapfile.
# Not zsh-safe (read -n/-s mean different things there). That is fine
# because it only ever runs inside bin/wb, which is bash.
#
# Default is a built-in, forward-only pager: it prints straight to the
# terminal, one screenful at a time, and never switches to the alternate
# screen. Everything it printed stays in the terminal's scrollback after
# the command returns, and the mouse wheel scrolls that scrollback as
# normal. External pagers are opt-in via WORKBENCH_PAGER.

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/core/pager.sh" "0.3.0" || true

# _wb_resolve_pager
# Prints the pager to use, or nothing when output should not be paged.
#   WORKBENCH_PAGER unset      -> builtin
#   WORKBENCH_PAGER=builtin    -> builtin
#   WORKBENCH_PAGER=""|cat|none -> nothing (no paging)
#   WORKBENCH_PAGER=<command>  -> that command line, verbatim
# PAGER is deliberately not consulted: it is the system-wide document
# viewer setting (man, git, systemctl), and workbench-shell exports
# PAGER=less itself, so it says nothing about how the user wants wb's
# command output handled.
_wb_resolve_pager() {
    if [[ -n "${WORKBENCH_PAGER+set}" ]]; then
        case "${WORKBENCH_PAGER}" in
            ""|cat|none) return 0 ;;
            builtin)     printf 'builtin\n'; return 0 ;;
            *)           printf '%s\n' "${WORKBENCH_PAGER}"; return 0 ;;
        esac
    fi
    printf 'builtin\n'
}

# _wb_term_size
# Prints "rows cols" for the controlling terminal. _WB_PAGER_SIZE
# overrides detection (tests only).
_wb_term_size() {
    local _size=""

    if [[ -n "${_WB_PAGER_SIZE:-}" ]]; then
        printf '%s\n' "${_WB_PAGER_SIZE}"
        return 0
    fi

    # stty reads the size from the tty itself, so it works even though
    # this runs inside $(...). Linux and macOS both print "rows cols".
    _size="$(stty size < /dev/tty 2>/dev/null)"
    if [[ -z "${_size}" ]]; then
        _size="${LINES:-24} ${COLUMNS:-80}"
    fi
    printf '%s\n' "${_size}"
}

# _wb_strip_sgr <text>
# Sets _WB_STRIPPED to <text> with ANSI colour sequences (ESC [ ... m)
# removed and tabs widened, so its visible width can be measured. Sets a variable rather
# than printing, because $(...) would fork once per line of output.
_wb_strip_sgr() {
    local _text="$1"
    local _before _after
    local _esc=$'\033['

    while [[ "${_text}" == *"${_esc}"*m* ]]; do
        _before="${_text%%"${_esc}"*}"
        _after="${_text#*"${_esc}"}"
        _after="${_after#*m}"
        _text="${_before}${_after}"
    done
    # A tab displays as up to 8 columns but counts as 1 character.
    # Counting each as 8 can only overestimate the width, so a page may
    # end a row early but never scrolls its first lines off screen.
    _WB_STRIPPED="${_text//$'\t'/        }"
}

# _wb_builtin_pager
# Reads stdin, writes stdout. Output that fits on one screen is printed
# with no prompt. Longer output pauses after each screenful.
# Keys: space = next page, enter / j / down-arrow = next line,
#       a = print the rest, q = stop.
# _WB_PAGER_INPUT overrides where keys are read from (tests only).
_wb_builtin_pager() {
    local _key_source="${_WB_PAGER_INPUT:-/dev/tty}"
    local _size _rows _cols
    _size="$(_wb_term_size)"
    _rows="${_size% *}"
    _cols="${_size#* }"
    case "${_rows}" in ''|*[!0-9]*) _rows=24 ;; esac
    case "${_cols}" in ''|*[!0-9]*) _cols=80 ;; esac
    if [[ "${_rows}" -lt 2 ]]; then
        _rows=2
    fi
    if [[ "${_cols}" -lt 1 ]]; then
        _cols=80
    fi

    # Buffer all input first: needed to decide whether it fits on one
    # screen, and to show a percentage in the prompt.
    local _lines=()
    local _heights=()
    local _count=0
    local _total_rows=0
    local _line _length _height

    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        _wb_strip_sgr "${_line}"
        _length="${#_WB_STRIPPED}"
        # A line wider than the terminal wraps onto extra rows.
        if [[ "${_length}" -eq 0 ]]; then
            _height=1
        else
            _height=$(( (_length + _cols - 1) / _cols ))
        fi
        _lines[_count]="${_line}"
        _heights[_count]="${_height}"
        _total_rows=$((_total_rows + _height))
        _count=$((_count + 1))
    done

    if [[ "${_count}" -eq 0 ]]; then
        return 0
    fi

    # One row is kept free for the prompt.
    local _page_rows=$((_rows - 1))

    if [[ "${_total_rows}" -le "${_page_rows}" ]]; then
        printf '%s\n' "${_lines[@]}"
        return 0
    fi

    # No keyboard to read from (stdout is a terminal but there is no
    # controlling tty, e.g. some CI runners): print everything rather
    # than stop after the first page.
    if ! { : < "${_key_source}"; } 2>/dev/null; then
        printf '%s\n' "${_lines[@]}"
        return 0
    fi

    # Keys are read on fd 3, opened once for the whole loop: stdin is the
    # pipe carrying the output, not the keyboard.
    local _index=0
    local _rows_shown=0
    local _budget="${_page_rows}"
    local _used _percent _key _rest

    while [[ "${_index}" -lt "${_count}" ]]; do
        _used=0
        while [[ "${_index}" -lt "${_count}" ]]; do
            # Always print at least one line per step, even one taller
            # than the budget, so a very long line can't stall paging.
            if [[ "${_used}" -gt 0 ]] && [[ $((_used + _heights[_index])) -gt "${_budget}" ]]; then
                break
            fi
            printf '%s\n' "${_lines[_index]}"
            _used=$((_used + _heights[_index]))
            _rows_shown=$((_rows_shown + _heights[_index]))
            _index=$((_index + 1))
        done

        if [[ "${_index}" -ge "${_count}" ]]; then
            break
        fi

        _percent=$((_rows_shown * 100 / _total_rows))
        printf '\033[7m-- %d%% -- space: page  enter: line  a: all  q: quit \033[0m' "${_percent}"

        _key=""
        if ! IFS= read -r -s -n 1 _key <&3; then
            _key="q"
        fi

        # Arrow keys and PgDn arrive as ESC [ <x>; read the rest so the
        # leftover bytes aren't treated as further key presses.
        if [[ "${_key}" == $'\033' ]]; then
            _rest=""
            IFS= read -r -s -n 2 _rest <&3 || true
            case "${_rest}" in
                "[B") _key="j" ;;
                "[6") IFS= read -r -s -n 1 _rest <&3 || true
                      _key=" " ;;
                *)    _key=" " ;;
            esac
        fi

        # Erase the prompt so it never lands in the scrollback.
        printf '\r\033[K'

        case "${_key}" in
            q|Q) return 0 ;;
            a|A) _budget="${_total_rows}" ;;
            ""|j) _budget=1 ;;
            *)   _budget="${_page_rows}" ;;
        esac
    done 3< "${_key_source}"
}

# _wb_maybe_page
# Reads stdin, writes stdout. Never pages when stdout isn't a terminal,
# so pipes, redirects and $(...) captures always get raw output.
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

    if [[ "${_pager}" == "builtin" ]]; then
        _wb_builtin_pager
        return 0
    fi

    # shellcheck disable=SC2086  # deliberate word-splitting: a
    # multi-word command line ("less -FRX", "bat --paging=always").
    ${_pager}
}
