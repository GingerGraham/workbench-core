#!/usr/bin/env bash
# tests/check-wb-add-multi.sh — docs/decisions-log.md D106 acceptance check.
#
# 'wb add <name> <name>...' registers several catalog modules in one
# command, through workbench_add_modules — the same path 'wb install
# --bundle' now uses. Every name is checked before anything is registered;
# a url, --private and --allow-hooks only go with a single name; the D84
# question is asked once for all of them.
#
# Modules resolve through a host-override catalog
# (${XDG_CONFIG_HOME}/workbench/catalog/{modules,bundles}.list) pointing at
# local bare repos, marked private so they are fetched with git, as every
# local-fixture test here does.
#
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# SC2030/SC2031: fixtures are built in subshells with their own HOME.
# shellcheck disable=SC2015,SC2030,SC2031
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
OUT="${WORK}/out.log"
export WORKBENCH_PAGER=cat
export GIT_CONFIG_NOSYSTEM=1

# make_fixture <module> <tmux line>
# A module that layers into tmux.conf, so a HOME with its own tmux.conf
# makes the D84 question appear.
make_fixture() {
    local module="$1" line="$2"
    (
        export HOME="${WORK}/buildhome"
        mkdir -p "${HOME}"
        git init -q --bare "${WORK}/${module}.git"
        git clone -q "${WORK}/${module}.git" "${WORK}/src-${module}" 2>/dev/null
        cd "${WORK}/src-${module}" || exit 1
        git config user.email t@t.com; git config user.name Test
        mkdir -p files
        printf '%s\n' "${line}" > files/tmux.conf
        cat > workbench.yml <<'EOF'
version: 2
core_api: ">=1.6 <2.0"
layers:
  - tool: tmux.conf
    src: files/tmux.conf
EOF
        git add -A; git commit -q -m v1; git branch -M main
        git push -q origin main 2>/dev/null
        git tag v1.0.0; git push -q origin v1.0.0 2>/dev/null
    )
}
make_fixture m-one 'set -g mouse on'
make_fixture m-two 'set -g history-limit 50000'
make_fixture m-three 'set -g base-index 1'

# new_home <label> — a fresh HOME with the override catalog in place
new_home() {
    export HOME="${WORK}/home-$1"
    export XDG_DATA_HOME="${HOME}/.local/share"
    export XDG_CONFIG_HOME="${HOME}/.config"
    rm -rf "${HOME}"
    mkdir -p "${XDG_CONFIG_HOME}/workbench/catalog"
    {
        printf 'm-one|%s|true\n' "${WORK}/m-one.git"
        printf 'm-two|%s|true\n' "${WORK}/m-two.git"
        printf 'm-three|%s|true\n' "${WORK}/m-three.git"
    } > "${XDG_CONFIG_HOME}/workbench/catalog/modules.list"
    printf 'pair|m-one,m-two\n' > "${XDG_CONFIG_HOME}/workbench/catalog/bundles.list"
}

registered() { grep -q '^REGISTERED=true' "${XDG_DATA_HOME}/workbench/modules/$1/sync.conf" 2>/dev/null; }
# deployed <module> — <module>'s layer block is in whichever tmux.conf the
# layer used (~/.tmux.conf if the user had one, else ~/.config/tmux/tmux.conf)
deployed() {
    local f
    for f in "${HOME}/.tmux.conf" "${HOME}/.config/tmux/tmux.conf"; do
        [[ -f "${f}" ]] && grep -q -- ">>> workbench $1/tmux.conf " "${f}" && return 0
    done
    return 1
}
none_registered() { [[ ! -d "${XDG_DATA_HOME}/workbench/modules/m-one" && ! -d "${XDG_DATA_HOME}/workbench/modules/m-two" ]]; }

# run_notty <wb args...> — no controlling terminal: nobody can be asked
run_notty() {
    rc=0
    if command -v setsid &>/dev/null; then
        setsid -w bash "${WB}" "$@" </dev/null >"${OUT}" 2>&1 || rc=$?
    else
        bash "${WB}" "$@" </dev/null >"${OUT}" 2>&1 || rc=$?
    fi
}

# ── 1-3. two names: both registered and deployed, with a summary. ──────────
new_home two
run_notty add m-one m-two
[[ "${rc}" -eq 0 ]] && registered m-one && registered m-two \
    && ok "add m-one m-two: both registered, exit 0" \
    || { fail "add m-one m-two (rc ${rc})"; cat "${OUT}"; }
deployed m-one && deployed m-two \
    && ok "add m-one m-two: both modules' layers deployed" \
    || { fail "add m-one m-two: layers not deployed"; cat "${OUT}"; cat "${HOME}/.tmux.conf" 2>/dev/null; }
grep -q 'wb add: registered: m-one m-two' "${OUT}" \
    && ok "add m-one m-two: summary names both" \
    || { fail "add m-one m-two: no summary"; cat "${OUT}"; }

# ── 4. already-registered names are reported, the rest still added. ────────
run_notty add m-two m-three
[[ "${rc}" -eq 0 ]] && registered m-three && grep -q 'wb add: already registered: m-two' "${OUT}" \
    && ok "add m-two m-three: m-three added, m-two reported as already registered" \
    || { fail "add m-two m-three (rc ${rc})"; cat "${OUT}"; }

