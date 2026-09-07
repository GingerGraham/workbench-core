#!/usr/bin/env bash
# tests/check-version-file-sync.sh — ARCHITECTURE.md §12 D36/D37
# acceptance check.
#
# Reproduces the confirmed regression: a version file written by an older
# core release (CORE_API_VERSION frozen below what the currently-running
# release declares) must be unconditionally corrected by
# _workbench_sync_version_facts on every wb install/apply — not left for a
# manual edit. Also checks the dead MANIFEST_SCHEMA_VERSION field is
# stripped from an existing file, and that STATE_SCHEMA_VERSION's own
# migration semantics are untouched by this change.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
export XDG_CACHE_HOME="${WORK}/cache"
mkdir -p "${HOME}"

WB="${REPO_ROOT}/bin/wb"
VERSION_FILE="${XDG_CONFIG_HOME}/workbench/core/version"

# ── Precondition: a pre-D29/D34 version file, exactly as a real frozen
#    host would have it — bare CORE_API_VERSION, dead MANIFEST_SCHEMA_VERSION
#    still present, STATE_SCHEMA_VERSION already current. ──────────────────
mkdir -p "$(dirname "${VERSION_FILE}")"
cat > "${VERSION_FILE}" <<'EOF'
CORE_API_VERSION=1
MANIFEST_SCHEMA_VERSION=1
STATE_SCHEMA_VERSION=2
WORKBENCH_CORE_SEMVER=0.1.0
EOF

# shellcheck source=bin/wb
source "${WB}" >/tmp/wb-version-sync-source.log 2>&1

_workbench_sync_version_facts

if grep -q '^CORE_API_VERSION=1\.1$' "${VERSION_FILE}"; then
    ok "CORE_API_VERSION synced from frozen '1' to current '1.1'"
else
    fail "CORE_API_VERSION not synced — got: $(grep '^CORE_API_VERSION=' "${VERSION_FILE}")"
fi

if grep -q '^MANIFEST_SCHEMA_VERSION=' "${VERSION_FILE}"; then
    fail "MANIFEST_SCHEMA_VERSION still present — should be retired"
else
    ok "MANIFEST_SCHEMA_VERSION removed from the file"
fi

if grep -q '^STATE_SCHEMA_VERSION=2$' "${VERSION_FILE}"; then
    ok "STATE_SCHEMA_VERSION untouched by this change"
else
    fail "STATE_SCHEMA_VERSION unexpectedly changed"
fi

# ── Idempotency: a second call on an already-current file is a clean no-op ─
BEFORE_MTIME="$(stat -c %Y "${VERSION_FILE}" 2>/dev/null || stat -f %m "${VERSION_FILE}")"
sleep 1
_workbench_sync_version_facts
AFTER_MTIME="$(stat -c %Y "${VERSION_FILE}" 2>/dev/null || stat -f %m "${VERSION_FILE}")"
if [[ "${BEFORE_MTIME}" == "${AFTER_MTIME}" ]]; then
    ok "second call on an already-current file did not rewrite it"
else
    fail "second call rewrote an already-current file — should be a no-op"
fi

# ── A brand-new host (_workbench_ensure_version_file's own path) never
#    writes the dead field and starts at the current value already. ────────
rm -f "${VERSION_FILE}"
_workbench_ensure_version_file
if grep -q '^MANIFEST_SCHEMA_VERSION=' "${VERSION_FILE}"; then
    fail "fresh bootstrap still writes dead MANIFEST_SCHEMA_VERSION field"
else
    ok "fresh bootstrap does not write MANIFEST_SCHEMA_VERSION"
fi
if grep -q '^CORE_API_VERSION=1\.1$' "${VERSION_FILE}"; then
    ok "fresh bootstrap starts at current CORE_API_VERSION"
else
    fail "fresh bootstrap did not start at current CORE_API_VERSION"
fi

# ── End-to-end: a full `wb apply` on the frozen-host precondition actually
#    unblocks a module's registration (the real-world symptom). ───────────
cat > "${VERSION_FILE}" <<'EOF'
CORE_API_VERSION=1
MANIFEST_SCHEMA_VERSION=1
STATE_SCHEMA_VERSION=2
WORKBENCH_CORE_SEMVER=0.1.0
EOF
_wb_cmd_apply --skip-ansible >/tmp/wb-version-sync-apply.log 2>&1 || true
if grep -q '^CORE_API_VERSION=1\.1$' "${VERSION_FILE}"; then
    ok "'wb apply' (via _wb_cmd_apply) syncs CORE_API_VERSION end-to-end"
else
    fail "'wb apply' did not sync CORE_API_VERSION — see /tmp/wb-version-sync-apply.log"
fi

echo
echo "== ${check_no} checks, ${FAILED} failed =="
exit "${FAILED}"
