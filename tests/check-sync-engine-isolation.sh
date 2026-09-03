#!/usr/bin/env bash
# tests/check-sync-engine-isolation.sh — Phase 5 acceptance check for
# lib/sync/engine.sh: module-zero equivalence, correct fetch/resolve/deploy
# across TRACK_MODE transitions, idempotent re-sync, and the resilience
# guarantee that one module's failure never aborts another's sync.
#
# Uses local bare git repos (via `git ls-remote`/shallow-clone over a plain
# filesystem path — no SSH, no network) to exercise the private/dev
# resolution+fetch path fully self-contained. The public (GitHub API +
# codeload) path is covered live by tests/check-distribution-no-git.sh and
# unit-level tests in tests/check-semver-comparator.sh; this file focuses on
# the engine's orchestration logic, which is identical for both paths.
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

# ── Build a source repo (bare) with a manifest, two clean tags, and a
#    feature branch ──────────────────────────────────────────────────────
SRC="${WORK}/src"
BARE="${WORK}/bare.git"
mkdir -p "${SRC}"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}"
(
    cd "${SRC}"
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    echo 'get-widget-functions() { :; }' > shell/widget.sh
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
deploy:
  - src: shell/widget.sh
    dest: ~/.local/share/wb-test/widget.sh
    mode: link
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/widget.sh
      tier: tools
EOF
    git add -A && git commit -q -m "v1"
    git branch -M main
    git push -q origin main
    git tag v1.0.0
    git push -q origin v1.0.0
    echo "v1.1 content" >> shell/widget.sh
    git add -A && git commit -q -m "v1.1"
    git tag v1.1.0
    git push -q origin main v1.1.0
    git checkout -q -b my-feature
    echo "feature wip" >> shell/widget.sh
    git add -A && git commit -q -m "feature wip"
    git push -q origin my-feature
)

# ── Register two modules: "core" (tracking latest, private=true so
#    resolution uses ls-remote against our local bare repo) and a second,
#    unrelated-named module "widgetco" tracking the same repo's
#    my-feature branch — proves module zero and an ordinary module go
#    through the identical code path. ─────────────────────────────────────
setup_module() {
    local name="$1" mode="$2" repo_url="${3:-${BARE}}"
    mkdir -p "$(workbench_module_dir "${name}")"
    cat > "$(workbench_module_conf_path "${name}")" <<EOF
REPO_URL=${repo_url}
PRIVATE=true
TRACK_MODE=${mode}
REGISTERED=true
SYNC_ENABLED=true
ALLOW_HOOKS=false
EOF
}
setup_module core latest
setup_module widgetco "branch:my-feature"

# ── 1. First sync: core (latest) resolves to v1.1.0, deploys correctly. ───
workbench_sync_module core >/tmp/wb-sync-core.log 2>&1
if [[ -f "${HOME}/.local/share/wb-test/widget.sh" ]] && grep -q "v1.1 content" "${HOME}/.local/share/wb-test/widget.sh"; then
    ok "core: first sync resolved latest (v1.1.0) and deployed its content"
else
    fail "core: first sync did not deploy expected v1.1.0 content"
    cat /tmp/wb-sync-core.log
fi

resolved="$(workbench_module_conf_get core RESOLVED_SHA "")"
# shellcheck disable=SC2015
[[ -n "${resolved}" ]] && ok "core: RESOLVED_SHA persisted after first sync" || fail "core: RESOLVED_SHA not persisted"

if [[ -f "$(workbench_module_dir core)/register.list" ]] && grep -q "widget.sh|tools" "$(workbench_module_dir core)/register.list"; then
    ok "core: register.list rendered from its own manifest, exactly like any other module would be"
else
    fail "core: register.list not rendered correctly"
fi

