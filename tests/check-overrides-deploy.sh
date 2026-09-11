#!/usr/bin/env bash
# tests/check-overrides-deploy.sh — ARCHITECTURE.md §12 D48 acceptance
# check for overrides_src: create-once deploy to
# ~/.config/workbench/local/overrides/<module-name>.sh, engine-computed
# destination (no dest field exists to validate), and the specific
# behaviour this field exists for — a later manifest change to
# overrides_src's content must never touch a file that already exists on
# disk from a previous deploy.
#
# Unit-level, not a full fetch/resolve cycle (tests/check-sync-engine-
# isolation.sh covers that around the ordinary deploy[] path already) —
# this constructs a module's "current" snapshot directly and calls
# workbench_deploy_module() against it, since overrides_src's behaviour
# is entirely within that one function.
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

DEST="${XDG_CONFIG_HOME}/workbench/local/overrides/acme-widget.sh"

# ── 1. First deploy: overrides_src is copied to the engine-computed path ──
CURRENT="$(workbench_module_current_dir acme-widget)"
mkdir -p "${CURRENT}/shell"
cat > "${CURRENT}/shell/overrides.sh" <<'EOF'
# export ACME_THEME="default"
EOF
cat > "${CURRENT}/workbench.yml" <<'EOF'
version: 2
overrides_src: shell/overrides.sh
EOF

workbench_deploy_module acme-widget >/tmp/overrides-deploy-1.log 2>&1

if [[ -f "${DEST}" ]] && grep -q 'ACME_THEME' "${DEST}"; then
    ok "overrides_src is deployed to \${XDG_CONFIG_HOME}/workbench/local/overrides/<name>.sh on first sync"
else
    fail "overrides_src was not deployed to the expected engine-computed path"
    cat /tmp/overrides-deploy-1.log
fi

# ── 2. A module without overrides_src deploys nothing — no blank
#    placeholder, no file, ever, until the module declares one. ──────────
mkdir -p "$(workbench_module_current_dir plain-widget)"
cat > "$(workbench_module_current_dir plain-widget)/workbench.yml" <<'EOF'
version: 2
EOF
workbench_deploy_module plain-widget >/tmp/overrides-deploy-2.log 2>&1
PLAIN_DEST="${XDG_CONFIG_HOME}/workbench/local/overrides/plain-widget.sh"
if [[ ! -e "${PLAIN_DEST}" ]]; then
    ok "a module with no overrides_src deploys no file — no blank placeholder is ever created"
else
    fail "a file was created for a module with no overrides_src: ${PLAIN_DEST}"
fi

# ── 3. Simulate an edit to the deployed file, then re-sync with the
#    module's overrides_src content changed upstream — the existing file
#    must survive untouched (force: false, no escape hatch). ────────────
cat > "${DEST}" <<'EOF'
export ACME_THEME="my-custom-theme"
EOF

cat > "${CURRENT}/shell/overrides.sh" <<'EOF'
# export ACME_THEME="a-newer-default-from-the-module"
# export ACME_NEW_KNOB="added-later"
EOF

workbench_deploy_module acme-widget >/tmp/overrides-deploy-3.log 2>&1

if grep -q 'my-custom-theme' "${DEST}" && ! grep -q 'ACME_NEW_KNOB' "${DEST}"; then
    ok "a re-sync never overwrites an already-deployed overrides file, even when overrides_src's content changed upstream"
else
    fail "the existing overrides file was overwritten by a re-sync"
    cat "${DEST}"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
