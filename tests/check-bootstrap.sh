#!/usr/bin/env bash
# tests/check-bootstrap.sh — bootstrap-fix brief §6 item 8 acceptance check.
#
# bootstrap.sh talks to api.github.com/codeload.github.com directly — it
# cannot depend on lib/ (that's the whole point of the file), so unlike
# most of this suite there is no local-bare-git-repo fixture to redirect it
# at (that trick relies on PRIVATE=true routing through
# lib/distribution/fetch-git-snapshot.sh's git-ls-remote path, which
# bootstrap.sh deliberately never uses at all). Instead this stubs `curl`
# on PATH with a fixture dispatcher keyed on the requested URL, and points
# the fetched tarball at a minimal fixture tree with a stub bin/wb — this
# keeps the suite hermetic (no real network, no real git, no real
# sudo/apt/ansible from a full `wb install` run) while still exercising
# bootstrap.sh's actual resolution/fetch/sync.conf logic unmodified.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BOOTSTRAP="${REPO_ROOT}/bootstrap.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── Fixture: a minimal fake workbench-core tree with a stub bin/wb ─────────
# Deliberately NOT the real repo tree — bootstrap.sh's own correctness
# (steps 1-5: idempotency check, ref resolution, fetch-into-real-snapshot,
# sync.conf write) is this test's whole scope; a full `wb install` run
# (prereqs, ansible, ssh) is already exercised by the rest of this suite
# and would otherwise pull sudo/apt/network into what should be a hermetic
# check of bootstrap.sh alone.
FIXTURE_SRC="${WORK}/fixture-src/workbench-core-testref"
mkdir -p "${FIXTURE_SRC}/bin"
cat > "${FIXTURE_SRC}/bin/wb" <<'EOF'
#!/usr/bin/env bash
echo "wb-stub: invoked with: $*" >&2
exit 0
EOF
chmod +x "${FIXTURE_SRC}/bin/wb"
echo "v9.9.9-fixture" > "${FIXTURE_SRC}/VERSION"

MOCK_TARBALL="${WORK}/mock.tar.gz"
tar -czf "${MOCK_TARBALL}" -C "${WORK}/fixture-src" workbench-core-testref

MAIN_SHA="3333333333333333333333333333333333333333"
cat > "${WORK}/commits-main.json" <<EOF
{"sha":"${MAIN_SHA}","commit":{"tree":{"sha":"4444444444444444444444444444444444444444"}}}
EOF

echo "[]" > "${WORK}/tags-empty.json"

# Deliberately mixed set: v1.9.0 vs v1.10.0 is the naive-lexical-sort trap
# ("9" > "1" as a bare string compare would wrongly pick v1.9.0); v1.10.0
# is the correct numeric winner. v1.10.0-rc1 is a pre-release and must be
# excluded from `latest` resolution entirely (ARCHITECTURE.md §9.2).
cat > "${WORK}/tags-mixed.json" <<'EOF'
[
  {"name":"v1.10.0-rc1","commit":{"sha":"1111111111111111111111111111111111111111"}},
  {"name":"v1.9.0","commit":{"sha":"2222222222222222222222222222222222222222"}},
  {"name":"v1.10.0","commit":{"sha":"5555555555555555555555555555555555555555"}}
]
EOF

# ── Mock curl on PATH ────────────────────────────────────────────────────────
MOCK_BIN="${WORK}/mockbin"
mkdir -p "${MOCK_BIN}"
cat > "${MOCK_BIN}/curl" <<MOCKCURL
#!/usr/bin/env bash
# Mock curl for check-bootstrap.sh: dispatches on the requested URL,
# reading fixture files named by env vars this test sets before invoking
# bootstrap.sh. Real bootstrap.sh call shapes only: "-fsSL -H <v> -A <v>
# <url>" (API, stdout) and "-fsSL <url> -o <file>" (tarball fetch).
url=""
outfile=""
args=("\$@")
i=0
while [[ \${i} -lt \${#args[@]} ]]; do
    case "\${args[\${i}]}" in
        -o) i=\$((i + 1)); outfile="\${args[\${i}]}" ;;
        -H|-A) i=\$((i + 1)) ;;
        -*) ;;
        *) url="\${args[\${i}]}" ;;
    esac
    i=\$((i + 1))
done

