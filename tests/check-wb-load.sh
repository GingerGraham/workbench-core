#!/usr/bin/env bash
# tests/check-wb-load.sh — docs/decisions-log.md D108.
#
# 'wb load disable <name>' stops new shells loading a module's shell content
# and changes nothing else: it keeps updating, its config keeps applying, and
# its tools are still listed. Core can't be turned off.
#
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# SC2329: converge()'s stubs are called by the function under test.
# SC2031: rc is only read after wb(), which sets it in this shell.
# shellcheck disable=SC2015,SC2329,SC2031
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
printf '[user]\n\tname = Mine\n' > "${HOME}/.gitconfig"

wb() {
    rc=0
    bash "${WB}" "$@" >"${OUT}" 2>&1 </dev/null || rc=$?
}

# Sources the loader directly, as the rc stub does, with core's state absent:
# only the module's own content is under test here.
shell_has_fn() {
    bash -c "source '${REPO_ROOT}/lib/loader.sh' >/dev/null 2>&1; type demo_fn >/dev/null 2>&1"
}

SRC="${WORK}/src"
BARE="${WORK}/bare.git"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}" 2>/dev/null
git -C "${SRC}" config user.email t@t.com
git -C "${SRC}" config user.name Test
mkdir -p "${SRC}/files" "${SRC}/shell"
cat > "${SRC}/workbench.yml" <<'YAML'
version: 2
core_api: ">=1.0 <99.0"
register:
  shell:
    - src: shell/demo.sh
      tier: tools
  installers:
    - src: shell/installers.sh
layers:
  - tool: gitconfig
    src: files/gitconfig
YAML
printf 'demo_fn() { echo demo-v1; }\n' > "${SRC}/shell/demo.sh"
printf 'install-demo-tool() { :; }\n' > "${SRC}/shell/installers.sh"
printf '[demo]\n\tsetting = on\n' > "${SRC}/files/gitconfig"
git -C "${SRC}" add -A
git -C "${SRC}" commit -q -m v1
git -C "${SRC}" branch -qM main
git -C "${SRC}" tag v1.0.0
git -C "${SRC}" push -q origin main v1.0.0

wb add demo "${BARE}" --private --yes
[[ "${rc}" -eq 0 ]] && shell_has_fn \
    && ok "fixture: the module's function loads" \
    || { fail "fixture (rc ${rc})"; cat "${OUT}"; }

wb load disable demo
[[ "${rc}" -eq 0 ]] && grep -q 'new terminal' "${OUT}" \
    && ok "'wb load disable' succeeds and says the effect is in new shells" \
    || { fail "wb load disable (rc ${rc})"; cat "${OUT}"; }
shell_has_fn \
    && fail "a load-disabled module's function still loaded" \
    || ok "a new shell doesn't load its function"

wb load disable demo
[[ "${rc}" -eq 0 ]] && grep -q 'no-op' "${OUT}" \
    && ok "disabling again is a no-op" \
    || { fail "second disable (rc ${rc})"; cat "${OUT}"; }

wb status
grep -E '^demo ' "${OUT}" | grep -q ' false ' && grep -q 'LOAD' "${OUT}" \
    && ok "'wb status' shows the setting" \
    || { fail "'wb status'"; cat "${OUT}"; }

[[ "$(git config --global --includes --get demo.setting)" == "on" ]] \
    && ok "its config still applies" \
    || fail "its config stopped applying"
wb tools list
grep -q 'demo-tool' "${OUT}" \
    && ok "its tools are still listed" \
    || { fail "its tools disappeared"; cat "${OUT}"; }

printf 'demo_fn() { echo demo-v2; }\n' > "${SRC}/shell/demo.sh"
git -C "${SRC}" add -A
git -C "${SRC}" commit -q -m v2
git -C "${SRC}" tag v1.1.0
git -C "${SRC}" push -q origin main v1.1.0
wb update
[[ "$(readlink "${MODULES}/demo/current")" == *v1.1.0-* ]] \
    && ok "it still updates" \
    || { fail "a load-disabled module stopped updating"; cat "${OUT}"; }
shell_has_fn \
    && fail "updating turned its shell content back on" \
    || ok "updating doesn't turn its shell content back on"

wb load enable demo
[[ "${rc}" -eq 0 ]] && shell_has_fn \
    && ok "'wb load enable' brings it back" \
    || { fail "wb load enable (rc ${rc})"; cat "${OUT}"; }

wb load disable core
[[ "${rc}" -ne 0 ]] && grep -q "can't be turned off" "${OUT}" \
    && ok "core can't be turned off" \
    || { fail "wb load disable core (rc ${rc})"; cat "${OUT}"; }
wb load disable
[[ "${rc}" -eq 2 ]] \
    && ok "no name is a usage error, not a default to core" \
    || { fail "wb load disable with no name (rc ${rc})"; cat "${OUT}"; }
rc=0
bash -c "source '${WB}' >/dev/null 2>&1; _wb_require modules/load-toggle.sh; workbench_cmd_load_toggle bogus demo" >"${OUT}" 2>&1 || rc=$?
[[ "${rc}" -eq 2 ]] && grep -q 'usage' "${OUT}" && ! grep -q '^LOAD_ENABLED=$' "${MODULES}/demo/sync.conf" \
    && ok "an unknown action, called directly, is a usage error and writes nothing" \
    || { fail "workbench_cmd_load_toggle bogus (rc ${rc})"; cat "${OUT}"; grep LOAD_ENABLED "${MODULES}/demo/sync.conf"; }
wb load disable nothing-here
[[ "${rc}" -ne 0 ]] && grep -q 'not registered' "${OUT}" \
    && ok "an unregistered module: says so" \
    || { fail "unregistered (rc ${rc})"; cat "${OUT}"; }

bash "${WB}" completion bash 2>/dev/null | grep -q 'load)' \
    && ok "bash completion covers 'wb load'" \
    || fail "bash completion doesn't cover 'wb load'"
bash "${WB}" completion zsh 2>/dev/null | grep -q 'load)' \
    && ok "zsh completion covers 'wb load'" \
    || fail "zsh completion doesn't cover 'wb load'"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
