#!/usr/bin/env bash
# tests/check-semver-comparator.sh — Phase 5b acceptance check for
# lib/core/semver.sh: tag filtering + comparison correctness, per
# ARCHITECTURE.md §9.2's exact example set.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/core/log.sh
source "${REPO_ROOT}/lib/core/log.sh"
# shellcheck source=lib/core/semver.sh
source "${REPO_ROOT}/lib/core/semver.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

# ── Clean-tag filtering ──────────────────────────────────────────────────────
declare -A expect=(
    [v1.2.3]=clean
    [v1.10.0]=clean
    [v0.0.1]=clean
    [1.2.3]=not
    [v1.2]=not
    [v1.2.3.4]=not
    [v1.2.3-rc1]=not
    [v1.2.3+build5]=not
    [vX.Y.Z]=not
    [release]=not
)
for tag in "${!expect[@]}"; do
    if [[ "${expect[${tag}]}" == "clean" ]]; then
        if _wb_semver_is_clean_tag "${tag}"; then
            ok "'${tag}' correctly recognised as a clean vX.Y.Z tag"
        else
            fail "'${tag}' should be a clean tag but was rejected"
        fi
    else
        if _wb_semver_is_clean_tag "${tag}"; then
            fail "'${tag}' should NOT be a clean tag but was accepted"
        else
            ok "'${tag}' correctly excluded from clean-tag filtering"
        fi
    fi
done

# ── Comparison correctness (naive string sort would get this wrong) ────────
if [[ "$(_wb_semver_cmp v1.9.0 v1.10.0)" == "-1" ]]; then
    ok "v1.9.0 < v1.10.0 (numeric compare, not lexicographic — '1' < '10' fails as strings)"
else
    fail "v1.9.0 vs v1.10.0 comparison wrong: $(_wb_semver_cmp v1.9.0 v1.10.0)"
fi
if [[ "$(_wb_semver_cmp v1.10.0 v2.0.0)" == "-1" ]]; then
    ok "v1.10.0 < v2.0.0"
else
    fail "v1.10.0 vs v2.0.0 comparison wrong"
fi
if [[ "$(_wb_semver_cmp v1.10.0 v1.10.0)" == "0" ]]; then
    ok "v1.10.0 == v1.10.0"
else
    fail "v1.10.0 vs v1.10.0 comparison wrong"
fi

# ── latest resolution across the exact mixed set from ARCHITECTURE.md §9.2 ──
# v1.10.0 should win (not v1.9.0 via naive string sort), and the rc tag must
# be excluded from the latest pool entirely.
result="$(printf 'v1.9.0\nv1.10.0\nv2.0.0\nv1.10.0-rc1\n' | _wb_semver_highest)"
if [[ "${result}" == "v2.0.0" ]]; then
    ok "highest of {v1.9.0, v1.10.0, v2.0.0, v1.10.0-rc1} is v2.0.0"
else
    fail "expected v2.0.0, got '${result}'"
fi

result2="$(printf 'v1.9.0\nv1.10.0\nv1.10.0-rc1\n' | _wb_semver_highest)"
if [[ "${result2}" == "v1.10.0" ]]; then
    ok "with v2.0.0 removed, highest of {v1.9.0, v1.10.0, v1.10.0-rc1} is v1.10.0 (rc1 excluded, not a naive-sort false win for v1.9.0)"
else
    fail "expected v1.10.0, got '${result2}'"
fi

result3="$(printf 'v1.10.0-rc1\nnot-a-tag\n1.2.3\n' | _wb_semver_highest)"
if [[ -z "${result3}" ]]; then
    ok "a candidate set with no clean tags at all yields no highest (empty, not an error)"
else
    fail "expected empty result for an all-dirty candidate set, got '${result3}'"
fi

# ── core_api range satisfaction ──────────────────────────────────────────────
# shellcheck disable=SC2015
_wb_version_satisfies 1 ">=1.0 <2.0" && ok "CORE_API_VERSION=1 satisfies '>=1.0 <2.0'" || fail "1 should satisfy >=1.0 <2.0"
# shellcheck disable=SC2015
_wb_version_satisfies 2 ">=1.0 <2.0" && fail "CORE_API_VERSION=2 should NOT satisfy '>=1.0 <2.0'" || ok "2 correctly fails >=1.0 <2.0"
# shellcheck disable=SC2015
_wb_version_satisfies 1.5 ">=1.0 <2.0" && ok "1.5 satisfies >=1.0 <2.0" || fail "1.5 should satisfy >=1.0 <2.0"
# shellcheck disable=SC2015
_wb_version_satisfies 0.9 ">=1.0 <2.0" && fail "0.9 should NOT satisfy >=1.0 <2.0" || ok "0.9 correctly fails >=1.0 <2.0"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
