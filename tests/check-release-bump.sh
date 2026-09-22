#!/usr/bin/env bash
# tests/check-release-bump.sh — acceptance check for the release pipeline's
# bump arithmetic, Conventional Commit scope resolution, and CHANGELOG
# gate/rewrite (.github/scripts/release/). docs/decisions-log.md D27.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RELEASE_DIR="${REPO_ROOT}/.github/scripts/release"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── 1. Bump arithmetic (lib.sh, no fixture repo needed) ─────────────────
# shellcheck source=.github/scripts/release/lib.sh
source "${RELEASE_DIR}/lib.sh"

# shellcheck disable=SC2015
[[ "$(_rel_bump_semver 1.2.3 patch)" == "1.2.4" ]] \
    && ok "patch bump: 1.2.3 -> 1.2.4" || fail "patch bump incorrect"
# shellcheck disable=SC2015
[[ "$(_rel_bump_semver 1.2.3 minor)" == "1.3.0" ]] \
    && ok "minor bump: 1.2.3 -> 1.3.0 (patch reset)" || fail "minor bump incorrect"
# shellcheck disable=SC2015
[[ "$(_rel_bump_semver 1.2.3 major)" == "2.0.0" ]] \
    && ok "major bump: 1.2.3 -> 2.0.0 (minor+patch reset)" || fail "major bump incorrect"
# shellcheck disable=SC2015
[[ "$(_rel_bump_semver 1.2.3 none)" == "1.2.3" ]] \
    && ok "none severity: version unchanged" || fail "none severity changed version"

# ── 2. Conventional Commit parsing ───────────────────────────────────────
# shellcheck disable=SC2015
[[ "$(_rel_commit_severity "$(printf 'feat: add thing')")" == "minor" ]] \
    && ok "feat: -> minor" || fail "feat: severity wrong"
# shellcheck disable=SC2015
[[ "$(_rel_commit_severity "$(printf 'fix: bug')")" == "patch" ]] \
    && ok "fix: -> patch" || fail "fix: severity wrong"
# shellcheck disable=SC2015
[[ "$(_rel_commit_severity "$(printf 'perf: speed')")" == "patch" ]] \
    && ok "perf: -> patch" || fail "perf: severity wrong"
# shellcheck disable=SC2015
[[ "$(_rel_commit_severity "$(printf 'chore: tidy')")" == "none" ]] \
    && ok "chore: -> none (informational only)" || fail "chore: severity wrong"
# shellcheck disable=SC2015
[[ "$(_rel_commit_severity "$(printf 'feat!: breaking')")" == "major" ]] \
    && ok "feat!: -> major (bang override)" || fail "feat!: severity wrong"
# shellcheck disable=SC2015
[[ "$(_rel_commit_severity "$(printf 'fix: x\n\nBREAKING CHANGE: yes')")" == "major" ]] \
    && ok "BREAKING CHANGE: footer -> major regardless of type" || fail "breaking-footer severity wrong"
# shellcheck disable=SC2015
[[ "$(_rel_commit_severity "$(printf 'not a conventional commit')")" == "unparseable" ]] \
    && ok "unparseable header -> 'unparseable', not an error" || fail "unparseable detection wrong"
# shellcheck disable=SC2015
[[ "$(_rel_commit_severity "$(printf 'bogustype: x')")" == "unparseable" ]] \
    && ok "well-formed header, unrecognised type -> 'unparseable'" || fail "unknown-type detection wrong"

# ── 3. CHANGELOG gate + rename/insert round-trip ─────────────────────────
EMPTY_CHANGELOG="${WORK}/empty-changelog.md"
cat > "${EMPTY_CHANGELOG}" <<'EOF'
# Changelog

## [Unreleased]

## [1.0.0] - 2026-01-01
EOF
if _rel_changelog_has_entries "${EMPTY_CHANGELOG}"; then
    fail "empty [Unreleased] section incorrectly reported as having entries"
else
    ok "empty [Unreleased] section correctly reported as empty (gate would fire)"
fi

FULL_CHANGELOG="${WORK}/full-changelog.md"
cat > "${FULL_CHANGELOG}" <<'EOF'
# Changelog

