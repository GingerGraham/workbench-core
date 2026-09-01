#!/usr/bin/env bash
# lib/distribution/resolve.sh — ref -> commit resolution.
#
# ARCHITECTURE.md §9.1/D5: public repos resolve via GitHub's unauthenticated
# API (no git anywhere in this path); private repos and any branch:-tracked
# repo (public or private) resolve via `git ls-remote` — cheap, read-only,
# does not require the full shallow-clone-and-discard fetch just to answer
# "what commit does this ref point at right now".
#
# No jq/python3/yq dependency: GitHub's JSON responses are parsed with
# grep/sed, the same technique workbench-precursor's install.sh already used
# for _resolve_branch_sha() — relies on GitHub's stable, documented key
# ordering (a tag object's "name" key always precedes its "commit"."sha"),
# not on any general JSON-parsing guarantee.

_wb_resolve_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/distribution/resolve.sh" "0.1.0" || true

# workbench_parse_github_url <url>
# Prints "<owner> <repo>" for an https or ssh GitHub remote URL. Empty
# output (exit 1) if the URL doesn't look like a GitHub remote.
workbench_parse_github_url() {
    local url="$1" rest owner repo
    case "${url}" in
        https://github.com/*) rest="${url#https://github.com/}" ;;
        git@github.com:*)     rest="${url#git@github.com:}" ;;
        ssh://git@github.com/*) rest="${url#ssh://git@github.com/}" ;;
        *) return 1 ;;
    esac
    rest="${rest%.git}"
    owner="${rest%%/*}"
    repo="${rest#*/}"
    [[ -z "${owner}" || -z "${repo}" || "${owner}" == "${repo}" && "${rest}" != */* ]] && return 1
    printf '%s %s\n' "${owner}" "${repo}"
}

# _wb_gh_curl <url>
# GitHub's API requires a User-Agent header on every request (a request
# without one is rejected outright, independent of rate limiting). Prints
# the response body on stdout; returns non-zero on any failure (network,
# 4xx/5xx, rate limit) without ever calling exit — callers treat resolution
# failure as "skip this cycle, retry later" (ARCHITECTURE.md §9.4's
# rate-limit note), never fatal.
_wb_gh_curl() {
    curl -fsSL -H "Accept: application/vnd.github+json" -A "workbench-core" "$1" 2>/dev/null
}

# _wb_gh_tags_json <owner> <repo>
# Raw JSON body of the tags list (single page, up to 100 — see the
# per-page note in contracts/tracking-spec.md; sufficient for personal-scale
# repos, and consistent with ARCHITECTURE.md §9.4's documented decision not
# to pre-engineer around GitHub's rate limit further than needed).
_wb_gh_tags_json() {
    local owner="$1" repo="$2"
    _wb_gh_curl "https://api.github.com/repos/${owner}/${repo}/tags?per_page=100"
}

# _wb_gh_tags_name_sha_pairs <owner> <repo>
# Emits "<tag-name>|<sha>" one per line, in the API's own (undocumented but
# stable) ordering. Relies on "name" preceding "commit":{"sha":...} within
# each array element, which is GitHub's documented response shape.
_wb_gh_tags_name_sha_pairs() {
    local owner="$1" repo="$2" json
    json="$(_wb_gh_tags_json "${owner}" "${repo}")" || return 1
    [[ -z "${json}" ]] && return 1
    printf '%s' "${json}" \
        | grep -oE '"(name|sha)"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed -E 's/^"(name|sha)"[[:space:]]*:[[:space:]]*"([^"]*)"$/\2/' \
        | awk 'NR % 2 == 1 { name = $0; next } { print name "|" $0 }'
}

# workbench_resolve_latest_tag_public <owner> <repo>
# Prints "<tag>|<sha>" for the highest clean vX.Y.Z tag, or nothing (exit 1)
# if the repo has no clean tags or the API call failed.
workbench_resolve_latest_tag_public() {
    local owner="$1" repo="$2" pairs best_tag="" best_sha=""
    pairs="$(_wb_gh_tags_name_sha_pairs "${owner}" "${repo}")" || return 1
    [[ -z "${pairs}" ]] && return 1

    local line tag sha cmp
    while IFS='|' read -r tag sha; do
        [[ -z "${tag}" ]] && continue
        _wb_semver_is_clean_tag "${tag}" || continue
        if [[ -z "${best_tag}" ]]; then
            best_tag="${tag}"; best_sha="${sha}"
        else
            cmp="$(_wb_semver_cmp "${tag}" "${best_tag}")"
            [[ "${cmp}" == "1" ]] && { best_tag="${tag}"; best_sha="${sha}"; }
        fi
    done <<< "${pairs}"

    [[ -z "${best_tag}" ]] && return 1
    printf '%s|%s\n' "${best_tag}" "${best_sha}"
}

# workbench_resolve_tag_public <owner> <repo> <tag>
# Prints the commit sha for an exact tag name (clean or pre-release — both
# are valid explicit pins). Exit 1 if not found.
workbench_resolve_tag_public() {
    local owner="$1" repo="$2" want="$3" pairs tag sha
    pairs="$(_wb_gh_tags_name_sha_pairs "${owner}" "${repo}")" || return 1
    while IFS='|' read -r tag sha; do
        [[ "${tag}" == "${want}" ]] && { printf '%s\n' "${sha}"; return 0; }
    done <<< "${pairs}"
    return 1
}

# workbench_resolve_branch_public <owner> <repo> <branch>
# Prints the branch tip's full sha. Ported from install.sh's
# _resolve_branch_sha(), unchanged.
workbench_resolve_branch_public() {
    local owner="$1" repo="$2" branch="$3"
    _wb_gh_curl "https://api.github.com/repos/${owner}/${repo}/commits/${branch}" \
        | grep -o '"sha":[^,]*' \
        | head -1 \
        | grep -oE '[0-9a-f]{40}'
}

# workbench_resolve_commit_public <owner> <repo> <sha>
# Verifies (does not "resolve" — the ref already is a commit) that <sha>
# exists upstream. Prints <sha> back on success. This is the defensive,
# not-normally-expected check ARCHITECTURE.md §9.2 describes for
# commit:<sha> pins.
workbench_resolve_commit_public() {
    local owner="$1" repo="$2" sha="$3" body
    body="$(_wb_gh_curl "https://api.github.com/repos/${owner}/${repo}/commits/${sha}")" || return 1
    printf '%s' "${body}" | grep -q "\"sha\": *\"${sha}" || \
    printf '%s' "${body}" | grep -q "\"sha\":\"${sha}" || return 1
    printf '%s\n' "${sha}"
}

# ── Private / dev (git ls-remote) resolution ─────────────────────────────────
# Cheap, read-only — no clone. Used for any private repo (all track modes)
# and any branch:-tracked repo, public or private (ARCHITECTURE.md §9.1).

# workbench_resolve_branch_ls_remote <git_url> <branch>
workbench_resolve_branch_ls_remote() {
    local url="$1" branch="$2"
    git ls-remote "${url}" "refs/heads/${branch}" 2>/dev/null | awk '{print $1}' | head -1
}

# workbench_resolve_tag_ls_remote <git_url> <tag>
# Prefers the peeled (^{}) sha for an annotated tag — that's the commit the
# tag actually points at, not the tag object's own sha.
workbench_resolve_tag_ls_remote() {
    local url="$1" tag="$2" out peeled lightweight
    out="$(git ls-remote "${url}" "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null)"
    [[ -z "${out}" ]] && return 1
    peeled="$(printf '%s\n' "${out}" | awk -v t="refs/tags/${tag}^{}" '$2 == t {print $1}')"
    if [[ -n "${peeled}" ]]; then
        printf '%s\n' "${peeled}"
        return 0
    fi
    lightweight="$(printf '%s\n' "${out}" | awk -v t="refs/tags/${tag}" '$2 == t {print $1}')"
    [[ -n "${lightweight}" ]] && printf '%s\n' "${lightweight}"
}

# workbench_resolve_latest_tag_ls_remote <git_url>
# Same "highest clean vX.Y.Z tag" resolution as the public path, but reading
# the full tag ref list via `git ls-remote --tags` instead of the GitHub
# API — works for any git host, not just GitHub, which matters here because
# private independent tools are not required to be on GitHub specifically
# even though the tarball-only public path is (ARCHITECTURE.md §9.1 ties
# the no-git path to GitHub's codeload specifically; the private path has no
# such constraint).
workbench_resolve_latest_tag_ls_remote() {
    local url="$1" out best_tag="" best_sha="" sha ref tag cmp
    out="$(git ls-remote --tags "${url}" 2>/dev/null)" || return 1
    [[ -z "${out}" ]] && return 1

    # Prefer a peeled (^{}) entry over its lightweight counterpart when both
    # are present for the same tag — same reasoning as
    # workbench_resolve_tag_ls_remote.
    local -a lines=()
    while IFS= read -r line; do lines+=("${line}"); done <<< "${out}"

    local i
    for ((i = 0; i < ${#lines[@]}; i++)); do
        sha="$(awk '{print $1}' <<< "${lines[$i]}")"
        ref="$(awk '{print $2}' <<< "${lines[$i]}")"
        case "${ref}" in
            */\^\{\}) continue ;; # handled via the lookahead below
        esac
        tag="${ref#refs/tags/}"
        _wb_semver_is_clean_tag "${tag}" || continue

        # If the very next line peels this same tag, prefer its sha.
        if [[ $((i + 1)) -lt ${#lines[@]} ]]; then
            local next_ref next_sha
            next_ref="$(awk '{print $2}' <<< "${lines[$((i + 1))]}")"
            if [[ "${next_ref}" == "refs/tags/${tag}^{}" ]]; then
                next_sha="$(awk '{print $1}' <<< "${lines[$((i + 1))]}")"
                sha="${next_sha}"
            fi
        fi

        if [[ -z "${best_tag}" ]]; then
            best_tag="${tag}"; best_sha="${sha}"
        else
            cmp="$(_wb_semver_cmp "${tag}" "${best_tag}")"
            [[ "${cmp}" == "1" ]] && { best_tag="${tag}"; best_sha="${sha}"; }
        fi
    done

    [[ -z "${best_tag}" ]] && return 1
    printf '%s|%s\n' "${best_tag}" "${best_sha}"
}
