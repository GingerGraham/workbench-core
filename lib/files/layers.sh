#!/usr/bin/env bash
# lib/files/layers.sh — config layers: a module's contribution to a config
# file the user already owns (docs/decisions-log.md D82; D81's Phase 2).
#
# A module declares layers[] (tool, src, position, adopt). It never names a
# target path: the adapter does. Core writes one marker-delimited block into
# the user's own file, containing an absolute-path include of
# <module>/current/<src>, placed so the user's own settings win:
#
#   adapter      targets, in the tool's load order        under    over
#   gitconfig    ~/.gitconfig only                         top      bottom
#   ssh_config   ~/.ssh/config only                        bottom   top
#   tmux.conf    ~/.tmux.conf, $XDG/tmux, ~/.config/tmux   top      bottom
#   vimrc        ~/.vimrc, ~/.vim/vimrc, $XDG/vim          top      bottom
#
# git, tmux and vim keep the last value they read; ssh keeps the first.
# 'under' is for module opinions, 'over' only for content recording the
# user's own choices made through module functions.
#
# Every layer is a row in the D81 ledger (files.list, kind 'layer', key
# '<target>#<position>') and honours files.policy rows keyed by its layer id
# ('<tool>' for under, '<tool>:over' for over) — skip or managed only.
#
# Invariant: the user's lines are never changed, moved or removed. Core only
# ever writes, moves or removes its own block, and relocates lines it finds
# inside its block that it didn't write.
#
# Bash 3.2: no associative arrays, no mapfile, no ${var,,}. File surgery is
# awk over temp files beside the target, renamed over it.
#
# Depends on lib/files/lifecycle.sh (ledger, policy, _wb_files_* helpers)
# and what it depends on.

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/files/layers.sh" "0.3.1" || true

# ── Adapters ────────────────────────────────────────────────────────────────

# Comment-line characters, as an awk bracket expression.
_wb_layers_comment_class() {
    case "$1" in
        gitconfig) printf '[#;]\n' ;;
        vimrc)     printf '["]\n' ;;
        *)         printf '[#]\n' ;;
    esac
}

# The character core's own marker and comment lines start with.
_wb_layers_comment_char() {
    case "$1" in
        vimrc) printf '"\n' ;;
        *)     printf '#\n' ;;
    esac
}

# True when <tool>'s block at <position> sits at the top of the file.
_wb_layers_is_top() {
    local tool="$1" position="$2"
    if [[ "${tool}" == "ssh_config" ]]; then
        [[ "${position}" == "over" ]]
    else
        [[ "${position}" == "under" ]]
    fi
}

# Absolute path → ~/-form when it's under $HOME (how ledger keys and the
# user see it); unchanged otherwise.
# shellcheck disable=SC2088  # a literal ~/ key, expanded by _wb_expand_dest
_wb_layers_tilde() {
    case "$1" in
        "${HOME}"/*) printf '~/%s\n' "${1#"${HOME}"/}" ;;
        *)           printf '%s\n' "$1" ;;
    esac
}

# Candidate targets, in the tool's own load order.
# shellcheck disable=SC2088
_wb_layers_candidates() {
    case "$1" in
        gitconfig)
            # Never ~/.config/git/config: when ~/.gitconfig is absent,
            # 'git config --global' writes into the XDG file — the user's own
            # settings would land inside workbench's file.
            printf '~/.gitconfig\n' ;;
        ssh_config)
            printf '~/.ssh/config\n' ;;
        tmux.conf)
            printf '~/.tmux.conf\n'
            [[ -n "${XDG_CONFIG_HOME:-}" ]] && _wb_layers_tilde "${XDG_CONFIG_HOME}/tmux/tmux.conf"
            printf '~/.config/tmux/tmux.conf\n' ;;
        vimrc)
            printf '~/.vimrc\n~/.vim/vimrc\n'
            if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
                _wb_layers_tilde "${XDG_CONFIG_HOME}/vim/vimrc"
            else
                printf '~/.config/vim/vimrc\n'
            fi ;;
    esac
}

# Target when none of the candidates exists.
# shellcheck disable=SC2088
_wb_layers_default_target() {
    local version
    case "$1" in
        gitconfig)  printf '~/.gitconfig\n' ;;
        ssh_config) printf '~/.ssh/config\n' ;;
        vimrc)      printf '~/.vimrc\n' ;;
        tmux.conf)
            # tmux reads ~/.config/tmux/tmux.conf from 3.1 on; anything older,
            # or no tmux yet, gets the file every version reads.
            version="$(tmux -V 2>/dev/null | sed -E 's/^tmux (next-)?([0-9]+\.[0-9]+).*/\2/')"
            if [[ "${version}" =~ ^[0-9]+\.[0-9]+$ ]] && _wb_version_satisfies "${version}.0" ">=3.1.0" 2>/dev/null; then
                printf '~/.config/tmux/tmux.conf\n'
            else
                printf '~/.tmux.conf\n'
            fi ;;
    esac
}

# _wb_layers_validate <tool> <real>
# 0 valid, 1 invalid, 2 no validator for this tool here (or nothing to check).
_wb_layers_validate() {
    local tool="$1" real="$2"
    [[ -f "${real}" ]] || return 2
    case "${tool}" in
        gitconfig)
            command -v git &>/dev/null || return 2
            git config --file "${real}" --includes --list >/dev/null 2>&1 || return 1 ;;
        ssh_config)
            command -v ssh &>/dev/null || return 2
            ssh -F "${real}" -G workbench-validate.invalid </dev/null >/dev/null 2>&1 || return 1 ;;
        *)
            return 2 ;;
    esac
}

# The include body for one block, one line per line.
_wb_layers_body() {
    local tool="$1" position="$2" p="$3" created="$4"
    case "${tool}" in
        gitconfig)
            printf '[include]\n\tpath = "%s"\n' "${p}" ;;
        ssh_config)
            # After a Host block an Include is scoped to that host — 'Match
            # all' makes the bottom block global again.
            [[ "${position}" == "under" ]] && printf 'Match all\n'
            printf 'Include "%s"\n' "${p}" ;;
        tmux.conf)
            printf 'source-file -q "%s"\n' "${p}" ;;
        vimrc)
            # Creating a vimrc switches off vim's defaults.vim; keep what the
            # user had with no vimrc. Inside the block, so restore removes it.
            if [[ "${created}" == "true" ]]; then
                printf 'unlet! skip_defaults_vim\n'
                # shellcheck disable=SC2016  # $VIMRUNTIME is vim's, not ours
                printf 'source $VIMRUNTIME/defaults.vim\n'
            fi
            printf "if filereadable('%s') | execute 'source' fnameescape('%s') | endif\n" "${p}" "${p}" ;;
    esac
}

workbench_layers_marker_start() {
    printf '%s >>> workbench %s/%s %s >>>\n' "$(_wb_layers_comment_char "$2")" "$1" "$2" "$3"
}
workbench_layers_marker_end() {
    printf '%s <<< workbench %s/%s %s <<<\n' "$(_wb_layers_comment_char "$2")" "$1" "$2" "$3"
}

# workbench_layers_block <module> <tool> <position> <abs_src> <created>
# The exact block text core writes, markers included.
workbench_layers_block() {
    local module="$1" tool="$2" position="$3" p="$4" created="$5"
    workbench_layers_marker_start "${module}" "${tool}" "${position}"
    printf '%s Managed by workbench (wb files status). Put your settings outside this block.\n' "$(_wb_layers_comment_char "${tool}")"
    _wb_layers_body "${tool}" "${position}" "${p}" "${created}"
    workbench_layers_marker_end "${module}" "${tool}" "${position}"
}