case "\${url}" in
    */codeload.github.com/*)
        # Checked first: a codeload tarball URL for a tag ref
        # (.../tar.gz/refs/tags/vX.Y.Z) also contains the substring "tags",
        # so this must not fall through to the tags-list pattern below.
        cp "\${MOCK_TARBALL}" "\${outfile}"
        ;;
    */repos/*/tags*)
        cat "\${MOCK_TAGS_JSON}"
        ;;
    */commits/main)
        cat "\${MOCK_MAIN_JSON}"
        ;;
    *)
        echo "mock curl: unhandled URL: \${url}" >&2
        exit 1
        ;;
esac
MOCKCURL
chmod +x "${MOCK_BIN}/curl"
export MOCK_TARBALL

run_bootstrap() {
    # Real tar (fixture extraction needs it) + mock curl, prepended so the
    # mock wins over any real curl later in PATH.
    env PATH="${MOCK_BIN}:${PATH}" \
        HOME="${1}" XDG_DATA_HOME="${1}/data" \
        MOCK_TAGS_JSON="${2}" MOCK_MAIN_JSON="${WORK}/commits-main.json" \
        bash "${BOOTSTRAP}"
}

# ── 1. No-tag fallback to `main` ────────────────────────────────────────────
H1="${WORK}/home1"; mkdir -p "${H1}"
OUT1="$(run_bootstrap "${H1}" "${WORK}/tags-empty.json" 2>&1)"
MODULE_DIR1="${H1}/data/workbench/modules/core"

if echo "${OUT1}" | grep -q "falling back to 'main'"; then
    ok "no-tag fallback: bootstrap.sh warns and falls back to main"
else
    fail "no-tag fallback: expected a 'falling back to main' warning"
    echo "${OUT1}"
fi

if [[ -f "${MODULE_DIR1}/sync.conf" ]] && grep -q '^TRACK_MODE=latest$' "${MODULE_DIR1}/sync.conf" && grep -q '^TRACK_REF=main$' "${MODULE_DIR1}/sync.conf"; then
    ok "no-tag fallback: sync.conf records TRACK_MODE=latest, TRACK_REF=main"
else
    fail "no-tag fallback: sync.conf missing or has unexpected TRACK_MODE/TRACK_REF"
fi

if grep -q "^RESOLVED_SHA=${MAIN_SHA}\$" "${MODULE_DIR1}/sync.conf" 2>/dev/null; then
    ok "no-tag fallback: RESOLVED_SHA is the real resolved sha, not a placeholder"
else
    fail "no-tag fallback: RESOLVED_SHA missing or not the expected real sha"
    cat "${MODULE_DIR1}/sync.conf" 2>/dev/null
fi

# ── 2. Resolves the latest tag correctly when one exists ───────────────────
H2="${WORK}/home2"; mkdir -p "${H2}"
OUT2="$(run_bootstrap "${H2}" "${WORK}/tags-mixed.json" 2>&1)"
MODULE_DIR2="${H2}/data/workbench/modules/core"

if echo "${OUT2}" | grep -q "resolved release: v1.10.0 "; then
    ok "tag resolution: picked v1.10.0 (numeric highest), not v1.9.0 (lexical trap) or the rc pre-release"
else
    fail "tag resolution: did not resolve to v1.10.0 as expected"
    echo "${OUT2}"
fi

if grep -q '^TRACK_REF=v1.10.0$' "${MODULE_DIR2}/sync.conf" 2>/dev/null \
    && grep -q '^RESOLVED_SHA=5555555555555555555555555555555555555555$' "${MODULE_DIR2}/sync.conf" 2>/dev/null; then
    ok "tag resolution: sync.conf records the correct TRACK_REF and RESOLVED_SHA for v1.10.0"
else
    fail "tag resolution: sync.conf does not reflect v1.10.0's ref/sha"
    cat "${MODULE_DIR2}/sync.conf" 2>/dev/null
fi

EXPECT_SNAP2="${MODULE_DIR2}/snapshots/v1.10.0-5555555"
if [[ -d "${EXPECT_SNAP2}" ]]; then
    ok "tag resolution: snapshot directory name matches <ref-slug>-<shortsha> (v1.10.0-5555555)"
else
    fail "tag resolution: expected snapshot dir ${EXPECT_SNAP2} not found"
    find "${MODULE_DIR2}/snapshots" -maxdepth 1 2>/dev/null
fi

