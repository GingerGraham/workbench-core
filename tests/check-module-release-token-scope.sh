#!/usr/bin/env bash
# tests/check-module-release-token-scope.sh — acceptance check for
# .github/workflows/module-release.yml (post-launch ledger N4, #169,
# docs/decisions-log.md D119): module release runs scripts from
# workbench-core at core_ref, so they must never run while the release App's
# write token exists or is readable.
#
# The workflow is read as plain text. Properties checked:
#   1. every actions/checkout keeps no credentials (persist-credentials: false)
#   2. nothing references the App token before it is minted
#   3. the token is minted after the last step that runs a core script
#   4. a step with no token verifies that only CHANGELOG.md changed
#   5. every step after the mint is a `uses:` step, and none of their
#      scripts runs git, gh or a child process
#   6. the commit step sends CHANGELOG.md and nothing else
# Then each property is broken in a copy of the workflow, to show the check
# can fail.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/module-release.yml"
FINALIZE="${REPO_ROOT}/.github/workflows/module-release-finalize.yml"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# line_of <file> <fixed text> — first line number containing the text, or empty
line_of() { grep -nF -e "$2" "$1" | head -n 1 | cut -d: -f1; }

# last_line_of <file> <fixed text> — last line number containing the text
last_line_of() { grep -nF -e "$2" "$1" | tail -n 1 | cut -d: -f1; }

# propose_job <file> — only the propose job's text (workflow header comments
# mention the token and the scripts, so they must not be scanned)
propose_job() { sed -n '/^  propose:/,$p' "$1"; }

# problems <file> — prints one line per violated property; nothing if clean
problems() {
    local file="$1" job mint last_core verify
    job="${WORK}/job.yml"
    propose_job "${file}" > "${job}"

    local checkouts creds
    checkouts="$(grep -c 'uses: actions/checkout@' "${job}")"
    creds="$(grep -c 'persist-credentials: false' "${job}")"
    if [[ "${checkouts}" -lt 2 || "${checkouts}" -ne "${creds}" ]]; then
        echo "checkouts keep credentials (${checkouts} checkouts, ${creds} with persist-credentials: false)"
    fi

    mint="$(line_of "${job}" 'id: app-token')"
    if [[ -z "${mint}" ]]; then
        echo "no App token step found"
        return
    fi

    local first_ref
    first_ref="$(grep -nF 'steps.app-token' "${job}" | head -n 1 | cut -d: -f1)"
    if [[ -n "${first_ref}" && "${first_ref}" -lt "${mint}" ]]; then
        echo "the App token is referenced (line ${first_ref}) before it is minted (line ${mint})"
    fi

    last_core="$(last_line_of "${job}" '_core/.github/scripts/')"
    if [[ -n "${last_core}" && "${last_core}" -gt "${mint}" ]]; then
        echo "a core script runs (line ${last_core}) after the App token is minted (line ${mint})"
    fi

    verify="$(line_of "${job}" '!= "CHANGELOG.md"')"
    if [[ -z "${verify}" || "${verify}" -gt "${mint}" ]]; then
        echo "no token-free check that only CHANGELOG.md changed before the mint"
    fi

    local after
    after="${WORK}/after.yml"
    # Comments are dropped: they explain why git and gh are absent.
    sed -n "$((mint + 1)),\$p" "${job}" | grep -vE '^[[:space:]]*#' > "${after}"
    if grep -qE '^[[:space:]]+run:' "${after}"; then
        echo "a run: step follows the token mint"
    fi
    if grep -qE '(^|[^A-Za-z_])(git|gh)[[:space:]]|execSync|child_process' "${after}"; then
        echo "a step after the token mint runs git, gh or a child process"
    fi

    if ! grep -q "path: 'CHANGELOG.md'" "${after}"; then
        echo "the commit step does not send CHANGELOG.md"
    elif [[ "$(grep -c "path: '" "${after}")" -ne 1 ]]; then
        echo "the commit step sends more than CHANGELOG.md"
    fi
}

# ── The real workflow ──────────────────────────────────────────────────────
out="$(problems "${WORKFLOW}")"
if [[ -z "${out}" ]]; then
    ok "module-release.yml: the write token never meets a core script"
else
    fail "module-release.yml: ${out}"
fi

# The finalize workflow runs no core script at all, so nothing there can see
# its token either.
if grep -qF '_core' "${FINALIZE}"; then
    fail "module-release-finalize.yml checks out or runs workbench-core code"
else
    ok "module-release-finalize.yml runs no core script"
fi

# ── Each property, broken in a copy, must be reported ──────────────────────
expect_problem() {
    local label="$1" pattern="$2" mutated="$3"
    local got
    got="$(problems "${mutated}")"
    if grep -q -e "${pattern}" <<< "${got}"; then
        ok "check fails when ${label}"
    else
        fail "check did not catch: ${label} (got: ${got:-nothing})"
    fi
}

m="${WORK}/m1.yml"
# awk, not sed: BSD sed (macOS) has no `0,/re/` address for "first match only".
awk '!done && /persist-credentials: false/ { sub(/persist-credentials: false/, "persist-credentials: true"); done = 1 } { print }' "${WORKFLOW}" > "${m}"
expect_problem "a checkout keeps credentials" "checkouts keep credentials" "${m}"

# Move the whole mint step to the top of the propose job.
mint_start="$(line_of "${WORKFLOW}" '# Minted only now')"
mint_end="$(( $(line_of "${WORKFLOW}" '# main requires verified commit signatures') - 1 ))"
anchor="$(line_of "${WORKFLOW}" '# Read-only default token')"
{
    sed -n "1,$((anchor - 1))p" "${WORKFLOW}"
    sed -n "${mint_start},${mint_end}p" "${WORKFLOW}"
    sed -n "${anchor},$((mint_start - 1))p" "${WORKFLOW}"
    sed -n "$((mint_end + 1)),\$p" "${WORKFLOW}"
} > "${WORK}/m2.yml"
expect_problem "the token is minted before the core scripts run" "referenced .* before it is minted\|core script runs" "${WORK}/m2.yml"

grep -vF '!= "CHANGELOG.md"' "${WORKFLOW}" > "${WORK}/m3.yml"
expect_problem "the CHANGELOG-only check is removed" "only CHANGELOG.md changed" "${WORK}/m3.yml"

printf '      - name: after\n        run: git push\n' | cat "${WORKFLOW}" - > "${WORK}/m4.yml"
expect_problem "a run: step follows the mint" "run: step follows" "${WORK}/m4.yml"

sed "s|const additions = \[{|const additions = [{ path: 'x.sh' }, {|" "${WORKFLOW}" > "${WORK}/m5.yml"
expect_problem "the commit sends another file" "more than CHANGELOG.md" "${WORK}/m5.yml"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