# Layer id ↔ tool/position. The id is what users type.
workbench_layers_id() {
    if [[ "$2" == "over" ]]; then printf '%s:over\n' "$1"; else printf '%s\n' "$1"; fi
}

# ── Targets ─────────────────────────────────────────────────────────────────

# workbench_layers_target <module> <tool> <position>
# The file a layer lives in: its recorded target once one exists, else the
# first candidate that exists, else the adapter's default.
workbench_layers_target() {
    local module="$1" tool="$2" position="$3" c
    while IFS= read -r c; do
        if [[ -n "$(workbench_files_ledger_get "${module}" "${c}#${position}")" ]]; then
            printf '%s\n' "${c}"; return 0
        fi
    done < <(_wb_layers_candidates "${tool}")
    while IFS= read -r c; do
        if [[ -e "$(_wb_expand_dest "${c}")" || -L "$(_wb_expand_dest "${c}")" ]]; then
            printf '%s\n' "${c}"; return 0
        fi
    done < <(_wb_layers_candidates "${tool}")
    _wb_layers_default_target "${tool}"
}

# workbench_layers_target_lines <module> <manifest> <current_dir> [--log]
# One workbench_files_targets line per usable layer:
#   <layer-id>|<src>|<target>#<position>|layer|managed||layer|<abs-src>
# Skipped (warned with --log): an adapter this core doesn't know — so a
# module using a future adapter still syncs everything else — an unknown
# position, a second entry for the same (tool, position), a src that is
# missing or a symlink, and a path a block can't quote safely.
workbench_layers_target_lines() {
    local module="$1" manifest="$2" current_dir="$3" log_refusals="${4:-}"
    local tool src position adopt seen=" " abs target
    while IFS='|' read -r tool src position adopt; do
        [[ -z "${tool}" ]] && continue
        position="${position:-under}"
        if ! _wb_layer_adapter_known "${tool}"; then
            [[ -n "${log_refusals}" ]] && log_warn "workbench_deploy_module: ${module}: skipping layer for unknown adapter '${tool}' — this core knows: ${_WB_LAYER_ADAPTERS}"
            continue
        fi
        if [[ "${position}" != "under" && "${position}" != "over" ]]; then
            [[ -n "${log_refusals}" ]] && log_warn "workbench_deploy_module: ${module}: skipping ${tool} layer — unknown position '${position}'"
            continue
        fi
        if [[ "${seen}" == *" ${tool}#${position} "* ]]; then
            [[ -n "${log_refusals}" ]] && log_warn "workbench_deploy_module: ${module}: skipping a second ${tool} layer at position ${position}"
            continue
        fi
        seen="${seen}${tool}#${position} "
        abs="${current_dir}/${src}"
        if ! _wb_path_is_safe_relative "${src}" || [[ -L "${abs}" || ! -f "${abs}" ]]; then
            [[ -n "${log_refusals}" ]] && log_error "workbench_deploy_module: ${module}: refusing ${tool} layer src '${src}' — missing, unsafe, or a symlink"
            continue
        fi
        # shellcheck disable=SC1003  # a pattern matching one backslash
        case "${abs}" in
            *'"'*|*"'"*|*'\'*|*$'\n'*|*'|'*)
                [[ -n "${log_refusals}" ]] && log_error "workbench_deploy_module: ${module}: refusing ${tool} layer — its path contains a quote, backslash, '|' or newline: ${abs}"
                continue ;;
        esac
        target="$(workbench_layers_target "${module}" "${tool}" "${position}")"
        _wb_files_key_ok "${target}" || continue
        printf '%s|%s|%s#%s|layer|managed||layer|%s\n' \
            "$(workbench_layers_id "${tool}" "${position}")" "${src}" "${target}" "${position}" "${abs}"
    done < <(workbench_manifest_layer_entries "${manifest}")
}

# workbench_layers_adopt_paths <module> <layer-id>
# The comma-joined adopt list of one layer, from the current manifest.
workbench_layers_adopt_paths() {
    local module="$1" id="$2" current_dir manifest tool src position adopt
    current_dir="$(workbench_module_current_dir "${module}")"
    manifest="$(workbench_resolve_manifest_path "${current_dir}")" || return 0
    while IFS='|' read -r tool src position adopt; do
        if [[ "$(workbench_layers_id "${tool}" "${position:-under}")" == "${id}" ]]; then
            printf '%s\n' "${adopt}"
            return 0
        fi
    done < <(workbench_manifest_layer_entries "${manifest}")
}

# ── Path safety ─────────────────────────────────────────────────────────────

# _wb_layers_resolve <real>
# The physical file a write to <real> lands in: a symlink chain followed to
# its end, the parent directory resolved with pwd -P (nearest existing
# ancestor when it doesn't exist yet). Bash 3.2 / BSD: no readlink -f.
_wb_layers_resolve() {
    local path="$1" link hops=0 probe suffix phys
    while [[ -L "${path}" ]]; do
        hops=$((hops + 1))
        [[ "${hops}" -gt 40 ]] && return 1
        link="$(readlink "${path}")"
        case "${link}" in
            /*) path="${link}" ;;
            *)  path="$(dirname "${path}")/${link}" ;;
        esac
    done
    probe="$(dirname "${path}")"
    suffix="/$(basename "${path}")"
    while [[ ! -d "${probe}" ]]; do
        suffix="/$(basename "${probe}")${suffix}"
        probe="$(dirname "${probe}")"
    done
    phys="$(cd -- "${probe}" >/dev/null 2>&1 && pwd -P)" || return 1
    printf '%s%s\n' "${phys%/}" "${suffix}"
}

# D75 for layers: the file actually written must be inside $HOME and never
# inside workbench's own state. The targets themselves (~/.gitconfig,
# ~/.ssh/config) sit on the deploy denylist by design — that list restricts
# module-declared dests; a layer's target is engine-computed.
_wb_layers_physical_ok() {
    local real="$1" resolved phys_home
    resolved="$(_wb_layers_resolve "${real}")" || return 1
    phys_home="$(cd -- "${HOME}" >/dev/null 2>&1 && pwd -P)" || return 1
    case "${resolved}" in
        "${phys_home}/.local/share/workbench/"*|"${phys_home}/.config/workbench/"*) return 1 ;;
        "${phys_home}"/*) return 0 ;;
    esac
    return 1
}

# ── File surgery (awk over temp files) ──────────────────────────────────────

# _wb_layers_locate <file> <start-marker> <end-marker>
# Prints "<start-line> <end-line>": 0 when absent; start>0 end=0 when the
# end marker is missing. Marker lines match whole, trailing whitespace
# trimmed.
_wb_layers_locate() {
    [[ -f "$1" ]] || { printf '0 0\n'; return 0; }
    awk -v s="$2" -v e="$3" '
        { l = $0; sub(/[ \t\r]+$/, "", l) }
        !st && l == s { st = NR; next }
        st && !en && l == e { en = NR }
        END { printf "%d %d\n", st, en }
    ' "$1"
}

# _wb_layers_has_user_lines <file> <comment-class>
# True when <file> has any line that is not blank, not a comment, and not
# inside a workbench block (any module's).
_wb_layers_has_user_lines() {
    [[ -s "$1" ]] || return 1
    awk -v cc="$2" '
        BEGIN { comment = "^[ \t]*" cc; bs = "^[#\"] >>> workbench [^ ]+ (under|over) >>>$"; be = "^[#\"] <<< workbench [^ ]+ (under|over) <<<$" }
        { l = $0; sub(/[ \t\r]+$/, "", l) }
        inb { if (l ~ be) inb = 0; next }
        l ~ bs { inb = 1; next }
        l == "" || l ~ comment { next }
        { found = 1; exit }
        END { exit found ? 0 : 1 }
    ' "$1"
}

# _wb_layers_strip_blocks <file>
# <file> without any workbench block (any module's), to stdout.
_wb_layers_strip_blocks() {
    [[ -f "$1" ]] || return 0
    awk '
        BEGIN { bs = "^[#\"] >>> workbench [^ ]+ (under|over) >>>$"; be = "^[#\"] <<< workbench [^ ]+ (under|over) <<<$" }
        { l = $0; sub(/[ \t\r]+$/, "", l) }
        inb { if (l ~ be) inb = 0; next }
        l ~ bs { inb = 1; next }
        { print }
    ' "$1"
}

# _wb_layers_remove_block <file> <start> <end>, to stdout.
_wb_layers_remove_block() {
    awk -v s="$2" -v e="$3" 'NR < s || NR > e' "$1"
}

# _wb_layers_compare <expected-inner> <found-inner> <tool> <missing-out> <extras-out>
# Lines compared trailing-whitespace-trimmed, as a multiset; blank found
# lines are ignored. Writes expected lines not found to <missing-out>, and
# found lines core didn't write to <extras-out> in their order — for
# gitconfig with the section header in effect restated above any line that
# would otherwise land in a different section once it's outside the block.
_wb_layers_compare() {
    awk -v tool="$3" -v missing="$4" -v extras="$5" '
        function rt(s) { sub(/[ \t\r]+$/, "", s); return s }
        FNR == NR { want[rt($0)]++; order[++n] = rt($0); next }
        {
            l = rt($0)
            if (tool == "gitconfig" && l ~ /^[ \t]*\[/) sect = l
            if (l == "") next
            if (want[l] > 0) { want[l]--; next }
            if (tool == "gitconfig" && l !~ /^[ \t]*\[/ && sect != "" && outsect != sect) { print sect > extras; outsect = sect }
            if (tool == "gitconfig" && l ~ /^[ \t]*\[/) outsect = l
            print $0 > extras
        }
        END {
            printf "" > missing; printf "" > extras
            for (i = 1; i <= n; i++) if (want[order[i]] > 0) { print order[i] > missing; want[order[i]]-- }
        }
    ' "$1" "$2"
}

# _wb_layers_write <tool> <real> <content-file> [<created:true|false>]
# Writes <content-file> to the file <real> resolves to: temp file beside it,
# then rename. Keeps the target's mode (ssh: never broader than 600); a new
# ssh config is 600 inside a 700 ~/.ssh. Never writes over a directory; a
# symlink at <real> stays a symlink (the caller decided to write through it).
_wb_layers_write() {
    local tool="$1" real="$2" content="$3" phys dir mode tmp
    phys="$(_wb_layers_resolve "${real}")" || return 1
    if [[ -d "${phys}" ]]; then
        log_error "  ${real} is a directory — not writing over it"
        return 1
    fi
    dir="$(dirname "${phys}")"
    if [[ ! -d "${dir}" ]]; then
        mkdir -p "${dir}" || return 1
        [[ "${tool}" == "ssh_config" ]] && chmod 700 "${dir}"
    fi
    if [[ -f "${phys}" ]]; then
        mode="$(_wb_files_mode "${phys}")"
        [[ "${tool}" == "ssh_config" ]] && mode="$(printf '%o' $(( 8#${mode} & 8#600 )))"
    elif [[ "${tool}" == "ssh_config" ]]; then
        mode=600
    else
        mode="$(printf '%o' $(( 8#666 & ~8#$(umask) )))"
    fi
    tmp="$(mktemp "${phys}.wb.XXXXXX")" || return 1
    if cat "${content}" > "${tmp}" && chmod "${mode}" "${tmp}" && mv -f "${tmp}" "${phys}"; then
        return 0
    fi
    rm -f "${tmp}"
    return 1
}

# ── Adopt (A.6): removing what a module's old hook wrote ────────────────────

# Normalises one line for adopt matching: trailing whitespace trimmed, a
# $HOME prefix (expanded or literal) spelled ~/.
# shellcheck disable=SC2016  # awk source, not shell
_wb_layers_adopt_norm_awk='
    function norm(s,   h) {
        sub(/[ \t\r]+$/, "", s)
        h = home "/"
        while ((i = index(s, h)) > 0) s = substr(s, 1, i - 1) "~/" substr(s, i + length(h))
        gsub(/\$\{HOME\}\//, "~/", s)
        gsub(/\$HOME\//, "~/", s)
        return s
    }'

# _wb_layers_adopt_block <real> <adopt-file> <out>
# Writes <real> minus the first run of lines matching <adopt-file> exactly
# (and one blank line directly above it) to <out>. Returns 1 when no run
# matched.
_wb_layers_adopt_block() {
    awk -v home="${HOME}" "${_wb_layers_adopt_norm_awk}"'
        FNR == NR { a[++na] = norm($0); next }
        { line[++n] = $0; nl[n] = norm($0) }
        END {
            if (na == 0) exit 1
            for (s = 1; s + na - 1 <= n && !hit; s++) {
                ok = 1
                for (k = 1; k <= na; k++) if (nl[s + k - 1] != a[k]) { ok = 0; break }
                if (ok) hit = s
            }
            if (!hit) { for (i = 1; i <= n; i++) print line[i] > out; exit 1 }
            from = hit; to = hit + na - 1
            if (from > 1 && nl[from - 1] == "") from--
            for (i = 1; i <= n; i++) if (i < from || i > to) print line[i] > out
            printf "" > out
        }
    ' out="$3" "$2" "$1"
}

# _wb_layers_adopt <module> <tool> <real> <adopt-csv> <current-dir>
# Runs on a layer's first apply and on 'wb files use'. Backs the whole
# target up first. gitconfig: '<key> <value>' per line, unset with
# --fixed-value in both the ~/ and the $HOME/ form (exit 5, no match, is
# fine). Others: one contiguous block. Then warns about any adopt line still
# found outside a workbench block — no further guessing.
_wb_layers_adopt() {
    local module="$1" tool="$2" real="$3" adopt_csv="$4" current_dir="$5"
    local rel file key value expanded rc tmp leftover
    [[ -n "${adopt_csv}" && -f "${real}" ]] || return 0
    workbench_backup_existing_file "${real}" "${module}" || return 1

    while IFS= read -r rel; do
        [[ -z "${rel}" ]] && continue
        file="${current_dir}/${rel}"
        if [[ ! -f "${file}" || -L "${file}" ]]; then
            log_warn "  adopt file ${rel} missing or a symlink — skipped"
            continue
        fi
        if [[ "${tool}" == "gitconfig" ]]; then
            while IFS=" " read -r key value || [[ -n "${key}" ]]; do
                [[ -z "${key}" ]] && continue
                expanded="${value}"
                # shellcheck disable=SC2088  # matching a literal ~/
                [[ "${value}" == "~/"* ]] && expanded="${HOME}/${value#\~/}"
                for value in "${value}" "${expanded}"; do
                    rc=0
                    git config --file "${real}" --fixed-value --unset-all "${key}" "${value}" 2>/dev/null || rc=$?
                    if [[ "${rc}" -ne 0 && "${rc}" -ne 5 ]]; then
                        log_error "  couldn't remove ${key} ${value} from ${real} (git config exit ${rc}) — not applying this layer"
                        return 1
                    fi
                done
                if git config --file "${real}" --fixed-value --get-all "${key}" "${expanded}" >/dev/null 2>&1 \
                    || git config --file "${real}" --fixed-value --get-all "${key}" "${value}" >/dev/null 2>&1; then
                    log_warn "  ${real} still has '${key} ${value}' — left as it is"
                fi
            done < "${file}"
        else
            tmp="$(mktemp "${real}.wb.XXXXXX")" || return 1
            if _wb_layers_adopt_block "${real}" "${file}" "${tmp}"; then
                _wb_layers_write "${tool}" "${real}" "${tmp}" || { rm -f "${tmp}"; return 1; }
                log_info "  removed workbench's older ${tool} lines from ${real}"
            fi
            rm -f "${tmp}"
            leftover="$(_wb_layers_strip_blocks "${real}" | awk -v home="${HOME}" "${_wb_layers_adopt_norm_awk}"'
                FNR == NR { if (norm($0) != "") a[norm($0)] = $0; next }
                (norm($0) in a) { print a[norm($0)] }' "${file}" -)"
            if [[ -n "${leftover}" ]]; then
                while IFS= read -r rel; do
                    log_warn "  ${real} still has '${rel}' — workbench's older block didn't match exactly; left as it is"
                done <<< "${leftover}"
            fi
        fi
    done < <(printf '%s\n' "${adopt_csv}" | tr ',' '\n')
    return 0
}

# ── Apply ───────────────────────────────────────────────────────────────────

# Sets WB_L_* from one layer target line.
_wb_layers_fields() {
    local base dest source
    IFS='|' read -r base _ dest _ _ _ _ source <<< "$1"
    WB_L_ID="${base}"
    WB_L_TOOL="${base%%:*}"
    WB_L_KEY="${dest}"
    WB_L_TARGET="${dest%#*}"
    WB_L_POSITION="${dest##*#}"
    WB_L_SOURCE="${source}"
    WB_L_REAL="$(_wb_expand_dest "${WB_L_TARGET}")"
}

# workbench_layers_line <module> <layer-id>
workbench_layers_line() {
    workbench_files_targets "$1" | awk -F'|' -v id="$2" '$7 == "layer" && $1 == id { print; exit }'
}

# _wb_layers_compose <module> <real> <block-file> <work-dir> [settle]
# Builds the target's new content in <work-dir>/new from its current
# content and the expected block. Sets WB_L_OUTCOME to one of:
#   unchanged | write | removed (markers gone) | user (expected line gone,
#   or the end marker is) — the last two write nothing.
_wb_layers_compose() {
    local module="$1" real="$2" block="$3" w="$4" mode="${5:-}"
    local start end s e cc top
    start="$(workbench_layers_marker_start "${module}" "${WB_L_TOOL}" "${WB_L_POSITION}")"
    end="$(workbench_layers_marker_end "${module}" "${WB_L_TOOL}" "${WB_L_POSITION}")"
    cc="$(_wb_layers_comment_class "${WB_L_TOOL}")"
    top=false
    _wb_layers_is_top "${WB_L_TOOL}" "${WB_L_POSITION}" && top=true
    : > "${w}/cur"
    [[ -f "${real}" ]] && cat "${real}" > "${w}/cur"
    read -r s e <<< "$(_wb_layers_locate "${w}/cur" "${start}" "${end}")"

    if [[ "${s}" -eq 0 ]]; then
        if [[ "${mode}" == "first" ]]; then
            if [[ "${top}" == "true" ]]; then
                cat "${block}" "${w}/cur" > "${w}/new"
            else
                cat "${w}/cur" > "${w}/new"
                [[ -s "${w}/cur" && -n "$(tail -c 1 "${w}/cur")" ]] && printf '\n' >> "${w}/new"
                cat "${block}" >> "${w}/new"
            fi
            WB_L_OUTCOME='write'
        else
            WB_L_OUTCOME=removed
        fi
        return 0
    fi
    if [[ "${e}" -eq 0 ]]; then
        WB_L_OUTCOME=user
        return 0
    fi

    sed -n "$((s + 1)),$((e - 1))p" "${w}/cur" > "${w}/found"
    sed '1d;$d' "${block}" > "${w}/want"
    _wb_layers_compare "${w}/want" "${w}/found" "${WB_L_TOOL}" "${w}/missing" "${w}/extras"
    if [[ -s "${w}/missing" ]]; then
        WB_L_OUTCOME=user
        return 0
    fi
    [[ "${mode}" == "settle" && -s "${w}/extras" ]] && { WB_L_OUTCOME=unchanged; return 0; }

    # pre + block + extras + post; then put the block back in position if
    # anything of the user's ended up on the wrong side of it.
    if [[ "${s}" -gt 1 ]]; then sed -n "1,$((s - 1))p" "${w}/cur" > "${w}/pre"; else : > "${w}/pre"; fi
    sed -n "$((e + 1)),\$p" "${w}/cur" > "${w}/post"
    cat "${w}/extras" "${w}/post" > "${w}/after"
    if [[ "${top}" == "true" ]] && _wb_layers_has_user_lines "${w}/pre" "${cc}"; then
        cat "${block}" "${w}/pre" "${w}/after" > "${w}/new"
    elif [[ "${top}" != "true" ]] && _wb_layers_has_user_lines "${w}/after" "${cc}"; then
        cat "${w}/pre" "${w}/after" > "${w}/new"
        [[ -s "${w}/new" && -n "$(tail -c 1 "${w}/new")" ]] && printf '\n' >> "${w}/new"
        cat "${block}" >> "${w}/new"
    else
        cat "${w}/pre" "${block}" "${w}/after" > "${w}/new"
    fi
    if cmp -s "${w}/cur" "${w}/new"; then
        WB_L_OUTCOME=unchanged
    else
        WB_L_OUTCOME='write'
        [[ -s "${w}/extras" ]] && log_info "  ${WB_L_TARGET}: moved $(grep -c . "${w}/extras" | tr -d ' ') line(s) of yours out of workbench's block, just below it"
    fi
}

# _wb_layers_commit <module> <real> <new-file> <before-copy> <existed:true|false> <before-valid>
# Writes, validates, rolls back. 0 written, 1 failed (target as it was).
_wb_layers_commit() {
    local module="$1" real="$2" new="$3" before="$4" existed="$5" before_rc="$6" after_rc=0
    if ! _wb_layers_write "${WB_L_TOOL}" "${real}" "${new}"; then
        log_error "  failed to write ${WB_L_TARGET}"
        return 1
    fi
    _wb_layers_validate "${WB_L_TOOL}" "${real}" || after_rc=$?
    if [[ "${after_rc}" -eq 1 ]]; then
        if [[ "${before_rc}" -eq 1 ]]; then
            log_warn "  ${WB_L_TARGET}: ${WB_L_TOOL} already reported errors in this file before workbench changed it — written anyway; check it yourself"
            return 0
        fi
        if [[ "${existed}" == "true" ]]; then
            _wb_layers_write "${WB_L_TOOL}" "${real}" "${before}"
        else
            rm -f "$(_wb_layers_resolve "${real}")"
        fi
        log_error "  ${WB_L_TARGET}: ${WB_L_TOOL} rejects the file with ${module}'s ${WB_L_ID} layer in it — put back as it was (check ${WB_L_SOURCE})"
        return 1
    fi
    return 0
}

# _wb_layers_convert_deploy_row <module>
# A.5: a D81 deploy row of this module at this layer's target (workbench-
# shell's tmux.conf and vimrc on hosts from before layers). Prints the
# conversion — active | edited — or nothing; deletes the row.
_wb_layers_convert_deploy_row() {
    local module="$1" row state sha
    row="$(workbench_files_ledger_get "${module}" "${WB_L_TARGET}")"
    [[ -z "${row}" ]] && return 0
    [[ "$(printf '%s\n' "${row}" | awk -F'|' '{ print $2 }')" == "deploy" ]] || return 0
    state="$(printf '%s\n' "${row}" | awk -F'|' '{ print $3 }')"
    sha="$(printf '%s\n' "${row}" | awk -F'|' '{ print $4 }')"
    WB_L_DEPLOY_ORIGINAL="$(printf '%s\n' "${row}" | awk -F'|' '{ print $5 }')"
    workbench_files_ledger_delete "${module}" "${WB_L_TARGET}"
    if [[ "${state}" == "active" && -f "${WB_L_REAL}" && ! -L "${WB_L_REAL}" && "$(_wb_sha256 "${WB_L_REAL}")" == "${sha}" ]]; then
        printf 'active\n'
    elif [[ -e "${WB_L_REAL}" ]]; then
        printf 'edited\n'
    fi
}

# workbench_layers_apply <module> <layer-id> [<target-line>] [settle]
# The sync engine's entry point for one layer (rules A.3, in order).
# 'settle' re-runs position self-heal only (wb files settle).
workbench_layers_apply() {
    local module="$1" id="$2" line="${3:-}" mode="${4:-}"
    local policy row state original created=false w existed=false before_rc=0 rc=0 convert="" sha
    [[ -z "${line}" ]] && line="$(workbench_layers_line "${module}" "${id}")"
    [[ -z "${line}" ]] && return 0
    _wb_layers_fields "${line}"

    if ! _wb_layers_physical_ok "${WB_L_REAL}"; then
        log_error "  ${WB_L_TARGET}: resolves outside your home directory or into workbench's own state — not writing ${module}'s ${WB_L_ID} layer"
        return 1
    fi
    policy="$(workbench_files_policy_get "${module}" "${WB_L_ID}")"
    row="$(workbench_files_ledger_get "${module}" "${WB_L_KEY}")"
    state="$(printf '%s\n' "${row}" | awk -F'|' '{ print $3 }')"
    original="$(printf '%s\n' "${row}" | awk -F'|' '{ print $5 }')"
    [[ -z "${original}" ]] && original="-"

    # 1. policy
    if [[ "${policy}" == "skip" ]]; then
        [[ "${mode}" == "settle" ]] && return 0
        workbench_layers_remove_block "${module}" "${line}" || return 1
        [[ "${state}" == "restored" ]] || workbench_files_ledger_set "${module}" "${WB_L_KEY}" layer user - "${original}"
        return 0
    fi
    # 2. a symlinked target (stow, chezmoi, yadm) — only with consent
    if [[ -L "${WB_L_REAL}" && "${policy}" != "managed" ]]; then
        [[ "${mode}" == "settle" ]] || log_info "  ${WB_L_TARGET} is a symlink you manage — not adding ${module}'s ${WB_L_ID} layer until you choose: 'wb files resolve ${module} ${WB_L_ID} use|keep'"
        return 0
    fi
    # 3. frozen states
    case "${state}" in
        removed|user|restored) return 0 ;;
    esac
    if [[ "${mode}" == "settle" && "${state}" != "active" ]]; then
        return 0
    fi

    w="$(mktemp -d "${TMPDIR:-/tmp}/wb-layer.XXXXXX")" || return 1
    [[ -f "${WB_L_REAL}" ]] && existed=true
    [[ "${existed}" == "true" ]] && cat "${WB_L_REAL}" > "${w}/before"
    _wb_layers_validate "${WB_L_TOOL}" "${WB_L_REAL}" || before_rc=$?

    if [[ -z "${state}" ]]; then
        # 4. first apply: convert a D81 copy at this target, adopt, write
        WB_L_DEPLOY_ORIGINAL="-"
        convert="$(_wb_layers_convert_deploy_row "${module}")"
        if [[ "${convert}" == "active" ]]; then
            original="${WB_L_DEPLOY_ORIGINAL:--}"
            [[ "${original}" == "-" ]] && original="+created"
            created=true
        elif [[ "${existed}" != "true" ]]; then
            original="+created"
            created=true
        else
            original="-"
            if [[ "${convert}" != "edited" ]] && ! _wb_layers_adopt "${module}" "${WB_L_TOOL}" "${WB_L_REAL}" \
                "$(workbench_layers_adopt_paths "${module}" "${WB_L_ID}")" "$(workbench_module_current_dir "${module}")"; then
                [[ "${existed}" == "true" ]] && _wb_layers_write "${WB_L_TOOL}" "${WB_L_REAL}" "${w}/before"
                rm -rf "${w}"
                return 1
            fi
        fi
    elif [[ "${original}" != "-" ]]; then
        created=true
    fi

    if [[ "${WB_L_TOOL}" == "ssh_config" ]]; then
        # ssh refuses a group/other-writable included file on hosts without
        # user-private groups (macOS); core owns the snapshot.
        chmod go-w "${WB_L_SOURCE}" 2>/dev/null || true
    fi

    workbench_layers_block "${module}" "${WB_L_TOOL}" "${WB_L_POSITION}" "${WB_L_SOURCE}" "${created}" > "${w}/block"
    if [[ "${convert}" == "active" ]]; then
        cp "${w}/block" "${w}/new"
        WB_L_OUTCOME='write'
    else
        _wb_layers_compose "${module}" "${WB_L_REAL}" "${w}/block" "${w}" "$([[ -z "${state}" ]] && echo first || echo "${mode}")"
    fi

    # settle moves blocks; it never changes what state a block is in
    [[ "${mode}" == "settle" && "${WB_L_OUTCOME}" != "write" ]] && WB_L_OUTCOME=unchanged
    case "${WB_L_OUTCOME}" in
        removed)
            workbench_files_ledger_set "${module}" "${WB_L_KEY}" layer removed - "${original}"
            log_info "  ${WB_L_TARGET}: you removed ${module}'s ${WB_L_ID} block — workbench won't add it again ('wb files use ${module} ${WB_L_ID}' brings it back)"
            ;;
        user)
            workbench_files_ledger_set "${module}" "${WB_L_KEY}" layer user - "${original}"
            log_info "  ${WB_L_TARGET}: you edited ${module}'s ${WB_L_ID} block — it's yours now; workbench won't change it ('wb files use ${module} ${WB_L_ID}' resets it)"
            ;;
        unchanged)
            sha="$(_wb_sha256 "${w}/block")"
            [[ "$(printf '%s\n' "${row}" | awk -F'|' '{ print $4 }')" == "${sha}" ]] || \
                workbench_files_ledger_set "${module}" "${WB_L_KEY}" layer active "${sha}" "${original}"
            ;;
        write)
            if _wb_layers_commit "${module}" "${WB_L_REAL}" "${w}/new" "${w}/before" "${existed}" "${before_rc}"; then
                workbench_files_ledger_set "${module}" "${WB_L_KEY}" layer active "$(_wb_sha256 "${w}/block")" "${original}"
                if [[ -z "${state}" ]]; then
                    log_info "  layered: ${WB_L_TARGET} (${module}/${WB_L_ID}, ${WB_L_POSITION})"
                    [[ "${convert}" == "edited" ]] && log_warn "  ${WB_L_TARGET} still contains an older copy of ${module}'s defaults — lines you keep there override future ${module} changes"
                elif [[ "${mode}" == "settle" ]]; then
                    log_info "  ${WB_L_TARGET}: moved ${module}'s ${WB_L_ID} block back into place"
                fi
            else
                rc=1
            fi
            ;;
    esac
    rm -rf "${w}"
    return "${rc}"
}

# workbench_layers_remove_block <module> <target-line>
# Removes this layer's block, nothing else. 0 also when there's none.
workbench_layers_remove_block() {
    local module="$1" line="$2" s e w
    _wb_layers_fields "${line}"
    [[ -f "${WB_L_REAL}" ]] || return 0
    read -r s e <<< "$(_wb_layers_locate "${WB_L_REAL}" \
        "$(workbench_layers_marker_start "${module}" "${WB_L_TOOL}" "${WB_L_POSITION}")" \
        "$(workbench_layers_marker_end "${module}" "${WB_L_TOOL}" "${WB_L_POSITION}")")"
    [[ "${s}" -gt 0 && "${e}" -gt 0 ]] || return 0
    w="$(mktemp "${WB_L_REAL}.wb.XXXXXX")" || return 1
    _wb_layers_remove_block "${WB_L_REAL}" "${s}" "${e}" > "${w}"
    if _wb_layers_write "${WB_L_TOOL}" "${WB_L_REAL}" "${w}"; then
        log_info "  removed ${module}'s ${WB_L_ID} block from ${WB_L_TARGET}"
        rm -f "${w}"
        return 0
    fi
    rm -f "${w}"
    return 1
}

# workbench_layers_settle <module>
# Puts each of the module's active blocks back in position after something
# wrote to their files (Core API _wb_layers_settle). Nothing else.
workbench_layers_settle() {
    local module="$1" line rc=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        workbench_layers_apply "${module}" "${line%%|*}" "${line}" settle || rc=1
    done < <(workbench_files_targets "${module}" | awk -F'|' '$7 == "layer"')
    return "${rc}"
}

# ── State, for status, pending and install ──────────────────────────────────

# workbench_layers_state <module> <target-line>
# Prints: not applied | active | skipped | linked | yours (edited) |
# removed by you | restored
workbench_layers_state() {
    local module="$1" line="$2" state
    _wb_layers_fields "${line}"
    state="$(workbench_files_ledger_field "${module}" "${WB_L_KEY}" 3)"
    if [[ "$(workbench_files_policy_get "${module}" "${WB_L_ID}")" == "skip" ]]; then
        [[ "${state}" == "restored" ]] && { printf 'restored\n'; return 0; }
        printf 'skipped\n'; return 0
    fi
    case "${state}" in
        active)   printf 'active\n' ;;
        user)     printf 'yours (edited)\n' ;;
        removed)  printf 'removed by you\n' ;;
        restored) printf 'restored\n' ;;
        *)
            if [[ -L "${WB_L_REAL}" && "$(workbench_files_policy_get "${module}" "${WB_L_ID}")" != "managed" ]]; then
                printf 'linked\n'
            else
                printf 'not applied\n'
            fi ;;
    esac
}

# True when the target holds config of the user's own (anything outside
# workbench blocks) or is a symlink the user manages.
workbench_layers_target_is_users() {
    local line="$1"
    _wb_layers_fields "${line}"
    [[ -L "${WB_L_REAL}" ]] && return 0
    [[ -f "${WB_L_REAL}" ]] || return 1
    _wb_layers_has_user_lines "${WB_L_REAL}" "$(_wb_layers_comment_class "${WB_L_TOOL}")"
}

# ── Carry-over on use (docs/decisions-log.md D84) ──────────────────────────
#
# 'Use workbench's' replaces the user's opinions, not their data. What's
# carried from the user's file into the new one, the full original backed
# up first in every case:
#   gitconfig    every [user] section, all keys — below the top block
#   ssh_config   top-level Include lines, and every Host/Match block whose
#                pattern isn't exactly '*' or 'all' — above the bottom
#                block, in their original order. The user's global defaults
#                (lines before the first Host/Match, Host *, Match all) are
#                what workbench's defaults replace.
#   tmux.conf, vimrc   nothing

# _wb_layers_carry <tool> <file> <out> [<notes-out>]
# Writes the carried lines of <file> (workbench blocks ignored) to <out>.
# ssh blocks kept but not obviously host-specific (Match exec, a Host
# pattern mixing '*' with names) are listed in <notes-out>: kept rather than
# guessed at.
_wb_layers_carry() {
    local tool="$1" file="$2" out="$3" notes="${4:-/dev/null}"
    : > "${out}"; : > "${notes}"
    [[ -f "${file}" ]] || return 0
    case "${tool}" in
        gitconfig)
            _wb_layers_strip_blocks "${file}" | awk '
                { t = tolower($0); sub(/^[ \t]+/, "", t) }
                t ~ /^\[/ { in_user = (t ~ /^\[user\][ \t]*([#;].*)?$/) }
                in_user { print }
            ' > "${out}" ;;
        ssh_config)
            _wb_layers_strip_blocks "${file}" | awk -v notes="${notes}" '
                {
                    t = $0; sub(/^[ \t]+/, "", t); lt = tolower(t)
                }
                lt ~ /^(host|match)([ \t]|=)/ {
                    args = t; sub(/^[A-Za-z]+[ \t]*=?[ \t]*/, "", args); sub(/[ \t]+#.*$/, "", args); sub(/[ \t]+$/, "", args)
                    kw = (lt ~ /^host/) ? "host" : "match"
                    in_block = 1
                    drop = (kw == "host" && args == "*") || (kw == "match" && tolower(args) == "all")
                    if (!drop && kw == "match" && tolower(args) ~ /(^|[ \t])exec([ \t]|$)/) print "Match " args > notes
                    if (!drop && kw == "host" && args ~ /\*/ && args !~ /^[^ \t]+$/) print "Host " args > notes
                    if (!drop) print
                    next
                }
                !in_block { if (lt ~ /^include([ \t]|=)/) print; next }
                !drop { print }
            ' > "${out}" ;;
    esac
}

# workbench_layers_carry_summary <target-line>
# One preview line per kind of thing 'use' would carry over, indented.
workbench_layers_carry_summary() {
    local line="$1" w keys names count
    _wb_layers_fields "${line}"
    [[ -f "${WB_L_REAL}" ]] || return 0
    w="$(mktemp -d "${TMPDIR:-/tmp}/wb-layer.XXXXXX")" || return 0
    _wb_layers_carry "${WB_L_TOOL}" "$(_wb_layers_resolve "${WB_L_REAL}")" "${w}/carry" "${w}/notes"
    case "${WB_L_TOOL}" in
        gitconfig)
            keys="$(awk -F'=' '/^[ \t]*[A-Za-z][A-Za-z0-9-]*[ \t]*=/ { k = $1; gsub(/[ \t]/, "", k); printf "%s%s", (n++ ? ", " : ""), k }' "${w}/carry")"
            [[ -n "${keys}" ]] && printf '      keep your [user] section (%s)\n' "${keys}" ;;
        ssh_config)
            count="$(grep -ciE '^[[:space:]]*(host|match)([[:space:]]|=)' "${w}/carry")"
            if [[ "${count}" -gt 0 ]]; then
                names="$(awk '{ t = $0; sub(/^[ \t]+/, "", t) } tolower(t) ~ /^(host|match)([ \t]|=)/ { sub(/^[A-Za-z]+[ \t]*=?[ \t]*/, "", t); printf "%s%s", (n++ ? ", " : ""), t }' "${w}/carry" | cut -c1-70)"
                printf '      keep %s Host/Match entr%s: %s\n' "${count}" "$([[ "${count}" -eq 1 ]] && echo y || echo ies)" "${names}"
            fi
            count="$(grep -ciE '^[[:space:]]*include([[:space:]]|=)' "${w}/carry")"
            [[ "${count}" -gt 0 ]] && printf '      keep %s Include line(s)\n' "${count}"
            while IFS= read -r names; do
                [[ -n "${names}" ]] && printf '      kept as it is — check it yourself: %s\n' "${names}"
            done < "${w}/notes" ;;
    esac
    rm -rf "${w}"
}

