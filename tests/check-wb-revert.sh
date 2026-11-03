#!/usr/bin/env bash
# tests/check-wb-revert.sh — docs/decisions-log.md D108.
#
# 'wb revert' goes back to a version on disk with no network, pins it, takes
# out what the newer version added, and refuses what it can't do safely. A
# failed 'wb track' leaves the module's tracking as it was. The remote is moved
# out of the way for the checks that claim to need no network.
#
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# shellcheck disable=SC2015
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WB="${REPO_ROOT}/bin/wb"

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
MODULES="${XDG_DATA_HOME}/workbench/modules"
OUT="${WORK}/out.log"

wb() {
    rc=0
    bash "${WB}" "$@" >"${OUT}" 2>&1 </dev/null || rc=$?
}
conf_of() { grep "^$2=" "${MODULES}/$1/sync.conf" 2>/dev/null | cut -d= -f2; }
current_is() { [[ "$(readlink "${MODULES}/demo/current")" == *"/$1-"* ]]; }

SRC="${WORK}/src"
BARE="${WORK}/bare.git"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}" 2>/dev/null
git -C "${SRC}" config user.email t@t.com
git -C "${SRC}" config user.name Test
mkdir -p "${SRC}/files" "${SRC}/shell"

release() {
    git -C "${SRC}" add -A
    git -C "${SRC}" commit -q -m "$1"
    git -C "${SRC}" branch -qM main
    git -C "${SRC}" tag "$1"
    git -C "${SRC}" push -q origin main "$1"
}
sha_of() { git -C "${SRC}" rev-parse "$1^{commit}"; }
remote_off() { mv "${BARE}" "${BARE}.off"; }
remote_on()  { mv "${BARE}.off" "${BARE}"; }

printf 'conf v1\n' > "${SRC}/files/conf"
cat > "${SRC}/workbench.yml" <<'YAML'
version: 2
core_api: ">=1.0 <99.0"
deploy:
  - src: files/conf
    dest: ~/.config/demo/conf
    force: true
YAML
release v1.0.0
wb add demo "${BARE}" --private --yes
[[ "${rc}" -eq 0 ]] && ok "fixture module added at v1.0.0" || { fail "wb add (rc ${rc})"; cat "${OUT}"; }

printf 'conf v2\n' > "${SRC}/files/conf"
release v1.1.0
wb update demo

# v1.2.0 adds a copied file, a file the user will edit, a link and a layer.
printf 'conf v3\n' > "${SRC}/files/conf"
printf 'added\n' > "${SRC}/files/added"
printf 'kept\n' > "${SRC}/files/kept"
printf 'linked\n' > "${SRC}/files/linked"
printf '[demo]\n\tsetting = v3\n' > "${SRC}/files/gitconfig"
cat > "${SRC}/workbench.yml" <<'YAML'
version: 2
core_api: ">=1.0 <99.0"
deploy:
  - src: files/conf
    dest: ~/.config/demo/conf
    force: true
  - src: files/added
    dest: ~/.config/demo/added
  - src: files/kept
    dest: ~/.config/demo/kept
  - src: files/linked
    dest: ~/.config/demo/linked
    mode: link
layers:
  - tool: gitconfig
    src: files/gitconfig
YAML
release v1.2.0
wb update demo
current_is v1.2.0 && [[ -f "${HOME}/.config/demo/added" && -L "${HOME}/.config/demo/linked" ]] \
    && grep -q 'workbench demo/gitconfig' "${HOME}/.gitconfig" \
    && ok "fixture updated to v1.2.0 with its extra file, link and block" \
    || { fail "fixture didn't reach v1.2.0"; cat "${OUT}"; }

# Fetch times one second apart can tie, so set the order the tests rely on.
touch -t 202601010000 "${MODULES}"/demo/snapshots/v1.0.0-*
touch -t 202601020000 "${MODULES}"/demo/snapshots/v1.1.0-*
touch -t 202601030000 "${MODULES}"/demo/snapshots/v1.2.0-*
printf 'my change\n' >> "${HOME}/.config/demo/kept"

# ── --list ─────────────────────────────────────────────────────────────────
wb revert demo --list
[[ "${rc}" -eq 0 ]] && grep -q '\* v1.2.0' "${OUT}" && grep -q 'v1.0.0' "${OUT}" && current_is v1.2.0 \
    && ok "--list shows the versions, marks the current one and changes nothing" \
    || { fail "--list (rc ${rc})"; cat "${OUT}"; }

# ── Refuses with no terminal and no --yes ──────────────────────────────────
wb revert demo
[[ "${rc}" -ne 0 ]] && current_is v1.2.0 && [[ "$(conf_of demo TRACK_MODE)" == "latest" ]] \
    && ok "no terminal and no --yes: refuses, nothing changed" \
    || { fail "revert without --yes (rc ${rc})"; cat "${OUT}"; }

