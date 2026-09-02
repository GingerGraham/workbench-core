#!/usr/bin/env bash
# .github/scripts/ci/run-tests.sh — runs tests/check-*.sh in turn, tallies
# each suite's own OK:/FAIL: line counts, and writes a markdown summary
# table. ARCHITECTURE.md §12 D26/§13 CI.
#
# Runs standalone too: $GITHUB_STEP_SUMMARY writes are guarded, so this is
# safe to run locally with no GitHub Actions context, for the exact same
# aggregation used in CI.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TESTS_DIR="${REPO_ROOT}/tests"

FAILED_SUITES=0
TOTAL_OK=0
TOTAL_FAIL=0

declare -a ROWS=()

for suite in "${TESTS_DIR}"/check-*.sh; do
    [[ -e "${suite}" ]] || continue
    name="$(basename "${suite}")"

    output="$(bash "${suite}" 2>&1)"
    exit_code=$?

    ok_count="$(grep -c '^OK:' <<<"${output}")"
    fail_count="$(grep -c '^FAIL:' <<<"${output}")"

    TOTAL_OK=$((TOTAL_OK + ok_count))
    TOTAL_FAIL=$((TOTAL_FAIL + fail_count))

    echo "=== ${name} ==="
    echo "${output}"
    echo

    if [[ ${exit_code} -ne 0 ]]; then
        FAILED_SUITES=$((FAILED_SUITES + 1))
        status="FAIL"
        echo "!!! ${name} exited non-zero (${exit_code})"
    else
        status="OK"
    fi

    ROWS+=("| ${name} | ${status} | ${ok_count} | ${fail_count} |")
done

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## Test suite results"
        echo
        echo "| Suite | Status | OK | FAIL |"
        echo "|---|---|---|---|"
        for row in "${ROWS[@]+"${ROWS[@]}"}"; do
            echo "${row}"
        done
        echo "| **Total** | $([[ ${FAILED_SUITES} -eq 0 ]] && echo OK || echo FAIL) | ${TOTAL_OK} | ${TOTAL_FAIL} |"
    } >>"${GITHUB_STEP_SUMMARY}"
fi

echo
echo "==============================="
echo "Suites run:    ${#ROWS[@]}"
echo "Suites failed: ${FAILED_SUITES}"
echo "Total OK:      ${TOTAL_OK}"
echo "Total FAIL:    ${TOTAL_FAIL}"
echo "==============================="

if [[ ${FAILED_SUITES} -gt 0 ]]; then
    exit 1
fi

exit 0