# _wb_layers_split_blocks <file> <top-out> <bottom-out>
# Every workbench block in <file>, sorted by where its adapter places it.
_wb_layers_split_blocks() {
    awk -v top="$2" -v bottom="$3" '
        BEGIN { printf "" > top; printf "" > bottom
                bs = "^[#\"] >>> workbench [^ ]+ (under|over) >>>$"; be = "^[#\"] <<< workbench [^ ]+ (under|over) <<<$" }
        { l = $0; sub(/[ \t\r]+$/, "", l) }
        !inb && l ~ bs {
            split(l, f, " "); split(f[4], mt, "/"); tool = mt[2]; pos = f[5]
            dest = ((tool == "ssh_config") ? (pos == "over") : (pos == "under")) ? top : bottom
            inb = 1
        }
        inb { print > dest; if (l ~ be) inb = 0 }
    ' "$1"
}

# _wb_layers_user_text <file> — the user's lines (outside every block),
# blank lines dropped and trailing whitespace trimmed: for comparing.
_wb_layers_user_text() {
    _wb_layers_strip_blocks "$1" | awk '{ sub(/[ \t\r]+$/, "") } $0 != ""'
}

# ── User-invoked operations ─────────────────────────────────────────────────

# workbench_layers_use <module> <target-line>
# "Use the module's version": the whole target is backed up, and replaced
# with a file holding workbench's blocks (this one, written fresh, and any
# other block already there) and what carries over (above). Through a symlink, this is the consent
# to write through it (policy managed); otherwise the per-layer policy is
# cleared.
workbench_layers_use() {
    local module="$1" line="$2" row original w existed=false before_rc=0 start end s e backup
    _wb_layers_fields "${line}"
    if ! _wb_layers_physical_ok "${WB_L_REAL}"; then
        log_error "  ${WB_L_TARGET}: resolves outside your home directory or into workbench's own state — refusing"
        return 1
    fi
    row="$(workbench_files_ledger_get "${module}" "${WB_L_KEY}")"
    original="$(printf '%s\n' "${row}" | awk -F'|' '{ print $5 }')"
    [[ -z "${original}" ]] && original="-"
    w="$(mktemp -d "${TMPDIR:-/tmp}/wb-layer.XXXXXX")" || return 1
    [[ -f "${WB_L_REAL}" ]] && { existed=true; cat "${WB_L_REAL}" > "${w}/before"; }
    _wb_layers_validate "${WB_L_TOOL}" "${WB_L_REAL}" || before_rc=$?

    if [[ "${existed}" == "true" ]] && workbench_layers_target_is_users "${line}"; then
        # The content, not a symlink: through a link it's the file the
        # link points at that changes.
        backup="$(_wb_backup_path_new "${WB_L_REAL}" "${module}")" \
            && cp -p "$(_wb_layers_resolve "${WB_L_REAL}")" "${backup}" || {
            log_error "  failed to back up ${WB_L_TARGET} — nothing was changed"
            rm -rf "${w}"
            return 1
        }
        log_info "  backed up ${WB_L_TARGET} -> ${backup}"
        [[ "${original}" == "-" || "${original}" == "+created" ]] && original="${backup}"
    elif [[ "${existed}" != "true" && "${original}" == "-" ]]; then
        original="+created"
    fi
    [[ "${original}" == "-" ]] && original="+created"

    workbench_layers_block "${module}" "${WB_L_TOOL}" "${WB_L_POSITION}" "${WB_L_SOURCE}" true > "${w}/block"
    start="$(workbench_layers_marker_start "${module}" "${WB_L_TOOL}" "${WB_L_POSITION}")"
    end="$(workbench_layers_marker_end "${module}" "${WB_L_TOOL}" "${WB_L_POSITION}")"
    : > "${w}/others"
    [[ "${existed}" == "true" ]] && cp "${w}/before" "${w}/others"
    read -r s e <<< "$(_wb_layers_locate "${w}/others" "${start}" "${end}")"
    if [[ "${s}" -gt 0 && "${e}" -gt 0 ]]; then
        _wb_layers_remove_block "${w}/others" "${s}" "${e}" > "${w}/rest"
    else
        cp "${w}/others" "${w}/rest"
    fi
    _wb_layers_split_blocks "${w}/rest" "${w}/top" "${w}/bottom"
    if _wb_layers_is_top "${WB_L_TOOL}" "${WB_L_POSITION}"; then
        cat "${w}/block" "${w}/top" > "${w}/top.new" && mv "${w}/top.new" "${w}/top"
    else
        cat "${w}/bottom" "${w}/block" > "${w}/bottom.new" && mv "${w}/bottom.new" "${w}/bottom"
    fi
    _wb_layers_carry "${WB_L_TOOL}" "${w}/rest" "${w}/carry"
    cat "${w}/top" "${w}/carry" "${w}/bottom" > "${w}/new"
    [[ "${WB_L_TOOL}" == "ssh_config" ]] && chmod go-w "${WB_L_SOURCE}" 2>/dev/null

    if ! _wb_layers_commit "${module}" "${WB_L_REAL}" "${w}/new" "${w}/before" "${existed}" "${before_rc}"; then
        rm -rf "${w}"
        return 1
    fi
    workbench_files_ledger_set "${module}" "${WB_L_KEY}" layer active \
        "$(workbench_layers_block "${module}" "${WB_L_TOOL}" "${WB_L_POSITION}" "${WB_L_SOURCE}" true | _wb_layers_sha_stdin)" "${original}"
    if [[ -L "${WB_L_REAL}" ]]; then
        workbench_files_policy_set "${module}" "${WB_L_ID}" managed
    else
        workbench_files_policy_set "${module}" "${WB_L_ID}" default
    fi
    if [[ -s "${w}/carry" ]]; then
        log_info "  ${WB_L_TARGET}: now workbench's block, with your $([[ "${WB_L_TOOL}" == "gitconfig" ]] && echo "[user] section" || echo "hosts and includes") kept ('wb files restore ${module} ${WB_L_ID}' puts yours back)"
    else
        log_info "  ${WB_L_TARGET}: now only workbench's block ('wb files restore ${module} ${WB_L_ID}' puts yours back)"
    fi
    rm -rf "${w}"
    workbench_files_write_pending "${module}"
}

