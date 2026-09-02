#!/usr/bin/env bash
# .github/scripts/release/compute-bumps.sh — walks the commit range
# (<previous release tag>, HEAD] and emits a machine-readable bump plan to
# stdout: one `<path>|<old>|<new>|<severity>` line per registered file that
# changed severity this cycle, plus a final
# `OVERALL|<old>|<new>|<severity>|<reason>` line. ARCHITECTURE.md §12 D27.
#
# Exits 0 in every case, including "nothing to release" (OVERALL severity
# none) — the caller (release.yml) decides whether to proceed by reading
# the OVERALL line, not by this script's exit code.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/release/lib.sh
source "${SCRIPT_DIR}/lib.sh"

cd "${REPO_ROOT}" || exit 1

PREV_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD^ 2>/dev/null || true)"
if [[ -z "${PREV_TAG}" ]]; then
    echo "compute-bumps: no previous vX.Y.Z tag found reachable from HEAD^ — nothing to diff against. Has v1.0.0 been cut yet (§7)?" >&2
    exit 1
fi

echo "compute-bumps: diffing (${PREV_TAG}, HEAD] against registered files" >&2

declare -A FILE_SEV
CORE_SEV="none"

while IFS= read -r sha; do
    [[ -z "${sha}" ]] && continue
    message="$(git log -1 --format=%B "${sha}")"
    header="$(head -1 <<< "${message}")"
    severity="$(_rel_commit_severity "${message}")"

    files_touched="$(git diff-tree --no-commit-id --name-only -r "${sha}")"

    if [[ "${severity}" == "unparseable" ]]; then
        touches_registered="false"
        while IFS= read -r f; do
            [[ -z "${f}" ]] && continue
            _rel_is_registered "${f}" && touches_registered="true"
        done <<< "${files_touched}"
        if [[ "${touches_registered}" == "true" ]]; then
            echo "WARNING: commit ${sha} ('${header}') touches a registered file but its message type doesn't parse — not contributing to any bump. pr-check.yml should have caught this at PR time." >&2
        fi
        continue
    fi

    [[ "${severity}" == "none" ]] && continue

    scope="$(_rel_commit_scope "${header}")"

    if [[ "${scope}" == "core" ]]; then
        CORE_SEV="$(_rel_max_sev "${CORE_SEV}" "${severity}")"
    elif [[ -n "${scope}" ]]; then
        if _rel_is_registered "${scope}"; then
            FILE_SEV["${scope}"]="$(_rel_max_sev "${FILE_SEV["${scope}"]:-none}" "${severity}")"
        else
            echo "WARNING: commit ${sha} ('${header}') names scope '${scope}', which is not a registered file or 'core' — ignored." >&2
        fi
    else
        while IFS= read -r f; do
            [[ -z "${f}" ]] && continue
            _rel_is_registered "${f}" || continue
            FILE_SEV["${f}"]="$(_rel_max_sev "${FILE_SEV["${f}"]:-none}" "${severity}")"
        done <<< "${files_touched}"
    fi
done < <(git log --format=%H "${PREV_TAG}..HEAD")

ROLLUP_SEV="none"
BUMP_PLAN=()
for path in "${!FILE_SEV[@]}"; do
    sev="${FILE_SEV[${path}]}"
    [[ "${sev}" == "none" ]] && continue
    ROLLUP_SEV="$(_rel_max_sev "${ROLLUP_SEV}" "${sev}")"
    old="$(_rel_current_version "${path}")"
    new="$(_rel_bump_semver "${old}" "${sev}")"
    BUMP_PLAN+=("${path}|${old}|${new}|${sev}")
done

OVERALL_SEV="$(_rel_max_sev "${ROLLUP_SEV}" "${CORE_SEV}")"

REASON="none"
if [[ "${OVERALL_SEV}" != "none" ]]; then
    rollup_is_max="false"; core_is_max="false"
    [[ "${ROLLUP_SEV}" == "${OVERALL_SEV}" ]] && rollup_is_max="true"
    [[ "${CORE_SEV}" == "${OVERALL_SEV}" ]] && core_is_max="true"
    if [[ "${rollup_is_max}" == "true" && "${core_is_max}" == "true" ]]; then
        REASON="component rollup and core-scoped commit (tied)"
    elif [[ "${core_is_max}" == "true" ]]; then
        REASON="core-scoped commit"
    else
        REASON="component rollup"
    fi
fi

for line in "${BUMP_PLAN[@]+"${BUMP_PLAN[@]}"}"; do
    echo "${line}"
done

OLD_VERSION="$(head -n 1 "${REPO_ROOT}/VERSION")"
if [[ "${OVERALL_SEV}" == "none" ]]; then
    echo "OVERALL|${OLD_VERSION}|${OLD_VERSION}|none|no registered-file or core-scoped bump this cycle"
else
    NEW_VERSION="$(_rel_bump_semver "${OLD_VERSION}" "${OVERALL_SEV}")"
    echo "OVERALL|${OLD_VERSION}|${NEW_VERSION}|${OVERALL_SEV}|${REASON}"
fi
