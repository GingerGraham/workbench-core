#!/usr/bin/env bash
# tests/check-snapshot-atomicity.sh — Phase 5c acceptance check for
# lib/distribution/snapshot.sh: the symlink swap never exposes a partially-
# written directory, and pruning retains exactly the configured count
# without ever touching whatever `current` points at.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"

# shellcheck source=lib/core/log.sh
source "${REPO_ROOT}/lib/core/log.sh"
# shellcheck source=lib/sync/state.sh
source "${REPO_ROOT}/lib/sync/state.sh"
# shellcheck source=lib/distribution/snapshot.sh
source "${REPO_ROOT}/lib/distribution/snapshot.sh"

MOD="acme-widget"

# 1. Five sequential swaps each land correctly (no stale/no partial target).
declare -a expect_dirs=()
for i in 1 2 3 4 5; do
    d="$(workbench_snapshot_path "${MOD}" "latest" "sha${i}")"
    mkdir -p "${d}"
    echo "content ${i}" > "${d}/f.txt"
    workbench_snapshot_swap "${MOD}" "${d}"
    expect_dirs+=("${d}")
    got="$(readlink "$(workbench_module_dir "${MOD}")/current")"
    if [[ "${got}" == "${d}" ]]; then
        ok "swap ${i}: current correctly points at the just-written snapshot"
    else
        fail "swap ${i}: current points at '${got}', expected '${d}'"
    fi
done

# 2. current always resolves to a directory containing the expected file —
#    never briefly empty/missing across N sequential swaps (this is as
#    close to "no partial-target window" as a single-threaded check can
#    demonstrate: every single swap's post-condition is verified, not just
#    the final one).
content="$(cat "$(workbench_module_dir "${MOD}")/current/f.txt" 2>/dev/null || true)"
if [[ "${content}" == "content 5" ]]; then
    ok "current resolves to fully-written content after the final swap"
else
    fail "current did not resolve to expected content: '${content}'"
fi

# 3. Pruning keeps exactly N, and never removes whatever `current` points at.
workbench_snapshot_prune "${MOD}" 3
remaining_count=$(find "$(workbench_module_dir "${MOD}")/snapshots" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
if [[ "${remaining_count}" -eq 3 ]]; then
    ok "pruning retained exactly 3 snapshots (the configured count)"
else
    fail "pruning retained ${remaining_count} snapshots, expected 3"
fi

current_after_prune="$(readlink "$(workbench_module_dir "${MOD}")/current")"
if [[ -d "${current_after_prune}" ]]; then
    ok "current's target still exists after pruning"
else
    fail "pruning deleted the directory current points at"
fi
if [[ "${current_after_prune}" == "${expect_dirs[4]}" ]]; then
    ok "current is unchanged by pruning (still the most recent snapshot)"
else
    fail "current changed after pruning: ${current_after_prune}"
fi

# 4. A module with fewer snapshots than the keep count is a no-op.
MOD2="tiny-widget"
d="$(workbench_snapshot_path "${MOD2}" "latest" "shaonly")"
mkdir -p "${d}"
workbench_snapshot_swap "${MOD2}" "${d}"
workbench_snapshot_prune "${MOD2}" 3
remaining2=$(find "$(workbench_module_dir "${MOD2}")/snapshots" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
if [[ "${remaining2}" -eq 1 ]]; then
    ok "pruning is a no-op when snapshot count is already below the keep threshold"
else
    fail "pruning incorrectly removed snapshots when below the keep threshold"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