_wb_layers_sha_stdin() {
    local t rc=0
    t="$(mktemp "${TMPDIR:-/tmp}/wb-layer-sha.XXXXXX")" || return 1
    cat > "${t}"
    _wb_sha256 "${t}" || rc=1
    rm -f "${t}"
    return "${rc}"
}

# workbench_layers_resolve <module> <target-line> keep|use
# Settles a symlinked target: use = write through the link (policy
# managed), keep = leave it alone (policy skip). 3 when nothing is waiting.
workbench_layers_resolve() {
    local module="$1" line="$2" choice="$3"
    _wb_layers_fields "${line}"
    case "${choice}" in
        use)
            workbench_files_policy_set "${module}" "${WB_L_ID}" managed || return 1
            workbench_layers_apply "${module}" "${WB_L_ID}" "${line}" || return 1
            ;;
        keep)
            workbench_files_policy_set "${module}" "${WB_L_ID}" skip || return 1
            workbench_layers_apply "${module}" "${WB_L_ID}" "${line}" || return 1
            log_info "  ${WB_L_TARGET}: left alone — ${module}'s ${WB_L_ID} layer is skipped"
            ;;
        *)
            log_error "workbench_layers_resolve: '${choice}' isn't a choice for a layer — keep or use"
            return 2 ;;
    esac
    workbench_files_write_pending "${module}"
}

