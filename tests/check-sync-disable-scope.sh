#!/usr/bin/env bash
# tests/check-sync-disable-scope.sh — docs/decisions-log.md D108.
#
# 'wb sync disable <name>' stops updates and nothing else. The timer's list and
# a bulk 'wb update' skip the module; an explicit 'wb update <name>' still works;
# its shell functions still load and its tools are still listed.
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

SRC="${WORK}/src"
BARE="${WORK}/bare.git"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}" 2>/dev/null
git -C "${SRC}" config user.email t@t.com
git -C "${SRC}" config user.name Test
mkdir -p "${SRC}/shell"
cat > "${SRC}/workbench.yml" <<'YAML'
version: 2
core_api: ">=1.0 <99.0"
register:
  shell:
    - src: shell/paused.sh
      tier: tools
  installers:
    - src: shell/installers.sh
YAML
printf 'paused_fn() { echo paused-v1; }\n' > "${SRC}/shell/paused.sh"
printf 'install-paused-tool() { :; }\n' > "${SRC}/shell/installers.sh"
git -C "${SRC}" add -A
git -C "${SRC}" commit -q -m v1
git -C "${SRC}" branch -qM main
git -C "${SRC}" tag v1.0.0
git -C "${SRC}" push -q origin main v1.0.0

wb add paused "${BARE}" --private --yes
[[ "${rc}" -eq 0 ]] && ok "fixture module added" || { fail "wb add (rc ${rc})"; cat "${OUT}"; }

wb sync disable paused
list_syncable="$(bash -c "source '${REPO_ROOT}/lib/core/log.sh' 2>/dev/null; source '${REPO_ROOT}/lib/sync/state.sh'; workbench_list_syncable_modules")"
list_loadable="$(bash -c "source '${REPO_ROOT}/lib/core/log.sh' 2>/dev/null; source '${REPO_ROOT}/lib/sync/state.sh'; workbench_list_loadable_modules")"
printf '%s\n' "${list_syncable}" | grep -qx paused \
    && fail "a sync-disabled module is in the syncable list" \
    || ok "a sync-disabled module isn't in the syncable list"
printf '%s\n' "${list_loadable}" | grep -qx paused \
    && ok "a sync-disabled module is still in the loadable list" \
    || fail "a sync-disabled module dropped out of the loadable list"

wb tools list
grep -q 'paused-tool' "${OUT}" \
    && ok "its tools are still listed" \
    || { fail "its tools disappeared from 'wb tools list'"; cat "${OUT}"; }

# A new release: bulk update skips it, an explicit update takes it.
printf 'paused_fn() { echo paused-v2; }\n' > "${SRC}/shell/paused.sh"
git -C "${SRC}" add -A
git -C "${SRC}" commit -q -m v2
git -C "${SRC}" tag v1.1.0
git -C "${SRC}" push -q origin main v1.1.0

wb update
[[ "$(readlink "${MODULES}/paused/current")" == *v1.0.0-* ]] \
    && ok "a bulk 'wb update' left it on its version" \
    || { fail "a bulk 'wb update' moved a sync-disabled module"; cat "${OUT}"; }
wb update paused
[[ "$(readlink "${MODULES}/paused/current")" == *v1.1.0-* ]] \
    && ok "an explicit 'wb update paused' still updates it" \
    || { fail "'wb update paused' didn't update it"; cat "${OUT}"; }

# Bulk update names what it skipped.
git -C "${SRC}" tag v1.1.1
git -C "${SRC}" push -q origin v1.1.1
wb update
grep -q 'skipping paused because its sync is off' "${OUT}" \
    && ok "a bulk 'wb update' says it skipped the module and why" \
    || { fail "no skip notice"; cat "${OUT}"; }

# With sync off, following the latest is one move, and it says so.
wb track paused --latest
wb track paused --tag v1.0.0
wb track paused --latest
grep -q "sync is off" "${OUT}" && grep -q 'wb sync enable paused' "${OUT}" \
    && ok "'wb track --latest' with sync off says it won't update on its own" \
    || { fail "no sync-off note"; cat "${OUT}"; }

# A branch-tracked module with sync off doesn't force the fast cadence.
sed -i.bak 's/^TRACK_MODE=.*/TRACK_MODE=branch:main/' "${MODULES}/paused/sync.conf"
rm -f "${MODULES}/paused/sync.conf.bak"
wb status
grep -q 'cadence active: no' "${OUT}" \
    && ok "a branch-tracked module with sync off doesn't force the fast cadence" \
    || { fail "fast cadence still on"; cat "${OUT}"; }

# 'wb track --branch' turns sync on, as its help says.
wb track paused --latest
wb track paused --branch main
[[ "$(grep '^SYNC_ENABLED=' "${MODULES}/paused/sync.conf" | cut -d= -f2)" == "true" ]] \
    && ok "'wb track --branch' turns sync on" \
    || { fail "sync still off after --branch"; cat "${OUT}"; }
wb track paused --latest
wb sync disable paused

# A frozen module on a version this core doesn't support: 'wb status' warns.
current="$(readlink "${MODULES}/paused/current")"
sed -i.bak 's/^core_api:.*/core_api: ">=1.0 <1.1"/' "${current}/workbench.yml"
rm -f "${current}/workbench.yml.bak"
bash -c "source '${WB}' >/dev/null 2>&1; _workbench_ensure_version_file; _workbench_sync_version_facts" >/dev/null 2>&1
wb status
grep -q 'paused: this version needs Core API' "${OUT}" \
    && ok "'wb status' warns about a version this core doesn't support" \
    || { fail "no core_api warning"; cat "${OUT}"; }

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