## [Unreleased]

### Added

- something worth shipping

## [1.0.0] - 2026-01-01
EOF
if _rel_changelog_has_entries "${FULL_CHANGELOG}"; then
    ok "non-empty [Unreleased] section correctly reported as having entries"
else
    fail "non-empty [Unreleased] section incorrectly reported as empty"
fi

_rel_changelog_release "${FULL_CHANGELOG}" "1.1.0" "2026-09-02"
if grep -qF '## [1.1.0] - 2026-09-02' "${FULL_CHANGELOG}"; then
    ok "[Unreleased] renamed to [1.1.0] - 2026-09-02"
else
    fail "CHANGELOG rename did not produce the expected heading"
fi
if grep -qF '## [Unreleased]' "${FULL_CHANGELOG}"; then
    ok "a fresh empty [Unreleased] heading was inserted"
else
    fail "no fresh [Unreleased] heading found after rename"
fi
if grep -qF '### Added' "${FULL_CHANGELOG}"; then
    ok "the renamed section's own entries survived the rewrite"
else
    fail "renamed section lost its entries"
fi

# ── 4. End-to-end: a fixture repo exercising compute-bumps/apply-bumps ──
FIXTURE="${WORK}/fixture"
mkdir -p "${FIXTURE}/bin" "${FIXTURE}/lib/core" "${FIXTURE}/lib/other"

cat > "${FIXTURE}/bin/wb" <<'EOF'
#!/usr/bin/env bash
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "bin/wb" "0.1.0" || true
EOF

cat > "${FIXTURE}/lib/core/semver.sh" <<'EOF'
#!/usr/bin/env bash
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/core/semver.sh" "0.1.0" || true

