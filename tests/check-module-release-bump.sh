#!/usr/bin/env bash
# tests/check-module-release-bump.sh — acceptance check for the module-repo
# release pipeline's bump arithmetic and manual workflow_dispatch floor
# (.github/scripts/module-release/). docs/decisions-log.md D40, D64.
#
# Simplified relative to check-release-bump.sh's fixture: no VERSION file
# (git-tag derived), no per-file registration, a single OVERALL severity.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODULE_RELEASE_DIR="${REPO_ROOT}/.github/scripts/module-release"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

FIXTURE="${WORK}/fixture"
mkdir -p "${FIXTURE}"
printf '# Changelog\n\n## [Unreleased]\n' > "${FIXTURE}/CHANGELOG.md"
echo "docs" > "${FIXTURE}/README-placeholder.md"

(
    cd "${FIXTURE}" || exit 1
    git init -q
    git config user.email "t@t.com"
    git config user.name "Test"
    git add -A
    git commit -q -m "chore: initial fixture"
    git tag -a v1.0.0 -m v1.0.0
)

# 1. Manual floor with nothing pending: forcing 'major' on a docs:-only
#    cycle forces OVERALL to major with a manual-override reason.
(
    cd "${FIXTURE}" || exit 1
    echo "docs update" >> README-placeholder.md
    git add -A
    git commit -q -m "docs: unrelated documentation tweak"
)
PLAN_FORCE_NONE="$(cd "${FIXTURE}" && WB_RELEASE_FORCE_SEVERITY=major "${MODULE_RELEASE_DIR}/compute-bump.sh" 2>/dev/null)"
if grep -q "^OVERALL|1\.0\.0|2\.0\.0|major|manual override (workflow_dispatch): requested at least 'major'\$" <<< "${PLAN_FORCE_NONE}"; then
    ok "manual floor on a none-severity cycle forces OVERALL to major with a manual-override reason"
else
    fail "manual floor on a none-severity cycle produced the wrong OVERALL line: ${PLAN_FORCE_NONE}"
fi

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 2. Manual floor is a floor, not a downgrade: a pending feat: (minor)
#    commit plus a 'patch' manual dispatch still ships minor, with the
#    natural reason, not a manual-override one.
(
    cd "${FIXTURE}" || exit 1
    echo "feat update" >> README-placeholder.md
    git add -A
    git commit -q -m "feat: add a new capability"
)
# shellcheck disable=SC2209
PLAN_NO_DOWNGRADE="$(cd "${FIXTURE}" && WB_RELEASE_FORCE_SEVERITY=patch "${MODULE_RELEASE_DIR}/compute-bump.sh" 2>/dev/null)"
if grep -q '^OVERALL|1\.0\.0|1\.1\.0|minor|highest-severity qualifying commit$' <<< "${PLAN_NO_DOWNGRADE}"; then
    ok "manual 'patch' floor does not downgrade a pending minor change; reason stays natural"
else
    fail "manual floor incorrectly changed severity or reason: ${PLAN_NO_DOWNGRADE}"
fi

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 3. Invalid WB_RELEASE_FORCE_SEVERITY value: fails loudly.
(
    cd "${FIXTURE}" || exit 1
    echo "docs update" >> README-placeholder.md
    git add -A
    git commit -q -m "docs: another unrelated tweak"
)
if (cd "${FIXTURE}" && WB_RELEASE_FORCE_SEVERITY=banana "${MODULE_RELEASE_DIR}/compute-bump.sh" >/dev/null 2>"${WORK}/invalid.log"); then
    fail "compute-bump.sh did not fail on an invalid WB_RELEASE_FORCE_SEVERITY value"
else
    ok "compute-bump.sh fails loudly on an invalid WB_RELEASE_FORCE_SEVERITY value"
fi
if grep -qi "invalid WB_RELEASE_FORCE_SEVERITY" "${WORK}/invalid.log"; then
    ok "invalid WB_RELEASE_FORCE_SEVERITY value logs a clear error"
else
    fail "no clear error logged for an invalid WB_RELEASE_FORCE_SEVERITY value"
fi

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 4. CHANGELOG gate still blocks apply-bump.sh on an empty [Unreleased],
#    even for a manually-forced release.
(
    cd "${FIXTURE}" || exit 1
    printf '# Changelog\n\n## [Unreleased]\n' > CHANGELOG.md
    echo "docs update" >> README-placeholder.md
    git add -A
    git commit -q -m "docs: yet another unrelated tweak"
)
# shellcheck disable=SC2209
PLAN_GATE="$(cd "${FIXTURE}" && WB_RELEASE_FORCE_SEVERITY=patch "${MODULE_RELEASE_DIR}/compute-bump.sh" 2>/dev/null)"
if (cd "${FIXTURE}" && "${MODULE_RELEASE_DIR}/apply-bump.sh" "${PLAN_GATE}" 2>"${WORK}/manual-gate.log"); then
    fail "apply-bump.sh did not fail with an empty [Unreleased] section on a manually-forced release"
else
    ok "CHANGELOG gate still blocks a manually-forced release with an empty [Unreleased] section"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
