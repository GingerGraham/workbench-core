#!/usr/bin/env bash
# tests/check-module-ci-release-trigger.sh — acceptance check for
# .github/scripts/release/detect-module-ci-changes.sh (security review
# follow-up R3, docs/decisions-log.md D80, D95, security status N10): changes
# to .github/actions/**, .github/workflows/module-*.yml,
# .github/scripts/module-ci/**, .github/scripts/module-release/** or
# .github/scripts/module-pr-check/** since the last tag must ask for a patch
# release; nothing else may.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DETECT="${REPO_ROOT}/.github/scripts/release/detect-module-ci-changes.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}" || exit 1
git init -q
git config user.email t@t.com
git config user.name Test
mkdir -p .github/actions/scan .github/workflows bin
echo a > README.md
git add -A && git commit -q -m init

run_detect() { REPO_ROOT="${WORK}" bash "${DETECT}" 2>/dev/null; }
commit_file() { mkdir -p "$(dirname "$1")"; echo "$RANDOM" >> "$1"; git add -A; git commit -q -m "change $1"; }

# 1. No tag yet: nothing to diff against.
out="$(run_detect)"
if [[ "${out}" == "force_severity=" ]]; then ok "no baseline tag: no forced release"; else fail "no tag: got [${out}]"; fi

git tag v1.0.0

# 2. Nothing since the tag.
out="$(run_detect)"
if [[ "${out}" == "force_severity=" ]]; then ok "no changes since the tag: no forced release"; else fail "no changes: got [${out}]"; fi

# 3. Unrelated files (docs, a caller workflow, a bin script).
commit_file README.md
commit_file .github/workflows/ci.yml
commit_file bin/tool
out="$(run_detect)"
if [[ "${out}" == "force_severity=" ]]; then ok "unrelated files (README, ci.yml, bin/) do not force a release"; else fail "unrelated: got [${out}]"; fi

# 4. A composite action changed.
commit_file .github/actions/scan/action.yml
out="$(run_detect)"
if grep -qx 'force_severity=patch' <<< "${out}" && grep -q '^reason=' <<< "${out}"; then
    ok ".github/actions/** change forces a patch release, with a reason"
else
    fail "actions change: got [${out}]"
fi

# 5. Only a module-*.yml reusable workflow changed (fresh tag first).
git tag v1.0.1
out="$(run_detect)"
if [[ "${out}" == "force_severity=" ]]; then ok "after a new tag the previous change no longer counts"; else fail "post-tag: got [${out}]"; fi
commit_file .github/workflows/module-ci.yml
out="$(run_detect)"
if grep -qx 'force_severity=patch' <<< "${out}"; then ok ".github/workflows/module-*.yml change forces a patch release"; else fail "module-ci.yml: got [${out}]"; fi

# 7-8. Only a module-CI script changed (D95), and a sibling release script
#      (not consumed by module CI) still doesn't count.
git tag v1.0.2
commit_file .github/scripts/release/compute-bumps.sh
out="$(run_detect)"
if [[ "${out}" == "force_severity=" ]]; then ok ".github/scripts/release/ change does not force a release"; else fail "release script: got [${out}]"; fi
commit_file .github/scripts/module-ci/check-clean-shell.sh
out="$(run_detect)"
if grep -qx 'force_severity=patch' <<< "${out}"; then ok ".github/scripts/module-ci/** change forces a patch release (D95)"; else fail "module-ci script: got [${out}]"; fi

# 9-10. The scripts module-release.yml and module-pr-check.yml run from the
#       core checkout count too (security status N10), each on its own.
git tag v1.0.3
commit_file .github/scripts/module-release/compute-bump.sh
out="$(run_detect)"
if grep -qx 'force_severity=patch' <<< "${out}"; then ok ".github/scripts/module-release/** change forces a patch release (N10)"; else fail "module-release script: got [${out}]"; fi
git tag v1.0.4
commit_file .github/scripts/module-pr-check/check-pr-title-format.sh
out="$(run_detect)"
if grep -qx 'force_severity=patch' <<< "${out}"; then ok ".github/scripts/module-pr-check/** change forces a patch release (N10)"; else fail "module-pr-check script: got [${out}]"; fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
