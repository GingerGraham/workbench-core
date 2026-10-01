#!/usr/bin/env bash
# Greps this repo's tracked shell content for a maintained list of
# known-dangerous patterns. Every pattern here should have zero legitimate
# hits in workbench today. If a hit is a genuine false positive, suppress
# it on that exact line with `# pattern-scan:ignore -- <reason>` (reason
# required, D80), not by loosening the pattern — and flag it back so it's
# a visible decision, not a silent exception.
set -euo pipefail

rules_file="${1:?usage: pattern-scan.sh <rules-file>}"
failed=0

# Suppression format (D80): `pattern-scan:ignore -- <reason>`, reason
# non-empty. A bare marker is itself an error. Every accepted suppression is
# printed as a ::notice so reviewers see it in the run summary.
ignore_re='pattern-scan:ignore[[:space:]]+--[[:space:]]+[^[:space:]]'

while IFS=$'\t' read -r pattern description || [[ -n "${pattern}" ]]; do
    [[ -z "${pattern}" || "${pattern}" == \#* ]] && continue
    while IFS=: read -r file line_no line || [[ -n "${file:-}" ]]; do
        [[ -z "${file:-}" ]] && continue
        if [[ "${line}" == *"pattern-scan:ignore"* ]]; then
            if [[ "${line}" =~ ${ignore_re} ]]; then
                echo "::notice file=${file},line=${line_no}::suppressed: ${description} (matched: ${pattern}) — ${line#*pattern-scan:ignore -- }"
                continue
            fi
            echo "::error file=${file},line=${line_no}::pattern-scan:ignore without a reason — use 'pattern-scan:ignore -- <reason>' (${description})"
            failed=1
            continue
        fi
        echo "::error file=${file},line=${line_no}::${description} (matched: ${pattern})"
        failed=1
    # -e (not a bare positional pattern) — git grep otherwise tries to parse
    # any pattern starting with a double dash as one of its own options and
    # errors out, which this loop's `|| true` was silently swallowing: those
    # patterns matched nothing, ever.
    #
    # files/* covers configuration modules copy into sensitive places
    # (workbench-ssh ships ~/.ssh/config.d content there — review R5).
    # A git pathspec '*' also matches across '/', so nested files count.
    done < <(git grep -nE -e "${pattern}" -- '*.sh' 'bin/*' 'hooks/*' 'files/*' 2>/dev/null || true)
done < "${rules_file}"

exit "${failed}"
