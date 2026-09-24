#!/usr/bin/env bash
# tests/check-hook-consent.sh — docs/decisions-log.md D76 acceptance check
# (security review M1): post_deploy hook consent is bound to the commit the
# user approved, not granted forever by ALLOW_HOOKS=true alone.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
export HOME="${WORK}/home"
mkdir -p "${HOME}"

# shellcheck source=lib/sync/engine.sh
source "${REPO_ROOT}/lib/sync/engine.sh"

MARKER="${HOME}/hook-ran.log"

setup_module() {
    local name="$1" repo_url="$2"
    mkdir -p "$(workbench_module_dir "${name}")"
    cat > "$(workbench_module_conf_path "${name}")" <<EOF
REPO_URL=${repo_url}
PRIVATE=true
TRACK_MODE=branch:main
REGISTERED=true
SYNC_ENABLED=true
ALLOW_HOOKS=true
EOF
}

# ── Shared bare repo: run_on defaults to "changed" ──────────────────────────
BARE="${WORK}/bare.git"
SRC="${WORK}/src"
mkdir -p "${SRC}"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}"
(
    cd "${SRC}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p hooks
    cat > hooks/post-deploy.sh <<'EOF'
#!/usr/bin/env bash
echo "v1 ran for ${WORKBENCH_MODULE_NAME}" >> "${HOME}/hook-ran.log"
EOF
    chmod +x hooks/post-deploy.sh
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
core_api: ">=1.0 <2.0"
hooks:
  post_deploy:
    command: ["hooks/post-deploy.sh"]
    run_on: changed
    timeout: 60
EOF
    git add -A && git commit -q -m "v1"
    git branch -M main
    git push -q origin main
)
SHA1="$(git -C "${SRC}" rev-parse main)"

setup_module hooktest "${BARE}"

# ── 1. Sync with reason "add" → hook runs once; HOOKS_APPROVED_SHA = sha1 ──
workbench_sync_module hooktest add >/tmp/wb-hook-consent-1.log 2>&1
if [[ -f "${MARKER}" ]] && [[ "$(grep -c 'v1 ran' "${MARKER}")" -eq 1 ]]; then
    ok "reason=add: hook ran exactly once"
else
    fail "reason=add: hook did not run exactly once — see /tmp/wb-hook-consent-1.log"
    cat "${MARKER}" 2>/dev/null
fi
APPROVED1="$(workbench_module_conf_get hooktest HOOKS_APPROVED_SHA "")"
if [[ "${APPROVED1}" == "${SHA1}" ]]; then
    ok "reason=add: HOOKS_APPROVED_SHA = sha1"
else
    fail "reason=add: HOOKS_APPROVED_SHA is '${APPROVED1}', expected ${SHA1}"
fi

# ── 2. Push a commit changing the hook; sync with reason "scheduled" ───────
#    → hook not run; HOOKS_PENDING=true; approved still sha1.
(
    cd "${SRC}" || exit 1
    cat > hooks/post-deploy.sh <<'EOF'
#!/usr/bin/env bash
echo "v2 ran for ${WORKBENCH_MODULE_NAME}" >> "${HOME}/hook-ran.log"
EOF
    git add -A && git commit -q -m "v2: change the hook"
    git push -q origin main
)
SHA2="$(git -C "${SRC}" rev-parse main)"
workbench_sync_module hooktest scheduled >/tmp/wb-hook-consent-2.log 2>&1
if [[ "$(grep -c 'v2 ran' "${MARKER}" 2>/dev/null)" -eq 0 ]]; then
    ok "reason=scheduled: changed hook was not run"
else
    fail "reason=scheduled: changed hook ran despite no approval"
fi
PENDING2="$(workbench_module_conf_get hooktest HOOKS_PENDING false)"
if [[ "${PENDING2}" == "true" ]]; then
    ok "reason=scheduled: HOOKS_PENDING=true"
else
    fail "reason=scheduled: HOOKS_PENDING is '${PENDING2}', expected true"
fi
APPROVED2="$(workbench_module_conf_get hooktest HOOKS_APPROVED_SHA "")"
if [[ "${APPROVED2}" == "${SHA1}" ]]; then
    ok "reason=scheduled: HOOKS_APPROVED_SHA still sha1 (not advanced)"
else
    fail "reason=scheduled: HOOKS_APPROVED_SHA is '${APPROVED2}', expected still ${SHA1}"
fi

# ── 3. Sync with reason "manual" (no TTY in CI) → hook runs; approved=sha2 ─
workbench_sync_module hooktest manual >/tmp/wb-hook-consent-3.log 2>&1
if [[ "$(grep -c 'v2 ran' "${MARKER}" 2>/dev/null)" -eq 1 ]]; then
    ok "reason=manual: the pending, changed hook ran (no TTY, so no prompt blocks it)"
else
    fail "reason=manual: the pending hook did not run — see /tmp/wb-hook-consent-3.log"
    cat "${MARKER}" 2>/dev/null