# ── 5-6. an unknown name, or a bundle name, registers nothing. ─────────────
new_home unknown
run_notty add m-one no-such-module pair m-two
[[ "${rc}" -eq 2 ]] && none_registered \
    && ok "add with an unknown name and a bundle name: exit 2, nothing registered" \
    || { fail "add with unknown names (rc ${rc})"; cat "${OUT}"; }
grep -q 'not in the known-modules catalog: no-such-module' "${OUT}" \
    && grep -q "bundles, not modules: pair — use 'wb install --bundle <name>'" "${OUT}" \
    && ok "add with unknown names: one error per kind, naming each" \
    || { fail "add with unknown names: errors don't name them"; cat "${OUT}"; }

# ── 7-9. a url, --private, --allow-hooks with several names: refused. ──────
run_notty add m-one m-two "${WORK}/m-one.git"
[[ "${rc}" -eq 2 ]] && none_registered && grep -q 'a url applies to one module' "${OUT}" \
    && ok "add m-one m-two <url>: refused, nothing registered" \
    || { fail "add with a url and two names (rc ${rc})"; cat "${OUT}"; }
run_notty add m-one m-two --private
[[ "${rc}" -eq 2 ]] && none_registered && grep -q -- '--private goes with a url' "${OUT}" \
    && ok "add m-one m-two --private: refused, nothing registered" \
    || { fail "add two names --private (rc ${rc})"; cat "${OUT}"; }
run_notty add m-one m-two --allow-hooks
[[ "${rc}" -eq 2 ]] && none_registered && grep -q -- '--allow-hooks is a per-module decision' "${OUT}" \
    && ok "add m-one m-two --allow-hooks: refused, nothing registered" \
    || { fail "add two names --allow-hooks (rc ${rc})"; cat "${OUT}"; }

# ── 10. the single-name url form is unchanged. ─────────────────────────────
run_notty add solo "${WORK}/m-three.git" --private
[[ "${rc}" -eq 0 ]] && registered solo \
    && ok "add solo <url> --private: the single-module url form still works" \
    || { fail "add solo <url> (rc ${rc})"; cat "${OUT}"; }

# ── 11. a bundle name given to single-name add gets a pointer. ─────────────
run_notty add pair
[[ "${rc}" -eq 1 ]] && grep -q "'pair' is a bundle, not a module — use 'wb install --bundle pair'" "${OUT}" \
    && ok "add pair: points at 'wb install --bundle pair'" \
    || { fail "add pair (rc ${rc})"; cat "${OUT}"; }

# ── 12. --skip-layer applies to each named module. ─────────────────────────
new_home skip
printf 'set -g mouse off\n' > "${HOME}/.tmux.conf"
run_notty add m-one m-two --skip-layer tmux.conf
[[ "${rc}" -eq 0 ]] && registered m-one && registered m-two \
    && ! grep -q 'workbench' "${HOME}/.tmux.conf" && ! deployed m-one && ! deployed m-two \
    && ok "add m-one m-two --skip-layer tmux.conf: neither module wrote a block" \
    || { fail "add --skip-layer (rc ${rc})"; cat "${OUT}"; cat "${HOME}/.tmux.conf"; }

# ── 13. the bundle path, through the shared helper. ────────────────────────
# _wb_cmd_install in a sourced bin/wb, with the prerequisite installer
# stubbed out: a test must never reach the host's package manager.
new_home bundle
rc=0
setsid_cmd=""
command -v setsid &>/dev/null && setsid_cmd="setsid -w"
# shellcheck disable=SC2016  # expanded by the inner bash
${setsid_cmd} bash -c '
    wb_path="$1"
    set --
    source "${wb_path}" >/dev/null 2>&1
    workbench_missing_shell_prereqs() { :; }
    workbench_install_shell_prereqs() { echo "TEST: prerequisite install attempted" >&2; return 1; }
    _wb_cmd_install --bundle pair
' _ "${WB}" </dev/null >"${OUT}" 2>&1 || rc=$?
[[ "${rc}" -eq 0 ]] && registered m-one && registered m-two \
    && deployed m-one && deployed m-two \
    && ! grep -q 'TEST: prerequisite install attempted' "${OUT}" \
    && ok "install --bundle pair: both members registered and deployed" \
    || { fail "install --bundle pair (rc ${rc})"; cat "${OUT}"; }

# ── 14. one question for every new module (needs a pty). ───────────────────
if command -v script &>/dev/null; then
    new_home asked
    printf 'set -g mouse off\n' > "${HOME}/.tmux.conf"
    done_flag="${WORK}/pty.done"
    rm -f "${done_flag}"
    cmd="echo | $(printf '%q ' bash "${WB}" add m-one m-two); rc=\$?; touch $(printf '%q' "${done_flag}"); exit \${rc}"
    rc=0
    n=0
    {
        printf 'k\n'
        while [[ ! -e "${done_flag}" && "${n}" -lt 1200 ]]; do sleep 0.1; n=$((n + 1)); done
    } | if script --version 2>/dev/null | grep -q util-linux; then
        script -qec "${cmd}" /dev/null
    else
        script -q /dev/null bash -c "${cmd}"
    fi >"${OUT}" 2>&1 || rc=$?
    times="$(grep -c 'These modules would touch config you already have' "${OUT}")"
    [[ "${times}" -eq 1 ]] && registered m-one && registered m-two \
        && ok "add m-one m-two from a terminal: asked once for both" \
        || { fail "add m-one m-two from a terminal: asked ${times} times (rc ${rc})"; cat "${OUT}"; }
else
    echo "SKIP: script(1) not installed — can't attach a pty for check 14."
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