_wb_semver_cmp() {
    local a="${1#v}" b="${2#v}"
    local -a A B
    IFS='.' read -r -a A <<< "${a}"
    IFS='.' read -r -a B <<< "${b}"
    local n="${#A[@]}"
    [[ "${#B[@]}" -gt "${n}" ]] && n="${#B[@]}"
    local i=0 ai bi
    while [[ "${i}" -lt "${n}" ]]; do
        ai="${A[${i}]:-0}"; bi="${B[${i}]:-0}"
        ai=$((10#${ai:-0})); bi=$((10#${bi:-0}))
        if [[ "${ai}" -lt "${bi}" ]]; then echo -1; return 0
        elif [[ "${ai}" -gt "${bi}" ]]; then echo 1; return 0
        fi
        i=$((i + 1))
    done
    echo 0
}
EOF

cat > "${FIXTURE}/lib/other/widget.sh" <<'EOF'
#!/usr/bin/env bash
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/other/widget.sh" "0.1.0" || true
EOF

cat > "${FIXTURE}/bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
_WB_BOOTSTRAP_VERSION="0.1.0"
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "bootstrap.sh" "${_WB_BOOTSTRAP_VERSION}" || true
EOF

echo "1.0.0" > "${FIXTURE}/VERSION"
cat > "${FIXTURE}/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

EOF

(
    cd "${FIXTURE}" || exit 1
    git init -q
    git config user.email "t@t.com"
    git config user.name "Test"
    git add -A
    git commit -q -m "chore: initial fixture"
    git tag -a v1.0.0 -m v1.0.0
)

export WORKBENCH_RELEASE_TEST_REPO_ROOT="${FIXTURE}"
# lib.sh was already sourced (section 1) with REPO_ROOT resolved to the
# real repo before this override existed — reassign it directly here too,
# since compute-bumps.sh/apply-bumps.sh (separate subprocesses, re-sourcing
# lib.sh fresh) pick up the env var either way, but this script's own
# direct _rel_* calls below (section 4f) reference the already-sourced
# $REPO_ROOT global, not a fresh source.
REPO_ROOT="${FIXTURE}"

# 4a. "nothing changed" path: a chore/docs-only commit -> OVERALL none, no
#     per-file lines, no VERSION/CHANGELOG rewrite.
(
    cd "${FIXTURE}" || exit 1
    echo "docs update" >> README-placeholder.md
    git add -A
    git commit -q -m "docs: unrelated documentation tweak"
)
PLAN_NOOP="$("${RELEASE_DIR}/compute-bumps.sh" 2>/dev/null)"
if grep -q '^OVERALL|1.0.0|1.0.0|none|' <<< "${PLAN_NOOP}"; then
    ok "docs-only commit: OVERALL severity is none, VERSION unchanged in the plan"
else
    fail "docs-only commit unexpectedly produced a version bump: ${PLAN_NOOP}"
fi
if ! grep -q -v '^OVERALL|' <<< "${PLAN_NOOP}"; then
    ok "docs-only commit: no per-file bump lines in the plan"
else
    fail "docs-only commit unexpectedly produced per-file bump lines"
fi
echo "${PLAN_NOOP}" > "${FIXTURE}/plan.txt"
if "${RELEASE_DIR}/apply-bumps.sh" "${FIXTURE}/plan.txt" 2>/dev/null; then
    ok "apply-bumps.sh is a clean no-op (exit 0) when OVERALL severity is none"
else
    fail "apply-bumps.sh failed on a none-severity plan"
fi
if [[ "$(cat "${FIXTURE}/VERSION")" == "1.0.0" ]]; then
    ok "apply-bumps.sh no-op left VERSION untouched"
else
    fail "apply-bumps.sh no-op modified VERSION"
fi

# Reset fixture back to the v1.0.0 tag for the remaining scenarios, each
# building its own small commit history on top.
(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 4b. Auto-detected scope: a fix: commit with no explicit scope, touching
#     exactly one registered file.
(
    cd "${FIXTURE}" || exit 1
    echo "# fix" >> lib/other/widget.sh
    git add -A
    git commit -q -m "fix: correct a bug in widget.sh"
)
PLAN_AUTO="$("${RELEASE_DIR}/compute-bumps.sh" 2>/dev/null)"
if grep -q '^lib/other/widget\.sh|0\.1\.0|0\.1\.1|patch$' <<< "${PLAN_AUTO}"; then
    ok "auto-detected scope: fix: with no explicit scope bumped the one touched registered file"
else
    fail "auto-detected scope did not bump the touched file as expected: ${PLAN_AUTO}"
fi
if grep -q '^OVERALL|1\.0\.0|1\.0\.1|patch|component rollup$' <<< "${PLAN_AUTO}"; then
    ok "auto-detected scope: OVERALL rolled up to patch, reason 'component rollup'"
else
    fail "auto-detected scope OVERALL line wrong: ${PLAN_AUTO}"
fi

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 4c. Explicit path scope: severity applies only to the named file, not to
#     every file the commit's diff happens to touch.
(
    cd "${FIXTURE}" || exit 1
    echo "# feat" >> lib/core/semver.sh
    echo "# incidental" >> lib/other/widget.sh
    git add -A
    git commit -q -m "feat(lib/core/semver.sh): add a new comparator mode"
)
PLAN_SCOPED="$("${RELEASE_DIR}/compute-bumps.sh" 2>/dev/null)"
if grep -q '^lib/core/semver\.sh|0\.1\.0|0\.2\.0|minor$' <<< "${PLAN_SCOPED}"; then
    ok "explicit path scope: named file bumped minor as declared"
else
    fail "explicit path scope did not bump the named file correctly: ${PLAN_SCOPED}"
fi
if grep -q '^lib/other/widget\.sh|' <<< "${PLAN_SCOPED}"; then
    fail "explicit path scope incorrectly also bumped an unnamed file it happened to touch"
else
    ok "explicit path scope did not bump the other file the commit's diff also touched"
fi

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 4d. 'core' scope: bumps OVERALL without bumping any specific file.
(
    cd "${FIXTURE}" || exit 1
    echo "# core decision" >> README-placeholder.md
    git add -A
    git commit -q -m "feat(core): a product-level decision with no file of its own"
)
PLAN_CORE="$("${RELEASE_DIR}/compute-bumps.sh" 2>/dev/null)"
if ! grep -q -v '^OVERALL|' <<< "${PLAN_CORE}"; then
    ok "'core' scope: no per-file bump lines produced"
else
    fail "'core' scope unexpectedly produced per-file bump lines: ${PLAN_CORE}"
fi
if grep -q '^OVERALL|1\.0\.0|1\.1\.0|minor|core-scoped commit$' <<< "${PLAN_CORE}"; then
    ok "'core' scope: OVERALL bumped minor, reason 'core-scoped commit'"
else
    fail "'core' scope OVERALL line wrong: ${PLAN_CORE}"
fi

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 4e. Unparseable type touching a registered file: warning, not an error,
#     and no severity contribution.
(
    cd "${FIXTURE}" || exit 1
    echo "# oops" >> lib/other/widget.sh
    git add -A
    git commit -q -m "made a change without a conventional type"
)
PLAN_WARN="$("${RELEASE_DIR}/compute-bumps.sh" 2>"${WORK}/warn.log")"
RC_WARN=$?
if [[ "${RC_WARN}" -eq 0 ]]; then
    ok "unparseable-type commit does not fail compute-bumps.sh"
else
    fail "unparseable-type commit caused compute-bumps.sh to exit non-zero"
fi
if grep -q '^OVERALL|1\.0\.0|1\.0\.0|none|' <<< "${PLAN_WARN}"; then
    ok "unparseable-type commit contributes no severity"
else
    fail "unparseable-type commit unexpectedly contributed a severity: ${PLAN_WARN}"
fi
if grep -qi "WARNING" "${WORK}/warn.log"; then
    ok "unparseable-type commit touching a registered file logs a visible warning"
else
    fail "no warning logged for an unparseable-type commit touching a registered file"
fi

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 4f. CHANGELOG gate blocks apply-bumps.sh when [Unreleased] is empty, even
#     though a real bump is pending.
(
    cd "${FIXTURE}" || exit 1
    printf '# Changelog\n\n## [Unreleased]\n' > CHANGELOG.md
    echo "# fix" >> lib/other/widget.sh
    git add -A
    git commit -q -m "fix: a real bump with no changelog entry"
)
"${RELEASE_DIR}/compute-bumps.sh" > "${FIXTURE}/plan-gate.txt" 2>/dev/null
if "${RELEASE_DIR}/apply-bumps.sh" "${FIXTURE}/plan-gate.txt" 2>"${WORK}/gate.log"; then
    fail "apply-bumps.sh did not fail with an empty [Unreleased] section"
else
    ok "apply-bumps.sh fails loudly when [Unreleased] is empty but a real bump is pending"
fi
if [[ "$(_rel_current_version lib/other/widget.sh)" == "0.1.0" ]]; then
    ok "CHANGELOG gate failure left widget.sh's version untouched (no partial apply)"
else
    fail "CHANGELOG gate failure did not prevent a partial file rewrite"
fi

# 4g. No baseline tag yet at all: a clean no-op plan (exit 0), not a hard
#     failure — matters most on the very first push that introduces this
#     pipeline, before v1.0.0 has actually been tagged.
UNTAGGED="${WORK}/untagged"
mkdir -p "${UNTAGGED}/lib/other"
cat > "${UNTAGGED}/lib/other/widget.sh" <<'EOF'
#!/usr/bin/env bash
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/other/widget.sh" "0.1.0" || true
EOF
echo "1.0.0" > "${UNTAGGED}/VERSION"
printf '# Changelog\n\n## [Unreleased]\n' > "${UNTAGGED}/CHANGELOG.md"
(
    cd "${UNTAGGED}" || exit 1
    git init -q
    git config user.email "t@t.com"
    git config user.name "Test"
    git add -A
    git commit -q -m "chore: no tags here yet"
)
export WORKBENCH_RELEASE_TEST_REPO_ROOT="${UNTAGGED}"
REPO_ROOT="${UNTAGGED}"
if PLAN_UNTAGGED="$("${RELEASE_DIR}/compute-bumps.sh" 2>/dev/null)"; then
    ok "compute-bumps.sh exits 0 when no baseline tag exists yet, not an error"
else
    fail "compute-bumps.sh failed outright when no baseline tag exists"
fi
if grep -q '^OVERALL|1.0.0|1.0.0|none|' <<< "${PLAN_UNTAGGED}"; then
    ok "no-baseline-tag case produces a clean none-severity plan"
else
    fail "no-baseline-tag case produced an unexpected plan: ${PLAN_UNTAGGED}"
fi

export WORKBENCH_RELEASE_TEST_REPO_ROOT="${FIXTURE}"
REPO_ROOT="${FIXTURE}"
(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 4h. 'core' scope touching a registered file: compute-bumps.sh still only
#     bumps OVERALL (documented, deliberate — D27), but now also logs a
#     visible warning pointing at the PR-time check that should have caught
#     this (D55) — a post-merge safety net for an admin-bypass path, not a
#     substitute for pr-check.yml.
(
    cd "${FIXTURE}" || exit 1
    echo "# should have been scoped to widget.sh" >> lib/other/widget.sh
    git add -A
    git commit -q -m "feat(core): should have been scoped to widget.sh"
)
PLAN_CORE_REG="$("${RELEASE_DIR}/compute-bumps.sh" 2>"${WORK}/core-reg-warn.log")"
if ! grep -q -v '^OVERALL|' <<< "${PLAN_CORE_REG}"; then
    ok "'core' scope touching a registered file: still no per-file bump line (documented D27 behaviour)"
else
    fail "'core' scope touching a registered file unexpectedly produced a per-file bump line: ${PLAN_CORE_REG}"
fi
if grep -q '^OVERALL|1\.0\.0|1\.1\.0|minor|core-scoped commit$' <<< "${PLAN_CORE_REG}"; then
    ok "'core' scope touching a registered file: OVERALL still bumps minor as designed"
else
    fail "'core' scope touching a registered file: OVERALL line wrong: ${PLAN_CORE_REG}"
fi
if grep -qi "D55" "${WORK}/core-reg-warn.log"; then
    ok "compute-bumps.sh logs a visible D55 warning when 'core' scope touches a registered file"
else
    fail "compute-bumps.sh did not log the expected D55 warning"
fi

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 4i. Manual floor with nothing else pending: forcing 'major' on a
#     docs-only cycle bumps OVERALL to major with a manual-override
#     reason, and produces no per-file bump lines.
(
    cd "${FIXTURE}" || exit 1
    echo "docs update" >> README-placeholder.md
    git add -A
    git commit -q -m "docs: unrelated documentation tweak"
)
PLAN_FORCE_NONE="$(WB_RELEASE_FORCE_SEVERITY=major "${RELEASE_DIR}/compute-bumps.sh" 2>/dev/null)"
if grep -q "^OVERALL|1\.0\.0|2\.0\.0|major|manual override (workflow_dispatch): requested at least 'major'\$" <<< "${PLAN_FORCE_NONE}"; then
    ok "manual floor on a none-severity cycle forces OVERALL to major with a manual-override reason"
else
    fail "manual floor on a none-severity cycle produced the wrong OVERALL line: ${PLAN_FORCE_NONE}"
fi
if ! grep -q -v '^OVERALL|' <<< "${PLAN_FORCE_NONE}"; then
    ok "manual floor on a none-severity cycle produces no per-file bump lines"
else
    fail "manual floor on a none-severity cycle unexpectedly produced per-file bump lines: ${PLAN_FORCE_NONE}"
fi

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 4j. Manual floor is a floor, not a downgrade: a pending feat: (minor)
#     commit plus a 'patch' manual dispatch still ships minor, with the
#     original computed reason, not a manual-override one.
(
    cd "${FIXTURE}" || exit 1
    echo "# fix" >> lib/other/widget.sh
    git add -A
    git commit -q -m "feat: add a new capability to widget.sh"
)
# shellcheck disable=SC2209
PLAN_NO_DOWNGRADE="$(WB_RELEASE_FORCE_SEVERITY=patch "${RELEASE_DIR}/compute-bumps.sh" 2>/dev/null)"
if grep -q '^OVERALL|1\.0\.0|1\.1\.0|minor|component rollup$' <<< "${PLAN_NO_DOWNGRADE}"; then
    ok "manual 'patch' floor does not downgrade a pending minor change; reason stays 'component rollup'"
else
    fail "manual floor incorrectly changed severity or reason: ${PLAN_NO_DOWNGRADE}"
fi

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 4k. Invalid WB_RELEASE_FORCE_SEVERITY value: fails loudly, doesn't
#     silently fall back to unforced behaviour.
(
    cd "${FIXTURE}" || exit 1
    echo "docs update" >> README-placeholder.md
    git add -A
    git commit -q -m "docs: another unrelated tweak"
)
if WB_RELEASE_FORCE_SEVERITY=banana "${RELEASE_DIR}/compute-bumps.sh" >/dev/null 2>"${WORK}/invalid.log"; then
    fail "compute-bumps.sh did not fail on an invalid WB_RELEASE_FORCE_SEVERITY value"
else
    ok "compute-bumps.sh fails loudly on an invalid WB_RELEASE_FORCE_SEVERITY value"
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

# 4l. CHANGELOG gate still applies to a fully manual, zero-qualifying-
#     commit release -- forcing a bump doesn't bypass it.
(
    cd "${FIXTURE}" || exit 1
    printf '# Changelog\n\n## [Unreleased]\n' > CHANGELOG.md
    echo "docs update" >> README-placeholder.md
    git add -A
    git commit -q -m "docs: yet another unrelated tweak"
)
# shellcheck disable=SC2209
WB_RELEASE_FORCE_SEVERITY=patch "${RELEASE_DIR}/compute-bumps.sh" > "${FIXTURE}/plan-manual-gate.txt" 2>/dev/null
if "${RELEASE_DIR}/apply-bumps.sh" "${FIXTURE}/plan-manual-gate.txt" 2>"${WORK}/manual-gate.log"; then
    fail "apply-bumps.sh did not fail with an empty [Unreleased] section on a manually-forced release"
else
    ok "CHANGELOG gate still blocks a manually-forced release with an empty [Unreleased] section"
fi

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 4m. Regression for a real incident: compute-bumps.sh invoked (e.g. via
#     workflow_dispatch) while HEAD is itself the just-tagged release
#     commit must resolve PREV_TAG to that same tag, not skip past it to
#     an older one — `git describe ... HEAD^` walks past a tag that sits
#     on HEAD itself, silently re-including every already-released commit
#     back to the PREVIOUS tag in the diff range. Confirmed live: a manual
#     'patch' dispatch run right after v2.12.0 was cut recomputed against
#     (v2.11.2, HEAD] instead of (v2.12.0, HEAD], re-counting the
#     already-released core-scoped feat commit and proposing v2.13.0
#     instead of a clean v2.12.1.
(
    cd "${FIXTURE}" || exit 1
    echo "# fix" >> lib/other/widget.sh
    git add -A
    git commit -q -m "fix: correct a bug in widget.sh"
    printf '1.1.0\n' > VERSION
    git add -A
    git commit -q -m "chore(release): v1.1.0"
    git tag -a v1.1.0 -m v1.1.0
)
PLAN_AT_TAG="$("${RELEASE_DIR}/compute-bumps.sh" 2>/dev/null)"
if grep -q '^OVERALL|1\.1\.0|1\.1\.0|none|' <<< "${PLAN_AT_TAG}"; then
    ok "compute-bumps.sh run with HEAD exactly on the just-cut tag finds no pending commits (PREV_TAG resolves to HEAD's own tag, not an older one)"
else
    fail "compute-bumps.sh run with HEAD exactly on the just-cut tag incorrectly found pending commits: ${PLAN_AT_TAG}"
fi
# shellcheck disable=SC2209
PLAN_AT_TAG_FORCED="$(WB_RELEASE_FORCE_SEVERITY=patch "${RELEASE_DIR}/compute-bumps.sh" 2>/dev/null)"
if grep -q "^OVERALL|1\.1\.0|1\.1\.1|patch|manual override (workflow_dispatch): requested at least 'patch'\$" <<< "${PLAN_AT_TAG_FORCED}"; then
    ok "manual floor with HEAD on the just-cut tag proposes the correct next patch (1.1.1), not a version inflated by re-counting already-released commits"
else
    fail "manual floor with HEAD on the just-cut tag proposed the wrong version: ${PLAN_AT_TAG_FORCED}"
fi

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# ── 9. PR title format check (docs/decisions-log.md D47) ───────────────────
# The real-world incident this guards against: PR #46's title lacked a
# Conventional Commit prefix, so the squash-merge commit that landed on
# main (using the PR title as its subject, per GitHub's default squash
# behaviour) didn't parse — silently dropping the whole PR's release
# severity even though every individual commit inside it was correctly
# formatted.
if bash "${RELEASE_DIR}/check-pr-title-format.sh" "feat: add a thing" >/dev/null 2>&1; then
    ok "check-pr-title-format.sh: a well-formed title passes"
else
    fail "check-pr-title-format.sh: a well-formed title was rejected"
fi
if bash "${RELEASE_DIR}/check-pr-title-format.sh" "feat(core)!: breaking change" >/dev/null 2>&1; then
    ok "check-pr-title-format.sh: a well-formed title with scope+breaking marker passes"
else
    fail "check-pr-title-format.sh: a well-formed scoped/breaking title was rejected"
fi
if bash "${RELEASE_DIR}/check-pr-title-format.sh" "Support workbench.yml/wb.yml as a parallel, version-2 manifest name" >/tmp/wb-pr-title-bad.log 2>&1; then
    fail "check-pr-title-format.sh: PR #46's actual (unprefixed) title was incorrectly accepted"
else
    ok "check-pr-title-format.sh: rejects a title with no Conventional Commit prefix (PR #46's actual title)"
fi
# shellcheck disable=SC2015
grep -q "expected: <feat|fix" /tmp/wb-pr-title-bad.log && ok "check-pr-title-format.sh: rejection message names the expected grammar" || fail "check-pr-title-format.sh: rejection message missing expected-grammar hint"

# ── 10. 'core' scope vs a touched registered file (docs/decisions-log.md D55) ──
# The PR #58/#59 incident: an explicit 'core' scope is an author override
# that skips auto-detection entirely, so it must never coincide with a
# commit/PR that actually touches a registered file — that file would
# silently keep its old script-local version. This checks both
# check-commit-format.sh and check-pr-title-format.sh catch it at PR time.

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)
BASE_D55="$(cd "${FIXTURE}" && git rev-parse HEAD)"

# 10a. check-commit-format.sh: a 'core'-scoped commit that also touches a
#      registered file must fail.
(
    cd "${FIXTURE}" || exit 1
    echo "# should have been scoped to widget.sh" >> lib/other/widget.sh
    git add -A
    git commit -q -m "feat(core): should have been scoped to widget.sh"
)
HEAD_D55_BAD="$(cd "${FIXTURE}" && git rev-parse HEAD)"
if bash "${RELEASE_DIR}/check-commit-format.sh" "${BASE_D55}" "${HEAD_D55_BAD}" >/tmp/wb-commit-core-reg.log 2>&1; then
    fail "check-commit-format.sh: 'core' scope touching a registered file was incorrectly accepted"
else
    ok "check-commit-format.sh: rejects 'core' scope when the commit also touches a registered file"
fi
# shellcheck disable=SC2015
grep -q "also touches a registered file" /tmp/wb-commit-core-reg.log \
    && ok "check-commit-format.sh: rejection message explains the 'core'-scope rule" \
    || fail "check-commit-format.sh: rejection message missing the 'core'-scope explanation"

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 10b. check-commit-format.sh: a legitimate 'core'-scoped commit touching no
#      registered file must still pass.
(
    cd "${FIXTURE}" || exit 1
    echo "# a real product-level decision" >> README-placeholder.md
    git add -A
    git commit -q -m "feat(core): a product-level decision with no file of its own"
)
HEAD_D55_OK="$(cd "${FIXTURE}" && git rev-parse HEAD)"
if bash "${RELEASE_DIR}/check-commit-format.sh" "${BASE_D55}" "${HEAD_D55_OK}" >/dev/null 2>&1; then
    ok "check-commit-format.sh: a legitimate 'core' scope touching no registered file still passes"
else
    fail "check-commit-format.sh: a legitimate 'core' scope was incorrectly rejected"
fi

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

# 10c. check-pr-title-format.sh: same rule, evaluated against the PR's
#      overall diff — the squash commit only ever carries the title's scope.
export WORKBENCH_RELEASE_TEST_REPO_ROOT="${FIXTURE}"
REPO_ROOT="${FIXTURE}"

(
    cd "${FIXTURE}" || exit 1
    echo "# change" >> lib/other/widget.sh
    git add -A
    git commit -q -m "chore: commit message irrelevant here — the PR title drives the squash commit"
)
HEAD_D55_TITLE_BAD="$(cd "${FIXTURE}" && git rev-parse HEAD)"
if bash "${RELEASE_DIR}/check-pr-title-format.sh" "feat(core): should have been scoped to widget.sh" "${BASE_D55}" "${HEAD_D55_TITLE_BAD}" >/tmp/wb-pr-title-core-reg.log 2>&1; then
    fail "check-pr-title-format.sh: 'core'-scoped title touching a registered file was incorrectly accepted"
else
    ok "check-pr-title-format.sh: rejects a 'core'-scoped title when the PR also touches a registered file"
fi
# shellcheck disable=SC2015
grep -q "also touches a registered file" /tmp/wb-pr-title-core-reg.log \
    && ok "check-pr-title-format.sh: rejection message explains the 'core'-scope rule" \
    || fail "check-pr-title-format.sh: rejection message missing the 'core'-scope explanation"

(
    cd "${FIXTURE}" || exit 1
    git checkout -q -B main v1.0.0
)

if bash "${RELEASE_DIR}/check-pr-title-format.sh" "feat(core): a product-level decision with no file of its own" "${BASE_D55}" "${BASE_D55}" >/dev/null 2>&1; then
    ok "check-pr-title-format.sh: a legitimate 'core'-scoped title with an empty diff still passes"
else
    fail "check-pr-title-format.sh: a legitimate 'core'-scoped title was incorrectly rejected"
fi

if bash "${RELEASE_DIR}/check-pr-title-format.sh" "feat: add a thing" >/dev/null 2>&1; then
    ok "check-pr-title-format.sh: omitting base/head still validates grammar only (backward compatible)"
else
    fail "check-pr-title-format.sh: omitting base/head broke the existing grammar-only call path"
fi

# 10d. check-pr-title-format.sh: exactly one of base-sha/head-sha given is a
#      caller misconfiguration and must fail loudly, not silently downgrade
#      to grammar-only (Copilot review finding on PR #62).
if bash "${RELEASE_DIR}/check-pr-title-format.sh" "feat(core): a product-level decision with no file of its own" "${BASE_D55}" >/tmp/wb-pr-title-partial-args.log 2>&1; then
    fail "check-pr-title-format.sh: base-sha with no head-sha was incorrectly accepted"
else
    ok "check-pr-title-format.sh: rejects base-sha given without head-sha"
fi
# shellcheck disable=SC2015
grep -q "requires both" /tmp/wb-pr-title-partial-args.log \
    && ok "check-pr-title-format.sh: partial-args rejection message explains the requirement" \
    || fail "check-pr-title-format.sh: partial-args rejection message missing"

# 10e. check-pr-title-format.sh: a failed 'git diff' (unreachable SHA) must
#      fail loudly rather than being treated as an empty, no-registered-file
#      diff (Copilot review finding on PR #62).
if bash "${RELEASE_DIR}/check-pr-title-format.sh" "feat(core): a product-level decision with no file of its own" "${BASE_D55}" "0000000000000000000000000000000000000000" >/tmp/wb-pr-title-bad-diff.log 2>&1; then
    fail "check-pr-title-format.sh: an unreachable head-sha was incorrectly accepted"
else
    ok "check-pr-title-format.sh: rejects an unreachable head-sha instead of silently treating it as an empty diff"
fi
# shellcheck disable=SC2015
grep -q "could not diff" /tmp/wb-pr-title-bad-diff.log \
    && ok "check-pr-title-format.sh: unreachable-sha rejection message explains the diff failure" \
    || fail "check-pr-title-format.sh: unreachable-sha rejection message missing"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
