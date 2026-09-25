#!/usr/bin/env bash
# Greps this repo's tracked shell content for a maintained list of
# known-dangerous patterns. Every pattern here should have zero legitimate
# hits in workbench today. If a hit is a genuine false positive, suppress
# it on that exact line with `# pattern-scan:ignore -- <reason>`, not by
# loosening the pattern — and flag it back so it's a visible decision, not
# a silent exception.
set -euo pipefail

rules_file="${1:?usage: pattern-scan.sh <rules-file>}"
failed=0

while IFS=$'\t' read -r pattern description || [[ -n "${pattern}" ]]; do
    [[ -z "${pattern}" || "${pattern}" == \#* ]] && continue
    while IFS=: read -r file line_no line || [[ -n "${file:-}" ]]; do
        [[ -z "${file:-}" ]] && continue
        [[ "${line}" == *"pattern-scan:ignore"* ]] && continue
        echo "::error file=${file},line=${line_no}::${description} (matched: ${pattern})"
        failed=1
    # -e (not a bare positional pattern) — git grep otherwise tries to parse
    # any pattern starting with '-' (e.g. --allow-unsigned-rpm) as one of its
    # own options and errors out, which this loop's `|| true` was silently
    # swallowing: those patterns matched nothing, ever.
    done < <(git grep -nE -e "${pattern}" -- '*.sh' 'bin/*' 'hooks/*' 2>/dev/null || true)
done < "${rules_file}"

exit "${failed}"
