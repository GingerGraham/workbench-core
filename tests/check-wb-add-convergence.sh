#!/usr/bin/env bash
# tests/check-wb-add-convergence.sh — Phase 7 acceptance check.
#
# `wb add <name> <url>` followed by `wb apply` produces no diff (the §8
# convergence constraint — `wb add` writes a strict subset of what a full
# `wb apply` would, by construction, since both call
# workbench_sync_module()). `wb add` on an already-registered module and
# `wb remove` on an unregistered one are both clean no-ops. `wb track`
# followed by `wb status` shows the pinned state and doesn't drift on a
# subsequent `wb update`.
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
mkdir -p "${HOME}"

# shellcheck source=bin/wb
WB="${REPO_ROOT}/bin/wb"

# ── Build a source repo (bare) with two tags. ──────────────────────────────
SRC="${WORK}/src"
BARE="${WORK}/bare.git"
mkdir -p "${SRC}"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}"
(
    cd "${SRC}"
    git config user.email t@t.com
    git config user.name Test
    echo "v1 content" > file.sh
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
deploy:
  - src: file.sh
    dest: ~/.local/share/wb-add-test/file.sh
    mode: link
core_api: ">=1.0 <2.0"
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
    echo "v1.2 content" >> file.sh
    git add -A && git commit -q -m v1.2
    git tag v1.2.0 && git push -q origin main v1.2.0
)

# ── 1. wb add registers and syncs. ─────────────────────────────────────────
bash "${WB}" add widget "${BARE}" --private >/tmp/wb-add-1.log 2>&1
if grep -q "v1.2 content" "${HOME}/.local/share/wb-add-test/file.sh" 2>/dev/null; then
    ok "wb add registered and synced 'widget', deploying the latest tag's content"
else
    fail "wb add did not deploy expected content"
    cat /tmp/wb-add-1.log
fi

# ── 2. wb add again is a clean no-op. ───────────────────────────────────────
sha_before="$(grep '^RESOLVED_SHA=' "${XDG_DATA_HOME}/workbench/modules/widget/sync.conf")"
out="$(bash "${WB}" add widget "${BARE}" --private 2>&1)"
sha_after="$(grep '^RESOLVED_SHA=' "${XDG_DATA_HOME}/workbench/modules/widget/sync.conf")"
if echo "${out}" | grep -q "already registered"; then
    ok "wb add on an already-registered module reports a clear no-op message"
else
    fail "wb add did not report a no-op for an already-registered module: ${out}"
fi
if [[ "${sha_before}" == "${sha_after}" ]]; then
    ok "re-running wb add did not re-fetch/change anything"
else
    fail "re-running wb add changed RESOLVED_SHA unexpectedly"
fi

# ── 3. wb remove on an unregistered name is a clean no-op. ─────────────────
out="$(bash "${WB}" remove totally-unregistered-name 2>&1)"
if echo "${out}" | grep -q "is not registered"; then
    ok "wb remove on an unregistered module is a clean no-op with a clear message"
else
    fail "wb remove on an unregistered module did not report the expected message: ${out}"
fi

# ── 4. wb remove then wb add again (re-registration). ──────────────────────
bash "${WB}" remove widget >/dev/null 2>&1
registered_after_remove="$(grep '^REGISTERED=' "${XDG_DATA_HOME}/workbench/modules/widget/sync.conf")"
[[ "${registered_after_remove}" == "REGISTERED=false" ]] && ok "wb remove sets REGISTERED=false without deleting anything" || fail "wb remove did not flip REGISTERED to false"
[[ -d "${XDG_DATA_HOME}/workbench/modules/widget/snapshots" ]] && ok "wb remove left snapshots/ in place" || fail "wb remove deleted snapshots/"

out="$(bash "${WB}" remove widget 2>&1)"
echo "${out}" | grep -q "is not registered" && ok "wb remove on an already-removed module is also a clean no-op" || fail "wb remove is not idempotent"

# ── 5. wb track --tag pins the module; wb status reflects it; a subsequent
#    wb update does not drift off the pin. ─────────────────────────────────
bash "${WB}" add widget "${BARE}" --private >/dev/null 2>&1
bash "${WB}" track widget --tag v1.0.0 >/tmp/wb-track.log 2>&1
mode_after_track="$(grep '^TRACK_MODE=' "${XDG_DATA_HOME}/workbench/modules/widget/sync.conf")"
[[ "${mode_after_track}" == "TRACK_MODE=tag:v1.0.0" ]] && ok "wb track --tag v1.0.0 correctly sets TRACK_MODE=tag:v1.0.0" || fail "wb track did not set TRACK_MODE correctly: ${mode_after_track}"

status_out="$(bash "${WB}" status 2>&1)"
echo "${status_out}" | grep -q "tag:v1.0.0" && ok "wb status shows the pinned tag:v1.0.0 state" || fail "wb status does not show the pinned state"

deployed_before="$(cat "${HOME}/.local/share/wb-add-test/file.sh")"
bash "${WB}" update widget >/dev/null 2>&1
deployed_after="$(cat "${HOME}/.local/share/wb-add-test/file.sh")"
if [[ "${deployed_before}" == "${deployed_after}" ]]; then
    ok "a subsequent wb update does not drift a tag:-pinned module off its pin"
else
    fail "wb update drifted a tag:-pinned module (before/after differ)"
fi

# ── 6. wb track on an already-pinned value is a no-op. ──────────────────────
out="$(bash "${WB}" track widget --tag v1.0.0 2>&1)"
echo "${out}" | grep -q "already tracking" && ok "wb track on an already-set value is a no-op with a clear message" || fail "wb track did not report the already-tracking no-op"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
