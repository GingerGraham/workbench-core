#!/usr/bin/env bash
# lib/distribution/fetch-git-snapshot.sh — shallow-clone-and-discard.
#
# ARCHITECTURE.md §9.1/D5: used for (a) any private repo, every TRACK_MODE,
# via the SSH deploy key from Phase 6, and (b) any branch:-tracked repo,
# public or private, re-run fresh on every sync cycle. Either way the
# result is the same as the tarball path: an immutable, atomic snapshot —
# `git` is transport only, never a persisted incrementally-pulled working
# tree, and `.git` is discarded before the tree ever reaches snapshots/.
#
# Form used (ARCHITECTURE.md §12 D12): `git init` + `git remote add` +
# `git fetch --depth 1 origin <ref>` + `git checkout FETCH_HEAD`, rather than
# `git clone --depth 1 --branch <ref>` directly — this form works uniformly
# whether <ref> is a branch name, a tag, or a full commit sha. A depth-1
# clone/fetch *by branch or tag name* works the same either way; a depth-1
# fetch *by raw commit sha* additionally requires the remote to have
# uploadpack.allowReachableSHA1InWant enabled, which is not guaranteed for
# an arbitrary private remote — so commit:<sha> pins fall back to a
# best-effort deeper fetch (below) rather than assuming shallow-by-sha works
# everywhere.

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/distribution/fetch-git-snapshot.sh" "0.1.0" || true

# workbench_fetch_git_snapshot <git_url> <ref-form> <ref-value> <dest_dir>
# <ref-form> is one of: branch | tag | commit.
workbench_fetch_git_snapshot() {
    local url="$1" ref_form="$2" ref_value="$3" dest_dir="$4"

    if [[ -e "${dest_dir}" ]]; then
        log_error "workbench_fetch_git_snapshot: dest_dir already exists: ${dest_dir}"
        return 1
    fi
    if ! command -v git &>/dev/null; then
        log_error "workbench_fetch_git_snapshot: git is required for private-repo/dev-mode fetches"
        return 1
    fi

    local scratch
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/workbench-fetch.XXXXXX")"

    (
        cd "${scratch}" || exit 1
        git init -q .
        git remote add origin "${url}"

        case "${ref_form}" in
            branch) git fetch -q --depth 1 origin "refs/heads/${ref_value}" ;;
            tag)    git fetch -q --depth 1 origin "refs/tags/${ref_value}" ;;
            commit)
                # A shallow fetch by raw sha only works if the server opted
                # in to allowReachableSHA1InWant. Try it first (cheap, fast
                # when it works); fall back to a full fetch + checkout,
                # which always works but transfers more history.
                if ! git fetch -q --depth 1 origin "${ref_value}" 2>/dev/null; then
                    git fetch -q origin || exit 1
                fi
                ;;
            *) exit 1 ;;
        esac
    ) || {
        log_warn "workbench_fetch_git_snapshot: fetch failed for ${url}@${ref_value} — will retry next cycle"
        rm -rf "${scratch}"
        return 1
    }

    (
        cd "${scratch}" || exit 1
        case "${ref_form}" in
            commit) git checkout -q "${ref_value}" ;;
            *)      git checkout -q FETCH_HEAD ;;
        esac
    ) || {
        log_warn "workbench_fetch_git_snapshot: checkout of ${ref_value} failed for ${url}"
        rm -rf "${scratch}"
        return 1
    }

    rm -rf "${scratch}/.git"
    mkdir -p "$(dirname "${dest_dir}")"
    mv "${scratch}" "${dest_dir}"
    return 0
}
