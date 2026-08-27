#!/usr/bin/env bash
# tests/check-bash32-compat.sh
# Greps lib/ for bash-4+-only constructs that silently break (or hard-error)
# on bash 3.2 — macOS's default /bin/bash, and a hard compatibility
# requirement for the Core API library and loader (ARCHITECTURE.md §6/§7
# item 11, build brief §2). Fails if any are found.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0

ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

# Each pattern: description|grep -E pattern
declare -a _checks=(
    "declare -A (associative arrays, bash 4+)|declare[[:space:]]+-A"
    "mapfile/readarray (bash 4+)|(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|\$)"
    "shopt -s globstar (bash 4+)|shopt[[:space:]]+-s[[:space:]]+globstar"
    "\${var,,} / \${var^^} case conversion (bash 4+)|\\\$\\{[a-zA-Z_][a-zA-Z0-9_]*(,,|\\^\\^)"
    "declare -n nameref (bash 4.3+)|declare[[:space:]]+-n"
)

# Comment-only lines (first non-whitespace char is #) are stripped before
# matching — this file's own header comments, and several lib/ files',
# deliberately name these constructs prose-wise to document why they're
# avoided, which would otherwise self-trigger every pattern below.
for entry in "${_checks[@]}"; do
    desc="${entry%%|*}"
    pattern="${entry#*|}"
    hit_files=""
    while IFS= read -r -d '' f; do
        if grep -vE '^[[:space:]]*#' "${f}" | grep -qE "${pattern}"; then
            hit_files="${hit_files}${f}"$'\n'
        fi
    done < <(find "${REPO_ROOT}/lib" -type f -print0)
    if [[ -n "${hit_files}" ]]; then
        fail "${desc} found in:"
        printf '%s' "${hit_files}" | while IFS= read -r f; do echo "        ${f}"; done
    else
        ok "no ${desc} in lib/"
    fi
done

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
