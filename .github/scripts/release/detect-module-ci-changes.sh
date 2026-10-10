#!/usr/bin/env bash
# .github/scripts/release/detect-module-ci-changes.sh — decides whether
# commits since the last release tag touched anything module CI consumes
# from core's *release* (.github/actions/** or .github/workflows/module-*.yml).
# Those paths are not registered files, so compute-bumps.sh would never bump
# for them on its own, and module CI (which resolves core's latest release,
# D78) would keep running stale rules (security review follow-up R3, D80).
#
# Prints GITHUB_OUTPUT-style lines on stdout:
#   force_severity=patch|      (empty = nothing module-consumed changed)
#   reason=<text>|             (only when force_severity is set)
# Feed force_severity to compute-bumps.sh as WB_RELEASE_FORCE_SEVERITY (the
# D67 floor). A manual, higher floor still wins because compute-bumps.sh
# only ever raises severity.
#
# GitHub-runner-only script (Bash 4+ allowed per AGENTS.md); no bashisms
# beyond what the other release scripts use.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"
cd "${REPO_ROOT}" || exit 1

prev_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)"
if [[ -z "${prev_tag}" ]]; then
    echo "force_severity="
    exit 0
fi

changed="$(git diff --name-only "${prev_tag}..HEAD" -- '.github/actions' '.github/workflows/module-*.yml')"
if [[ -z "${changed}" ]]; then
    echo "force_severity="
    exit 0
fi

echo "detect-module-ci-changes: module-consumed CI files changed since ${prev_tag}:" >&2
printf '  %s\n' "${changed//$'\n'/$'\n'  }" >&2
echo "force_severity=patch"
echo "reason=Publish module-consumed CI changes since ${prev_tag} (.github/actions, module-*.yml) so module CI picks them up (D80)."