# workbench_layers_restore <module> <ledger-key>
# Removes the block. A backed-up original ('wb files use') is put back when
# nothing of the user's has appeared since; a file core created is deleted
# when nothing but blocks remains. The user's lines are never removed. Ends
# 'restored' with policy skip. 3 when there's nothing of workbench's here.
workbench_layers_restore() {
    local module="$1" key="$2" row state original line target real tool position id s e w rc=0
    row="$(workbench_files_ledger_get "${module}" "${key}")"
    [[ -z "${row}" ]] && return 3
    state="$(printf '%s\n' "${row}" | awk -F'|' '{ print $3 }')"
    original="$(printf '%s\n' "${row}" | awk -F'|' '{ print $5 }')"
    [[ "${state}" == "active" ]] || return 3
    target="${key%#*}"
    position="${key##*#}"
    real="$(_wb_expand_dest "${target}")"
    line="$(workbench_files_targets "${module}" 2>/dev/null | awk -F'|' -v k="${key}" '$7 == "layer" && $3 == k { print; exit }')"
    if [[ -n "${line}" ]]; then
        tool="${line%%|*}"; tool="${tool%%:*}"
    else
        tool="$(_wb_layers_tool_for_target "${target}")"
    fi
    id="$(workbench_layers_id "${tool}" "${position}")"
    if ! _wb_layers_physical_ok "${real}"; then
        log_error "  ${target}: resolves outside your home directory or into workbench's own state — refusing"
        return 1
    fi

    w="$(mktemp -d "${TMPDIR:-/tmp}/wb-layer.XXXXXX")" || return 1
    if [[ -f "${real}" ]]; then
        read -r s e <<< "$(_wb_layers_locate "${real}" \
            "$(workbench_layers_marker_start "${module}" "${tool}" "${position}")" \
            "$(workbench_layers_marker_end "${module}" "${tool}" "${position}")")"
        if [[ "${s}" -gt 0 && "${e}" -gt 0 ]]; then
            _wb_layers_remove_block "${real}" "${s}" "${e}" > "${w}/rest"
        else
            cat "${real}" > "${w}/rest"
        fi
        if [[ "${original}" != "-" && "${original}" != "+created" && -f "${original}" ]] \
            && _wb_layers_unchanged_since_use "${tool}" "${w}/rest" "${original}"; then
            # Put back what 'use' backed up, minus this block if it held one.
            read -r s e <<< "$(_wb_layers_locate "${original}" \
                "$(workbench_layers_marker_start "${module}" "${tool}" "${position}")" \
                "$(workbench_layers_marker_end "${module}" "${tool}" "${position}")")"
            if [[ "${s}" -gt 0 && "${e}" -gt 0 ]]; then
                _wb_layers_remove_block "${original}" "${s}" "${e}" > "${w}/rest"
            else
                cat "${original}" > "${w}/rest"
            fi
            _wb_layers_write "${tool}" "${real}" "${w}/rest" && log_info "  restored ${target} from ${original}" || rc=1
        elif [[ "${original}" == "+created" ]] && ! grep -q '[^[:space:]]' "${w}/rest"; then
            rm -f "$(_wb_layers_resolve "${real}")" && log_info "  removed ${target} (workbench created it)" || rc=1
        else
            if [[ "${original}" != "-" && "${original}" != "+created" ]]; then
                log_warn "  ${target}: has settings of yours added since — not putting back ${original}; it's still there"
            fi
            if [[ "${s}" -gt 0 && "${e}" -gt 0 ]]; then
                _wb_layers_write "${tool}" "${real}" "${w}/rest" && log_info "  removed ${module}'s ${id} block from ${target}" || rc=1
            fi
        fi
    fi
    rm -rf "${w}"
    [[ "${rc}" -eq 0 ]] || return 1
    workbench_files_ledger_set "${module}" "${key}" layer restored - "${original}"
    workbench_files_policy_set "${module}" "${id}" skip
    workbench_files_write_pending "${module}"
    return 0
}