# ── 3. `current` is a real directory under snapshots/, never /tmp ──────────
if [[ -L "${MODULE_DIR2}/current" ]]; then
    TARGET="$(readlink "${MODULE_DIR2}/current")"
    case "${TARGET}" in
        "${MODULE_DIR2}/snapshots/"*)
            if [[ -d "${TARGET}" && ! -L "${TARGET}" ]]; then
                ok "current is a symlink to a real directory under snapshots/ (${TARGET})"
            else
                fail "current's target is not a real, non-symlink directory: ${TARGET}"
            fi
            ;;
        /tmp/*|"${TMPDIR:-/tmp}"/*)
            fail "current points into a scratch/tmp path: ${TARGET}"
            ;;
        *)
            fail "current points outside snapshots/: ${TARGET}"
            ;;
    esac
else
    fail "current is not a symlink at all: $(ls -la "${MODULE_DIR2}/current" 2>&1)"
fi

# ── 4. Re-running bootstrap.sh is idempotent — hands off, does not re-fetch ─
BEFORE_COUNT="$(find "${MODULE_DIR2}/snapshots" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
OUT3="$(run_bootstrap "${H2}" "${WORK}/tags-mixed.json" 2>&1)"
AFTER_COUNT="$(find "${MODULE_DIR2}/snapshots" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

if echo "${OUT3}" | grep -q "already bootstrapped"; then
    ok "idempotency: re-running bootstrap.sh recognises the existing install and skips re-fetching"
else
    fail "idempotency: re-run did not report 'already bootstrapped'"
    echo "${OUT3}"
fi

if [[ "${BEFORE_COUNT}" -eq "${AFTER_COUNT}" ]]; then
    ok "idempotency: snapshot count unchanged by the re-run (${BEFORE_COUNT})"
else
    fail "idempotency: snapshot count changed on re-run (${BEFORE_COUNT} -> ${AFTER_COUNT}) — bootstrap.sh re-fetched"
fi

if echo "${OUT3}" | grep -q "wb-stub: invoked with: install"; then
    ok "idempotency: re-run hands off to bin/wb install"
else
    fail "idempotency: re-run did not hand off to bin/wb install"
    echo "${OUT3}"
fi

# ── 5. No `git` invoked anywhere in bootstrap.sh ────────────────────────────
# Unlike check-distribution-no-git.sh's target file, bootstrap.sh
# legitimately writes a REPO_URL ending in ".git" into sync.conf (data, not
# an invocation) — the boundary here additionally excludes a preceding '.'
# so that literal doesn't false-positive as a git command token.
if grep -vE '^[[:space:]]*#' "${BOOTSTRAP}" | grep -qE '(^|[^a-zA-Z0-9_.-])git([^a-zA-Z0-9_.-]|$)'; then
    fail "bootstrap.sh contains a literal 'git' token outside comments"
else
    ok "bootstrap.sh's source contains no 'git' invocation at all"
fi

CLEAN_BIN="${WORK}/clean-bin"
mkdir -p "${CLEAN_BIN}"
IFS=':' read -r -a _path_dirs <<< "${PATH}"
for d in "${_path_dirs[@]}"; do
    [[ -d "${d}" ]] || continue
    for f in "${d}"/*; do
        [[ -e "${f}" ]] || continue
        b="$(basename "${f}")"
        # git is excluded (that's the point of this check); curl is
        # excluded too, so the mock below can be written into a path that
        # never pointed at the real curl binary — `cp` onto an existing
        # symlink follows it and would otherwise overwrite the real
        # binary's target in place.
        [[ "${b}" == "git" || "${b}" == git-* || "${b}" == "curl" ]] && continue
        [[ -e "${CLEAN_BIN}/${b}" ]] && continue
        ln -s "${f}" "${CLEAN_BIN}/${b}" 2>/dev/null || true
    done
done
cp "${MOCK_BIN}/curl" "${CLEAN_BIN}/curl"

H4="${WORK}/home4"; mkdir -p "${H4}"
if env -i PATH="${CLEAN_BIN}" HOME="${H4}" XDG_DATA_HOME="${H4}/data" \
    MOCK_TAGS_JSON="${WORK}/tags-mixed.json" MOCK_MAIN_JSON="${WORK}/commits-main.json" MOCK_TARBALL="${MOCK_TARBALL}" \
    bash "${BOOTSTRAP}" >"${WORK}/no-git-run.log" 2>&1; then
    ok "bootstrap.sh runs to completion with git entirely absent from PATH"
else
    fail "bootstrap.sh failed with git absent from PATH"
    cat "${WORK}/no-git-run.log"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