# ── Back one version with no network ───────────────────────────────────────
remote_off
wb revert demo --yes
[[ "${rc}" -eq 0 ]] && current_is v1.1.0 && grep -qx 'conf v2' "${HOME}/.config/demo/conf" \
    && ok "with the remote gone, goes back one version and its files follow" \
    || { fail "offline revert (rc ${rc})"; cat "${OUT}"; }
[[ "$(conf_of demo TRACK_MODE)" == "tag:v1.1.0" && "$(conf_of demo RESOLVED_SHA)" == "$(sha_of v1.1.0)" ]] \
    && ok "pinned to the tag, with the full commit recorded" \
    || fail "state after revert: $(conf_of demo TRACK_MODE) $(conf_of demo RESOLVED_SHA)"
[[ ! -e "${HOME}/.config/demo/added" && ! -L "${HOME}/.config/demo/linked" ]] \
    && ok "an unchanged file and a link only the newer version declared are removed" \
    || { fail "newer version's file or link left behind"; cat "${OUT}"; }
grep -q 'workbench demo/gitconfig' "${HOME}/.gitconfig" 2>/dev/null \
    && { fail "newer version's block left in ~/.gitconfig"; cat "${HOME}/.gitconfig"; } \
    || ok "a block only the newer version declared is removed"
grep -q 'my change' "${HOME}/.config/demo/kept" && grep -q 'leaving it in place' "${OUT}" \
    && ok "a file the user changed stays, with a warning" \
    || { fail "user's changed file not kept"; cat "${OUT}"; }

# ── Repeating keeps going back, then stops ─────────────────────────────────
wb revert demo --yes
[[ "${rc}" -eq 0 ]] && current_is v1.0.0 \
    && ok "repeating goes back again, rather than forward" \
    || { fail "second revert (rc ${rc})"; cat "${OUT}"; }
wb revert demo --yes
[[ "${rc}" -ne 0 ]] && current_is v1.0.0 && grep -q 'no older version' "${OUT}" \
    && ok "no older version: says so, nothing changed" \
    || { fail "revert past the oldest (rc ${rc})"; cat "${OUT}"; }
wb revert demo v9.9.9 --yes
[[ "${rc}" -ne 0 ]] && grep -q "isn't on this machine" "${OUT}" \
    && ok "a version not on disk: says so" \
    || { fail "unknown version (rc ${rc})"; cat "${OUT}"; }
wb revert demo v1.0.0 --yes
[[ "${rc}" -eq 0 ]] && grep -q 'no-op' "${OUT}" \
    && ok "the version it's already on: no-op" \
    || { fail "same version (rc ${rc})"; cat "${OUT}"; }
remote_on

# ── It stays pinned ────────────────────────────────────────────────────────
wb update demo
current_is v1.0.0 \
    && ok "'wb update' doesn't move it forward" \
    || { fail "'wb update' moved a reverted module"; cat "${OUT}"; }

# ── Returning to releases brings back what revert took out ─────────────────
wb track demo --latest
[[ "${rc}" -eq 0 ]] && current_is v1.2.0 && [[ -f "${HOME}/.config/demo/added" && -L "${HOME}/.config/demo/linked" ]] \
    && grep -q 'workbench demo/gitconfig' "${HOME}/.gitconfig" \
    && ok "'wb track --latest' restores the newer version's file, link and block" \
    || { fail "return to latest (rc ${rc})"; cat "${OUT}"; ls -la "${HOME}/.config/demo"; }

# ── A failed 'wb track' changes nothing, and a retry isn't a no-op ─────────
remote_off
wb track demo --tag v1.1.0
[[ "${rc}" -ne 0 && "$(conf_of demo TRACK_MODE)" == "latest" ]] && current_is v1.2.0 \
    && ok "'wb track' with the remote gone: fails, tracking unchanged" \
    || { fail "failed track (rc ${rc}): mode $(conf_of demo TRACK_MODE)"; cat "${OUT}"; }
remote_on
wb track demo --tag v1.1.0
[[ "${rc}" -eq 0 ]] && current_is v1.1.0 \
    && ok "retrying 'wb track' with the remote back does the work" \
    || { fail "track retry (rc ${rc})"; cat "${OUT}"; }
wb track demo --latest

# ── With no adoption.log row, a tag snapshot still works and self-corrects ─
rm -f "${XDG_DATA_HOME}/workbench/adoption.log"
wb revert demo v1.0.0 --yes
[[ "${rc}" -eq 0 ]] && current_is v1.0.0 && [[ "$(conf_of demo TRACK_MODE)" == "tag:v1.0.0" ]] \
    && ok "no adoption.log: a tag-named snapshot still reverts" \
    || { fail "revert without log (rc ${rc})"; cat "${OUT}"; }