# ── 2. Re-sync with nothing changed upstream: no new snapshot created. ─────
before_count=$(find "$(workbench_module_dir core)/snapshots" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
workbench_sync_module core >/tmp/wb-sync-core2.log 2>&1
after_count=$(find "$(workbench_module_dir core)/snapshots" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
if [[ "${before_count}" -eq "${after_count}" ]]; then
    ok "core: re-sync with no upstream change created no new snapshot (idempotent)"
else
    fail "core: re-sync with no change created a new snapshot anyway (${before_count} -> ${after_count})"
fi
# shellcheck disable=SC2015
grep -q "up to date" /tmp/wb-sync-core2.log && ok "core: re-sync logged 'up to date'" || fail "core: re-sync did not report up to date"

# ── 3. A new tag lands upstream (v1.2.0): re-sync picks it up. ─────────────
(
    cd "${SRC}"
    echo "v1.2 content" >> shell/widget.sh
    git add -A && git commit -q -m "v1.2"
    git tag v1.2.0
    git push -q origin main v1.2.0
)
workbench_sync_module core >/tmp/wb-sync-core3.log 2>&1
if grep -q "v1.2 content" "${HOME}/.local/share/wb-test/widget.sh"; then
    ok "core: a new upstream tag (v1.2.0) is picked up and deployed on the next sync"
else
    fail "core: new tag v1.2.0 was not deployed"
    cat /tmp/wb-sync-core3.log
fi

# ── 4. widgetco (branch:my-feature) resolves and deploys the feature
#    branch's own content — proves TRACK_MODE=branch: works and that an
#    ordinary module goes through the exact same functions core just did. ──
workbench_sync_module widgetco >/tmp/wb-sync-widgetco.log 2>&1
if [[ -d "$(workbench_module_current_dir widgetco)" ]] && grep -q "feature wip" "$(workbench_module_current_dir widgetco)/shell/widget.sh"; then
    ok "widgetco (branch:my-feature): resolved and fetched the feature branch's own content"
else
    fail "widgetco: branch tracking did not fetch expected content"
    cat /tmp/wb-sync-widgetco.log
fi

# ── 5. Isolation: a broken module (bad REPO_URL) alongside a healthy one —
#    workbench_sync_all must still sync the healthy one and report failure
#    only for the broken one. ──────────────────────────────────────────────
mkdir -p "$(workbench_module_dir broken-module)"
cat > "$(workbench_module_conf_path broken-module)" <<EOF
REPO_URL=/nonexistent/path/does-not-exist.git
PRIVATE=true
TRACK_MODE=latest
REGISTERED=true
SYNC_ENABLED=true
EOF

# A genuinely new upstream change for "core", so workbench_sync_all has real
# work to do for it (a bare "up to date" cycle wouldn't distinguish
# isolation working from deploy simply being skipped as a no-op).
(
    cd "${SRC}"
    echo "v1.3 content" >> shell/widget.sh
    git add -A && git commit -q -m "v1.3"
    git tag v1.3.0
    git push -q origin main v1.3.0
)

failures=0
workbench_sync_all "test" >/tmp/wb-sync-all.log 2>&1 || failures=$?

if [[ "${failures}" -ge 1 ]]; then
    ok "workbench_sync_all reports at least one failure (the broken module)"
else
    fail "workbench_sync_all did not report the broken module's failure"
fi
if [[ -f "${HOME}/.local/share/wb-test/widget.sh" ]] && grep -q "v1.3 content" "${HOME}/.local/share/wb-test/widget.sh"; then
    ok "workbench_sync_all still synced/deployed the healthy modules' new content despite the broken one"
else
    fail "the broken module's failure prevented the healthy modules from syncing — isolation broken"
    cat /tmp/wb-sync-all.log
fi

# ── 6. Unsupported manifest version: workbench_sync_module refuses to sync
#    a module declaring a version: this core doesn't know how to process
#    (ARCHITECTURE.md §12 D30) — deploy and register both skipped, and an
#    unrelated healthy module in the same workbench_sync_all run still
#    succeeds. ─────────────────────────────────────────────────────────────
BADSRC="${WORK}/badsrc"
BADBARE="${WORK}/badsrc-bare.git"
mkdir -p "${BADSRC}"
git init -q --bare "${BADBARE}"
git clone -q "${BADBARE}" "${BADSRC}"
(
    cd "${BADSRC}"
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    echo 'get-badversion-functions() { :; }' > shell/badversion.sh
    cat > .dotfiles-sync.yml <<'EOF'
version: 2
branch: main
deploy:
  - src: shell/badversion.sh
    dest: ~/.local/share/wb-test/badversion.sh
    mode: link
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/badversion.sh
      tier: tools
EOF
    git add -A && git commit -q -m "v1"
    git branch -M main
    git push -q origin main
    git tag v1.0.0
    git push -q origin v1.0.0
)
setup_module badversion latest "${BADBARE}"

badversion_rc=0
workbench_sync_module badversion >/tmp/wb-sync-badversion.log 2>&1 || badversion_rc=$?
if [[ "${badversion_rc}" -ne 0 ]]; then
    ok "badversion: workbench_sync_module returned non-zero for an unsupported manifest version"
else
    fail "badversion: workbench_sync_module returned success for an unsupported manifest version"
fi
# shellcheck disable=SC2015
grep -q "this core only supports schema version" /tmp/wb-sync-badversion.log && ok "badversion: refusal logged the expected message" || fail "badversion: expected refusal message not logged"
if [[ ! -f "$(workbench_module_dir badversion)/register.list" ]]; then
    ok "badversion: register.list was not written"
else
    fail "badversion: register.list was written despite the unsupported version"
fi
if [[ ! -e "${HOME}/.local/share/wb-test/badversion.sh" ]]; then
    ok "badversion: deploy destination was not touched"
else
    fail "badversion: deploy destination was created despite the unsupported version"
fi

# A manifest missing the (required, contracts/manifest-spec.md §Field
# reference) version: field entirely must be refused the same way as an
# explicitly unsupported one — the gate must not silently pass an absent
# value through as "no opinion".
NOVERSRC="${WORK}/noversrc"
NOVERBARE="${WORK}/noversrc-bare.git"
mkdir -p "${NOVERSRC}"
git init -q --bare "${NOVERBARE}"
git clone -q "${NOVERBARE}" "${NOVERSRC}"
(
    cd "${NOVERSRC}"
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    echo 'get-noversion-functions() { :; }' > shell/noversion.sh
    cat > .dotfiles-sync.yml <<'EOF'
branch: main
deploy:
  - src: shell/noversion.sh
    dest: ~/.local/share/wb-test/noversion.sh
    mode: link
EOF
    git add -A && git commit -q -m "v1"
    git branch -M main
    git push -q origin main
    git tag v1.0.0
    git push -q origin v1.0.0
)
setup_module noversion latest "${NOVERBARE}"

noversion_rc=0
workbench_sync_module noversion >/tmp/wb-sync-noversion.log 2>&1 || noversion_rc=$?
if [[ "${noversion_rc}" -ne 0 ]]; then
    ok "noversion: workbench_sync_module returned non-zero for a manifest missing version:"
else
    fail "noversion: workbench_sync_module returned success for a manifest missing version:"
fi
if [[ ! -e "${HOME}/.local/share/wb-test/noversion.sh" ]]; then
    ok "noversion: deploy destination was not touched"
else
    fail "noversion: deploy destination was created despite the missing version:"
fi

# A genuinely new upstream change for "core" again, so this run has real
# work to do, then confirm it still syncs successfully alongside the
# unsupported-version module.
(
    cd "${SRC}"
    echo "v1.4 content" >> shell/widget.sh
    git add -A && git commit -q -m "v1.4"
    git tag v1.4.0
    git push -q origin main v1.4.0
)
workbench_sync_all "test" >/tmp/wb-sync-all2.log 2>&1 || true
if [[ -f "${HOME}/.local/share/wb-test/widget.sh" ]] && grep -q "v1.4 content" "${HOME}/.local/share/wb-test/widget.sh"; then
    ok "core: still syncs successfully in the same workbench_sync_all run as the unsupported-version module"
else
    fail "core: sync did not succeed alongside the unsupported-version module — isolation broken"
    cat /tmp/wb-sync-all2.log
fi

# ── 7. wb status contract: reading module state does no fetch/lock — a
#    read-only conf-get call must not itself perform network I/O. Verified
#    structurally: workbench_module_conf_get never calls resolve/fetch
#    functions. ───────────────────────────────────────────────────────────
if grep -vE '^[[:space:]]*#' "${REPO_ROOT}/lib/sync/state.sh" | grep -qE 'workbench_(resolve|fetch)_'; then
    fail "lib/sync/state.sh (read path) appears to call a resolve/fetch function"
else
    ok "lib/sync/state.sh's read path (workbench_module_conf_get etc.) contains no resolve/fetch calls — read-only, no-lock by construction"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