# _wb_layers_unchanged_since_use <tool> <current-minus-block> <backup>
# True when nothing of the user's has been added since 'use': the user's
# lines are none, exactly what 'use' carried over, or what the backup
# already holds.
_wb_layers_unchanged_since_use() {
    local tool="$1" rest="$2" backup="$3" now w rc=1
    now="$(_wb_layers_user_text "${rest}")"
    [[ -z "${now}" ]] && return 0
    [[ "${now}" == "$(_wb_layers_user_text "${backup}")" ]] && return 0
    w="$(mktemp "${TMPDIR:-/tmp}/wb-layer-carry.XXXXXX")" || return 1
    _wb_layers_carry "${tool}" "${backup}" "${w}"
    [[ "${now}" == "$(_wb_layers_user_text "${w}")" ]] && rc=0
    rm -f "${w}"
    return "${rc}"
}

# An adapter for a target with no manifest entry left (restore after a
# module dropped the layer).
_wb_layers_tool_for_target() {
    case "$1" in
        *gitconfig)   printf 'gitconfig\n' ;;
        */.ssh/config) printf 'ssh_config\n' ;;
        *tmux*)       printf 'tmux.conf\n' ;;
        *vimrc)       printf 'vimrc\n' ;;
    esac
}

# workbench_layers_diff <module> <target-line>
# The block core would write against the block found in the target.
workbench_layers_diff() {
    local module="$1" line="$2" w s e created=false original
    _wb_layers_fields "${line}"
    original="$(workbench_files_ledger_field "${module}" "${WB_L_KEY}" 5)"
    [[ -n "${original}" && "${original}" != "-" ]] && created=true
    w="$(mktemp -d "${TMPDIR:-/tmp}/wb-layer.XXXXXX")" || return 1
    workbench_layers_block "${module}" "${WB_L_TOOL}" "${WB_L_POSITION}" "${WB_L_SOURCE}" "${created}" > "${w}/expected"
    : > "${w}/found"
    if [[ -f "${WB_L_REAL}" ]]; then
        read -r s e <<< "$(_wb_layers_locate "${WB_L_REAL}" \
            "$(workbench_layers_marker_start "${module}" "${WB_L_TOOL}" "${WB_L_POSITION}")" \
            "$(workbench_layers_marker_end "${module}" "${WB_L_TOOL}" "${WB_L_POSITION}")")"
        if [[ "${s}" -gt 0 ]]; then
            [[ "${e}" -eq 0 ]] && e='$'
            sed -n "${s},${e}p" "${WB_L_REAL}" > "${w}/found"
        fi
    fi
    if [[ ! -s "${w}/found" ]]; then
        echo "$(_wb_files_display_path "${WB_L_TARGET}"): no ${module}/${WB_L_ID} block in it. Workbench's block would be:"
        sed 's/^/    /' "${w}/expected"
    elif cmp -s "${w}/expected" "${w}/found"; then
        echo "$(_wb_files_display_path "${WB_L_TARGET}"): ${module}'s ${WB_L_ID} block is as workbench wrote it."
    else
        diff -u -L "workbench: ${module}/${WB_L_ID}" -L "found in $(_wb_files_display_path "${WB_L_TARGET}")" "${w}/expected" "${w}/found"
    fi
    rm -rf "${w}"
    return 0
}
