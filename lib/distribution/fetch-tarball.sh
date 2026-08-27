#!/usr/bin/env bash
# lib/distribution/fetch-tarball.sh — public-repo fetch, no git.
#
# ARCHITECTURE.md §9.1/D5: the default/production path for a public repo,
# any TRACK_MODE. Generalised from workbench-precursor's scripts/sync.sh
# release_sync() (self-sync only, commit-based) to any module, tag-based.
# tests/check-distribution-no-git.sh asserts this file never invokes `git`
# by scrubbing it from PATH and confirming a fetch still succeeds.

# workbench_fetch_tarball_public <owner> <repo> <ref-form> <ref-value> <dest_dir>
# <ref-form> is one of: branch | tag | commit — selects the codeload path
# shape. <dest_dir> must not exist yet; it is created fresh with the
# extracted tree's contents (never the wrapping <repo>-<ref>/ directory
# codeload always produces).
workbench_fetch_tarball_public() {
    local owner="$1" repo="$2" ref_form="$3" ref_value="$4" dest_dir="$5"
    local path

    case "${ref_form}" in
        branch) path="refs/heads/${ref_value}" ;;
        tag)    path="refs/tags/${ref_value}" ;;
        commit) path="${ref_value}" ;;
        *)
            log_error "workbench_fetch_tarball_public: unknown ref-form '${ref_form}'"
            return 1
            ;;
    esac

    if [[ -e "${dest_dir}" ]]; then
        log_error "workbench_fetch_tarball_public: dest_dir already exists: ${dest_dir}"
        return 1
    fi

    local tmp_tar tmp_extract
    tmp_tar="$(mktemp "${TMPDIR:-/tmp}/workbench-fetch.XXXXXX")"
    tmp_extract="$(mktemp -d "${TMPDIR:-/tmp}/workbench-fetch.XXXXXX")"

    if ! curl -fsSL "https://codeload.github.com/${owner}/${repo}/tar.gz/${path}" -o "${tmp_tar}"; then
        log_warn "workbench_fetch_tarball_public: could not fetch tarball for ${owner}/${repo}@${ref_value} — network issue, will retry next cycle"
        rm -f "${tmp_tar}"
        rm -rf "${tmp_extract}"
        return 1
    fi

    if ! tar -xzf "${tmp_tar}" -C "${tmp_extract}"; then
        log_warn "workbench_fetch_tarball_public: tarball extraction failed for ${owner}/${repo}@${ref_value}"
        rm -f "${tmp_tar}"
        rm -rf "${tmp_extract}"
        return 1
    fi
    rm -f "${tmp_tar}"

    local extracted_dir
    extracted_dir="$(find "${tmp_extract}" -mindepth 1 -maxdepth 1 -type d | head -1)"
    if [[ -z "${extracted_dir}" ]]; then
        rm -rf "${tmp_extract}"
        log_warn "workbench_fetch_tarball_public: tarball for ${owner}/${repo}@${ref_value} produced no directory"
        return 1
    fi

    mkdir -p "$(dirname "${dest_dir}")"
    mv "${extracted_dir}" "${dest_dir}"
    rm -rf "${tmp_extract}"
    return 0
}