fi
APPROVED3="$(workbench_module_conf_get hooktest HOOKS_APPROVED_SHA "")"
if [[ "${APPROVED3}" == "${SHA2}" ]]; then
    ok "reason=manual: HOOKS_APPROVED_SHA advanced to sha2"
else
    fail "reason=manual: HOOKS_APPROVED_SHA is '${APPROVED3}', expected ${SHA2}"
fi
PENDING3="$(workbench_module_conf_get hooktest HOOKS_PENDING false)"
if [[ "${PENDING3}" == "false" ]]; then
    ok "reason=manual: HOOKS_PENDING cleared back to false"
else
    fail "reason=manual: HOOKS_PENDING is '${PENDING3}', expected false"
fi

# ── 4. Migration: pre-D76 host state (RESOLVED_SHA set, no
#    HOOKS_APPROVED_SHA), run_on: always, scheduled, unchanged → hook runs;
#    HOOKS_APPROVED_SHA is now set (approved silently, no prompt). ─────────
MIGSHA="1234567890123456789012345678901234567890"
mkdir -p "$(workbench_module_dir "migtest")"
cat > "$(workbench_module_conf_path "migtest")" <<EOF
REPO_URL=${BARE}
PRIVATE=true
TRACK_MODE=latest
REGISTERED=true
SYNC_ENABLED=true
ALLOW_HOOKS=true
RESOLVED_SHA=${MIGSHA}
EOF
MIGCURRENT="$(workbench_module_current_dir migtest)"
mkdir -p "${MIGCURRENT}/hooks"
cat > "${MIGCURRENT}/hooks/post-deploy.sh" <<'EOF'
#!/usr/bin/env bash
echo "migration ran for ${WORKBENCH_MODULE_NAME}" >> "${HOME}/hook-ran.log"
EOF
chmod +x "${MIGCURRENT}/hooks/post-deploy.sh"
cat > "${MIGCURRENT}/.dotfiles-sync.yml" <<'EOF'
version: 1
branch: main
core_api: ">=1.0 <2.0"
hooks:
  post_deploy:
    command: ["hooks/post-deploy.sh"]
    run_on: always
    timeout: 60
EOF
workbench_run_post_deploy_hook migtest scheduled false false >/tmp/wb-hook-consent-4.log 2>&1
if [[ "$(grep -c 'migration ran' "${MARKER}" 2>/dev/null)" -eq 1 ]]; then
    ok "migration: pre-D76 host's first unchanged scheduled cycle runs the hook"
else
    fail "migration: hook did not run — see /tmp/wb-hook-consent-4.log"
    cat "${MARKER}" 2>/dev/null
fi
APPROVED4="$(workbench_module_conf_get migtest HOOKS_APPROVED_SHA "")"
if [[ "${APPROVED4}" == "${MIGSHA}" ]]; then
    ok "migration: HOOKS_APPROVED_SHA is now set to the current RESOLVED_SHA"
else
    fail "migration: HOOKS_APPROVED_SHA is '${APPROVED4}', expected ${MIGSHA}"
fi

# ── 5. ALLOW_HOOKS=false → never runs, no keys written ──────────────────────
mkdir -p "$(workbench_module_dir "offtest")"
cat > "$(workbench_module_conf_path "offtest")" <<EOF
REPO_URL=${BARE}
PRIVATE=true
TRACK_MODE=latest
REGISTERED=true
SYNC_ENABLED=true
ALLOW_HOOKS=false
RESOLVED_SHA=${MIGSHA}
EOF
OFFCURRENT="$(workbench_module_current_dir offtest)"
mkdir -p "${OFFCURRENT}/hooks"
cp "${MIGCURRENT}/hooks/post-deploy.sh" "${OFFCURRENT}/hooks/post-deploy.sh"
cp "${MIGCURRENT}/.dotfiles-sync.yml" "${OFFCURRENT}/.dotfiles-sync.yml"
BEFORE_MARKER_LINES="$(wc -l < "${MARKER}")"
workbench_run_post_deploy_hook offtest scheduled true true >/tmp/wb-hook-consent-5.log 2>&1
AFTER_MARKER_LINES="$(wc -l < "${MARKER}")"
if [[ "${BEFORE_MARKER_LINES}" -eq "${AFTER_MARKER_LINES}" ]]; then
    ok "ALLOW_HOOKS=false: hook never runs"
else
    fail "ALLOW_HOOKS=false: hook ran despite ALLOW_HOOKS=false"
fi
if [[ -z "$(workbench_module_conf_get offtest HOOKS_APPROVED_SHA "")" && -z "$(workbench_module_conf_get offtest HOOKS_PENDING "")" ]]; then
    ok "ALLOW_HOOKS=false: no HOOKS_APPROVED_SHA/HOOKS_PENDING keys written"
else
    fail "ALLOW_HOOKS=false: HOOKS_APPROVED_SHA/HOOKS_PENDING were written despite ALLOW_HOOKS=false"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
