#!/usr/bin/env bash
# lib/distribution/snapshot.sh — snapshots/ directory management: naming,
# the atomic `current` symlink swap, and pruning (ARCHITECTURE.md §9.3).
# Generalises the atomic-symlink-swap/pruning *pattern* workbench-precursor's
# self-sync "release mode" (scripts/sync.sh) already established for itself
# — every module, core included, gets the identical mechanism here.

_wb_snapshot_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/sync/state.sh
[[ -f "${_wb_snapshot_lib_dir}/../sync/state.sh" ]] && source "${_wb_snapshot_lib_dir}/../sync/state.sh"

# Default retention: keep this many snapshots per module, pruning the rest.
: "${WORKBENCH_SNAPSHOT_KEEP:=3}"

# _wb_slugify <string>
# Filesystem-safe slug: lowercase (via tr, bash-3.2-safe), anything outside
# [a-z0-9._-] collapsed to '-'. Used to build the <ref-slug> half of
# snapshots/<ref-slug>-<shortsha>/ from an arbitrary TRACK_REF (a branch
# name can contain '/', which a directory component must not).
_wb_slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-'
}

# workbench_snapshot_dirname <ref> <shortsha>
workbench_snapshot_dirname() {
    printf '%s-%s\n' "$(_wb_slugify "$1")" "$2"
}

# workbench_snapshot_path <module> <ref> <shortsha>
workbench_snapshot_path() {
    printf '%s/snapshots/%s\n' "$(workbench_module_dir "$1")" "$(workbench_snapshot_dirname "$2" "$3")"
}

# workbench_snapshot_swap <module> <new_snapshot_dir>
# Flips <module>/current to point at <new_snapshot_dir> — no window where
# `current` resolves to a partially-written directory (the new snapshot is
# always written out fully, under its own final name, before this is ever
# called). Uses `ln -sfn` directly against the final `current` path, the
# same primitive workbench-precursor's own release-mode symlink swap used
# (scripts/sync.sh release_sync()) — deliberately NOT a temp-symlink-then-
# `mv` pattern: `mv src dest` treats an existing symlink-to-directory `dest`
# as a directory to move *into* (POSIX/GNU/BSD mv all do this the same way),
# so it would silently nest the new snapshot inside the old one instead of
# replacing `current` — this is the exact footgun donor code's own comment
# on this warns about. `ln -sfn` (GNU) / `ln -sfh` (BSD/macOS, `-n`/`-h` are
# ln's "don't follow an existing symlink destination" flag on their
# respective platforms) unlinks the old symlink and creates the new one in
# its place — no directory-traversal ambiguity, and no window where the
# path points at a wrong or partial target (it's either the previous
# snapshot or the new one, never a half-written third state).
workbench_snapshot_swap() {
    local module="$1" new_dir="$2"
    local module_dir current_link
    module_dir="$(workbench_module_dir "${module}")"
    current_link="${module_dir}/current"

    [[ -d "${new_dir}" ]] || { log_error "workbench_snapshot_swap: ${new_dir} does not exist"; return 1; }

    mkdir -p "${module_dir}"
    # GNU coreutils ln (Linux) accepts -n for this; BSD ln (macOS) does not
    # recognise -n but accepts -h for the identical behaviour — there is no
    # single flag both accept, so try -n first and fall back to -h rather
    # than branching on WORKBENCH_OS (keeps this working under whatever `ln`
    # is actually on PATH, not just the platform's usual default).
    if ! ln -sfn "${new_dir}" "${current_link}" 2>/dev/null; then
        ln -sfh "${new_dir}" "${current_link}"
    fi
}

# workbench_snapshot_prune <module> [keep_count]
# Removes snapshot directories beyond the retention window, oldest first by
# mtime, never touching whatever `current` points at (even if it would
# otherwise fall outside the retention count — a manually-pinned old
# snapshot some other mechanism still references is never the thing this
# function deletes out from under it).
workbench_snapshot_prune() {
    local module="$1" keep="${2:-${WORKBENCH_SNAPSHOT_KEEP}}"
    local module_dir snapshots_dir current_target
    module_dir="$(workbench_module_dir "${module}")"
    snapshots_dir="${module_dir}/snapshots"
    [[ -d "${snapshots_dir}" ]] || return 0

    # Plain `readlink` (no -f) is sufficient and portable: workbench_snapshot_swap
    # always writes `current` as an absolute-path symlink (workbench_snapshot_path
    # builds from workbench_module_dir, itself absolute), so there's no relative
    # target to resolve. `-f` is a GNU coreutils extension BSD/macOS readlink
    # does not have at all — using it here would silently break pruning's own
    # "never delete what current points at" guarantee on macOS (current_target
    # would come back empty, matching nothing).
    current_target=""
    [[ -L "${module_dir}/current" ]] && current_target="$(readlink "${module_dir}/current" 2>/dev/null || true)"

    local -a all=()
    local d
    while IFS= read -r d; do
        [[ -n "${d}" ]] && all+=("${d}")
    done < <(find "${snapshots_dir}" -mindepth 1 -maxdepth 1 -type d -exec ls -1dt {} + 2>/dev/null)

    local i count=0
    for ((i = 0; i < ${#all[@]}; i++)); do
        count=$((count + 1))
        [[ "${count}" -le "${keep}" ]] && continue
        [[ -n "${current_target}" && "${all[$i]}" == "${current_target}" ]] && continue
        rm -rf "${all[$i]}"
        log_info "workbench_snapshot_prune: removed old snapshot ${all[$i]}"
    done
}
