#!/usr/bin/env bash
# lib/core/semver.sh — pure-bash, bash-3.2-safe version comparison.
#
# Generalised from workbench-precursor's install.sh version_ge(), but
# deliberately NOT reusing its `sort -V` implementation — the build brief
# forbids introducing (or depending on) sort -V, python3, yq, or jq for any
# of this. Everything here is string/array manipulation and integer
# arithmetic only.
#
# Two independent uses:
#   1. Tag format filtering/comparison for TRACK_MODE=latest resolution
#      (ARCHITECTURE.md §9.2) — only clean vX.Y.Z tags participate.
#   2. core_api range satisfaction for manifest gating (ARCHITECTURE.md §6) —
#      e.g. does CORE_API_VERSION=1 satisfy a module's declared
#      core_api: ">=1.0 <2.0"?
#
# No [[ =~ ]] regex matching is used — zsh's extended-regex support for =~
# is not guaranteed to be loaded by default, unlike bash's. Tag-shape
# validation instead uses plain glob/case matching plus a per-segment
# digit-only check, which behaves identically in both shells.

# _wb_semver_is_clean_tag <tag>
# True iff <tag> is exactly vX.Y.Z — three numeric segments, v-prefixed, no
# pre-release/build suffix. Anything else (missing 'v', two segments,
# "-rc1" suffix, non-numeric segment) is rejected. A rejected tag is not an
# error — it simply doesn't participate in `latest` resolution; it remains a
# perfectly valid explicit `tag:<name>` pin.
_wb_semver_is_clean_tag() {
    local tag="$1"
    case "${tag}" in
        v*) : ;;
        *) return 1 ;;
    esac
    local rest="${tag#v}"
    local -a parts
    IFS='.' read -r -a parts <<< "${rest}"
    [[ "${#parts[@]}" -eq 3 ]] || return 1
    local p
    for p in "${parts[@]}"; do
        [[ -n "${p}" ]] || return 1
        case "${p}" in
            *[!0-9]*) return 1 ;;
        esac
    done
    return 0
}

# _wb_semver_cmp <a> <b>
# Prints -1, 0, or 1 (a<b, a==b, a>b) to stdout. Handles a leading 'v' on
# either side and differing segment counts (missing trailing segments treat
# as 0) — so "1" compares equal to "1.0" and "1.0.0", which is what lets this
# same primitive serve both the 3-segment tag comparator and the 2-segment
# core_api range check.
_wb_semver_cmp() {
    local a="${1#v}" b="${2#v}"
    local -a A B
    IFS='.' read -r -a A <<< "${a}"
    IFS='.' read -r -a B <<< "${b}"
    local n="${#A[@]}"
    [[ "${#B[@]}" -gt "${n}" ]] && n="${#B[@]}"
    local i=0 ai bi
    while [[ "${i}" -lt "${n}" ]]; do
        ai="${A[${i}]:-0}"
        bi="${B[${i}]:-0}"
        # Strip any non-digit noise defensively; both call sites only ever
        # pass segments already validated as numeric, but a bad input here
        # should compare as 0 rather than blow up the arithmetic below.
        case "${ai}" in *[!0-9]*) ai=0 ;; esac
        case "${bi}" in *[!0-9]*) bi=0 ;; esac
        ai=$((10#${ai:-0}))
        bi=$((10#${bi:-0}))
        if [[ "${ai}" -lt "${bi}" ]]; then
            echo -1
            return 0
        elif [[ "${ai}" -gt "${bi}" ]]; then
            echo 1
            return 0
        fi
        i=$((i + 1))
    done
    echo 0
}

# _wb_semver_highest
# Reads candidate tags one per line from stdin, filters to clean vX.Y.Z tags
# only (_wb_semver_is_clean_tag), and prints the highest. Prints nothing
# (empty output, exit 0) if no candidate tag was clean.
_wb_semver_highest() {
    local tag best=""
    while IFS= read -r tag; do
        [[ -z "${tag}" ]] && continue
        _wb_semver_is_clean_tag "${tag}" || continue
        if [[ -z "${best}" ]]; then
            best="${tag}"
        else
            local cmp
            cmp="$(_wb_semver_cmp "${tag}" "${best}")"
            [[ "${cmp}" == "1" ]] && best="${tag}"
        fi
    done
    printf '%s\n' "${best}"
}

# _wb_version_satisfies <version> <range>
# <range> is a space-separated list of clauses, each "<op><number>" with op
# one of >= <= > < = ==, e.g. ">=1.0 <2.0". Every clause must hold for the
# range to be satisfied (AND semantics — sufficient for the core_api use
# case; no OR/union ranges are needed anywhere in this contract).
_wb_version_satisfies() {
    local version="$1" range="$2"
    local clause op num cmp
    for clause in ${range}; do
        case "${clause}" in
            '>='*) op='>='; num="${clause#>=}" ;;
            '<='*) op='<='; num="${clause#<=}" ;;
            '>'*)  op='>';  num="${clause#>}"  ;;
            '<'*)  op='<';  num="${clause#<}"  ;;
            '=='*) op='=='; num="${clause#==}" ;;
            '='*)  op='='; num="${clause#=}"   ;;
            *)
                log_warn "_wb_version_satisfies: unrecognised clause '${clause}' in range '${range}'"
                return 1
                ;;
        esac
        cmp="$(_wb_semver_cmp "${version}" "${num}")"
        case "${op}" in
            '>=') [[ "${cmp}" == "0" || "${cmp}" == "1" ]]  || return 1 ;;
            '<=') [[ "${cmp}" == "0" || "${cmp}" == "-1" ]] || return 1 ;;
            '>')  [[ "${cmp}" == "1" ]]  || return 1 ;;
            '<')  [[ "${cmp}" == "-1" ]] || return 1 ;;
            '='|'==') [[ "${cmp}" == "0" ]] || return 1 ;;
        esac
    done
    return 0
}