wb update demo
[[ "$(conf_of demo RESOLVED_SHA)" == "$(sha_of v1.0.0)" ]] && current_is v1.0.0 \
    && ok "the next update corrects the short commit to the full one" \
    || { fail "RESOLVED_SHA not corrected: $(conf_of demo RESOLVED_SHA)"; cat "${OUT}"; }

# ── A branch snapshot with no record can't be pinned ───────────────────────
cp -a "$(cd "${MODULES}/demo/snapshots" && pwd)/$(basename "$(readlink "${MODULES}/demo/current")")" \
    "${MODULES}/demo/snapshots/branch-main-abc1234"
wb revert demo abc1234 --yes
[[ "${rc}" -ne 0 ]] && grep -q 'no record' "${OUT}" && current_is v1.0.0 \
    && ok "a branch snapshot with no adoption.log row is refused" \
    || { fail "branch snapshot (rc ${rc})"; cat "${OUT}"; }
rm -rf "${MODULES}/demo/snapshots/branch-main-abc1234"

wb revert nothing-here
[[ "${rc}" -ne 0 ]] && grep -q 'not registered' "${OUT}" \
    && ok "an unregistered module: says so" \
    || { fail "unregistered (rc ${rc})"; cat "${OUT}"; }

# ── Core gate ──────────────────────────────────────────────────────────────
core_gate() {
    bash -c "
        source '${WB}' >/dev/null 2>&1
        _wb_require modules/revert.sh
        _wb_revert_core_allowed '$1'
    " >"${OUT}" 2>&1
}
mkdir -p "${WORK}/core-good/lib/core" "${WORK}/core-api/lib/core" "${WORK}/core-schema/lib/core"
host_api="$(awk -F= '$1 == "CORE_API_VERSION" { print $2 }' "${REPO_ROOT}/lib/core/version-defaults.conf")"
host_schema="$(awk -F= '$1 == "STATE_SCHEMA_VERSION" { print $2 }' "${REPO_ROOT}/lib/core/version-defaults.conf")"
printf 'CORE_API_VERSION=%s\nSTATE_SCHEMA_VERSION=%s\n' "${host_api}" "${host_schema}" > "${WORK}/core-good/lib/core/version-defaults.conf"
printf 'CORE_API_VERSION=0.1\nSTATE_SCHEMA_VERSION=%s\n' "${host_schema}" > "${WORK}/core-api/lib/core/version-defaults.conf"
printf 'CORE_API_VERSION=%s\nSTATE_SCHEMA_VERSION=0\n' "${host_api}" > "${WORK}/core-schema/lib/core/version-defaults.conf"
mkdir -p "${WORK}/core-unreadable/lib/core"
bash -c "source '${WB}' >/dev/null 2>&1; _workbench_ensure_version_file; _workbench_sync_version_facts" >/dev/null 2>&1

# ── A Core API hold for a version it didn't reach isn't left behind ────────
mode_before="$(conf_of demo TRACK_MODE)"
held_before="$(conf_of demo HELD_CORE_API)"
sed -i.bak 's/^core_api: .*/core_api: ">=99.0"/' "${SRC}/workbench.yml" && rm -f "${SRC}/workbench.yml.bak"
release v9.0.0
wb track demo --tag v9.0.0
[[ "${rc}" -ne 0 && "$(conf_of demo TRACK_MODE)" == "${mode_before}" && "$(conf_of demo HELD_CORE_API)" == "${held_before}" ]] \
    && grep -q "needs Core API" "${OUT}" \
    && ok "'wb track' to a version this core can't serve: fails, mode and Core API hold unchanged" \
    || { fail "held track (rc ${rc}): mode $(conf_of demo TRACK_MODE), held '$(conf_of demo HELD_CORE_API)'"; cat "${OUT}"; }

core_gate "${WORK}/core-good" \
    && ok "core gate: allows a core every module accepts" \
    || { fail "core gate refused a good core"; cat "${OUT}"; }
core_gate "${WORK}/core-api" \
    && { fail "core gate allowed a Core API a module excludes"; cat "${OUT}"; } \
    || { grep -q 'demo needs Core API' "${OUT}" && ok "core gate: refuses, naming the module it would strand" || { fail "core gate message"; cat "${OUT}"; }; }
core_gate "${WORK}/core-schema" \
    && { fail "core gate allowed an older state schema"; cat "${OUT}"; } \
    || ok "core gate: refuses a core that can't read this host's state"
core_gate "${WORK}/core-unreadable" \
    && { fail "core gate allowed a core whose version facts can't be read"; cat "${OUT}"; } \
    || { grep -q "can't read the state schema version" "${OUT}" && ok "core gate: refuses a core whose version facts can't be read" || { fail "core gate unreadable message"; cat "${OUT}"; }; }

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
