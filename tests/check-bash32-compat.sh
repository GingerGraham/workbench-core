#!/usr/bin/env bash
# tests/check-bash32-compat.sh
# Greps bin/, bootstrap.sh, lib/, tests/ and .github/scripts/ for
# bash-4+-only constructs that silently break (or hard-error) on bash 3.2 —
# macOS's default /bin/bash, and a hard compatibility requirement for
# everything AGENTS.md lists (docs/architecture.md §6/§7 item 11, build brief
# §2). .github/scripts/ may use bash 4 (it runs only on GitHub-hosted
# runners) but by convention avoids these too (CONTRIBUTING.md). This file
# is excluded: its own pattern table would match. Also checks that every
# `$(cd … && pwd)` in shipped code discards cd's output (D96). Fails if any
# are found.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0

ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

# Each pattern: description|grep -E pattern
declare -a _checks=(
    "declare/local/typeset -A (associative arrays, bash 4+)|(declare|local|typeset)[[:space:]]+-A"
    "mapfile/readarray (bash 4+)|(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|\$)"
    "shopt -s globstar (bash 4+)|shopt[[:space:]]+-s[[:space:]]+globstar"
    "\${var,,} / \${var^^} case conversion (bash 4+)|\\\$\\{[a-zA-Z_][a-zA-Z0-9_]*(,,|\\^\\^)"
    "declare -n nameref (bash 4.3+)|declare[[:space:]]+-n"
    "\${var@Q}-style transforms (bash 4.4+)|\\\$\\{[a-zA-Z_][a-zA-Z0-9_]*@[QEPAa]\\}"
)

SELF="${REPO_ROOT}/tests/check-bash32-compat.sh"

# Comment-only lines (first non-whitespace char is #) are stripped before
# matching — this file's own header comments, and several lib/ files',
# deliberately name these constructs prose-wise to document why they're
# avoided, which would otherwise self-trigger every pattern below.
for entry in "${_checks[@]}"; do
    desc="${entry%%|*}"
    pattern="${entry#*|}"
    hit_files=""
    while IFS= read -r -d '' f; do
        [[ "${f}" == "${SELF}" ]] && continue
        if grep -vE '^[[:space:]]*#' "${f}" | grep -qE "${pattern}"; then
            hit_files="${hit_files}${f}"$'\n'
        fi
    done < <(find "${REPO_ROOT}/bin" "${REPO_ROOT}/bootstrap.sh" "${REPO_ROOT}/lib" \
                  "${REPO_ROOT}/tests" "${REPO_ROOT}/.github/scripts" -type f -print0)
    if [[ -n "${hit_files}" ]]; then
        fail "${desc} found in:"
        printf '%s' "${hit_files}" | while IFS= read -r f; do echo "        ${f}"; done
    else
        ok "no ${desc} in bin/, bootstrap.sh, lib/, tests/, .github/scripts/"
    fi
done

# Every `$(cd … && pwd)` in shipped code discards cd's own output: zsh runs
# chpwd hooks inside $(…), and CDPATH makes cd print the directory, and
# either would land in the captured path (docs/decisions-log.md D96).
# tests/ is left out: it runs under bash with no hooks. Each match runs from
# `$(cd ` to its first `&&`, so two substitutions on one line are checked
# separately.
cd_hits=""
while IFS= read -r -d '' f; do
    while IFS= read -r site; do
        [[ -z "${site}" ]] && continue
        case "${site}" in
            *">/dev/null"*) ;;
            *) cd_hits="${cd_hits}${f#"${REPO_ROOT}/"}: ${site}"$'\n' ;;
        esac
    done < <(grep -vE '^[[:space:]]*#' "${f}" | grep -oE '\$\(cd ([^&]|&[^&])*&&[[:space:]]*pwd' || true)
done < <(find "${REPO_ROOT}/bin" "${REPO_ROOT}/bootstrap.sh" "${REPO_ROOT}/lib" \
              "${REPO_ROOT}/shell" -type f -print0 2>/dev/null)
if [[ -n "${cd_hits}" ]]; then
    fail "\$(cd … && pwd) without >/dev/null on cd found in:"
    printf '%s' "${cd_hits}" | while IFS= read -r h; do echo "        ${h}"; done
else
    ok "every \$(cd … && pwd) in bin/, bootstrap.sh, lib/, shell/ discards cd's output"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
