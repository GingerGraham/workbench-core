#!/usr/bin/env bash
# tests/check-release-bump.sh — acceptance check for the release pipeline's
# bump arithmetic, Conventional Commit scope resolution, and CHANGELOG
# gate/rewrite (.github/scripts/release/). ARCHITECTURE.md §12 D27.
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

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
