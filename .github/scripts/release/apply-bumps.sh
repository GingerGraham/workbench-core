#!/usr/bin/env bash
# .github/scripts/release/apply-bumps.sh <bump-plan-file>
#
# Consumes a bump plan produced by compute-bumps.sh: rewrites each listed
# file's script-local version line, bumps VERSION, and renames/inserts the
# CHANGELOG.md [Unreleased] heading (§3.5/§3.6). Gated on a non-empty
# CHANGELOG [Unreleased] section — fails loudly, before touching anything,
# if overall severity is not "none" and that section is empty.
#
# A no-op (exit 0, nothing written) when the plan's OVERALL severity is
# "none" — so this is always safe to call, even if the caller's own gate
# didn't already skip it. ARCHITECTURE.md §12 D27.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/release/lib.sh
source "${SCRIPT_DIR}/lib.sh"

PLAN_FILE="${1:?usage: apply-bumps.sh <bump-plan-file>}"
[[ -f "${PLAN_FILE}" ]] || { echo "apply-bumps: no such file: ${PLAN_FILE}" >&2; exit 1; }

OVERALL_LINE="$(grep -m 1 '^OVERALL|' "${PLAN_FILE}")"
if [[ -z "${OVERALL_LINE}" ]]; then
    echo "apply-bumps: no OVERALL| line found in ${PLAN_FILE} — not a valid bump plan." >&2
    exit 1
fi
IFS='|' read -r _ OVERALL_OLD OVERALL_NEW OVERALL_SEV OVERALL_REASON <<< "${OVERALL_LINE}"

if [[ "${OVERALL_SEV}" == "none" ]]; then
    echo "apply-bumps: OVERALL severity is none — nothing to apply." >&2
    exit 0
fi

CHANGELOG="${REPO_ROOT}/CHANGELOG.md"
if ! _rel_changelog_has_entries "${CHANGELOG}"; then
    echo "apply-bumps: refusing to release ${OVERALL_NEW} — CHANGELOG.md's [Unreleased] section is empty. Add an entry before this can ship." >&2
    exit 1
fi

while IFS='|' read -r path old new severity; do
    [[ -z "${path}" || "${path}" == "OVERALL" ]] && continue
    echo "apply-bumps: ${path} ${old} -> ${new} (${severity})" >&2
    if ! _rel_set_version "${path}" "${new}"; then
        echo "apply-bumps: aborting — failed to rewrite ${path}, VERSION/CHANGELOG.md left untouched." >&2
        exit 1
    fi
done < "${PLAN_FILE}"

echo "apply-bumps: VERSION ${OVERALL_OLD} -> ${OVERALL_NEW} (${OVERALL_SEV}, ${OVERALL_REASON})" >&2
printf '%s\n' "${OVERALL_NEW}" > "${REPO_ROOT}/VERSION"

TODAY="$(date -u +%Y-%m-%d)"
_rel_changelog_release "${CHANGELOG}" "${OVERALL_NEW}" "${TODAY}"
echo "apply-bumps: CHANGELOG.md [Unreleased] -> [${OVERALL_NEW}] - ${TODAY}, fresh [Unreleased] inserted" >&2
