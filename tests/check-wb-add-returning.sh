#!/usr/bin/env bash
# tests/check-wb-add-returning.sh — docs/decisions-log.md D108.
#
# 'wb add' on a module 'wb remove' deregistered brings it back with its url and
# settings, and offers the choice of version: move to the latest (recommended)
# or stay. With nothing to decide, or no terminal to ask on, it returns as the
# user left it. After 'wb remove --restore' it asks before putting config back.
#
# Questions are answered through a pty (script(1)), so /dev/tty is real, the
# same way as tests/check-install-choice.sh.
#
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# SC2088: ~/ in expected output is literal.
# shellcheck disable=SC2015,SC2088
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
printf 'THEIRS\n' > "${HOME}/.demo.conf"

wb() {
    rc=0
    bash "${WB}" "$@" >"${OUT}" 2>&1 </dev/null || rc=$?
}

# wb_tty <answers> <wb args...> — a pty attached, stdin a pipe.
wb_tty() {
    local answers="$1" done_flag="${WORK}/pty.done" n=0 cmd
    shift
    cmd="$(printf '%q ' bash "${WB}" "$@")"
    cmd="${cmd}; rc=\$?; touch $(printf '%q' "${done_flag}"); exit \${rc}"
    rm -f "${done_flag}"
    rc=0
    {
        printf '%b' "${answers}"
        while [[ ! -e "${done_flag}" && "${n}" -lt 600 ]]; do sleep 0.1; n=$((n + 1)); done
    } | if script --version 2>/dev/null | grep -q util-linux; then
        script -qec "${cmd}" /dev/null
    else
        script -q /dev/null bash -c "${cmd}"
    fi >"${OUT}" 2>&1 || rc=$?
}

conf_of() { grep "^$2=" "${MODULES}/$1/sync.conf" 2>/dev/null | cut -d= -f2; }
version_is() { [[ "$(readlink "${MODULES}/demo/current")" == *"/$1-"* ]]; }

SRC="${WORK}/src"
BARE="${WORK}/bare.git"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}" 2>/dev/null
git -C "${SRC}" config user.email t@t.com
git -C "${SRC}" config user.name Test
mkdir -p "${SRC}/files"
cat > "${SRC}/workbench.yml" <<'YAML'
version: 2
core_api: ">=1.0 <99.0"
deploy:
  - src: files/demo.conf
    dest: ~/.demo.conf
YAML
release() {
    printf 'MODULE %s\n' "$1" > "${SRC}/files/demo.conf"
    git -C "${SRC}" add -A
    git -C "${SRC}" commit -q -m "$1"
    git -C "${SRC}" branch -qM main
    git -C "${SRC}" tag "$1"
    git -C "${SRC}" push -q origin main "$1"
}
remote_off() { mv "${BARE}" "${BARE}.off"; }
remote_on()  { mv "${BARE}.off" "${BARE}"; }

# Back to a known start: v1.1.0, tracking <mode>, removed.
removed_at_v1_1_0() {
    wb track demo --tag v1.1.0
    wb sync enable demo
    if [[ "$1" == "following" ]]; then
        sed -i.bak 's/^TRACK_MODE=.*/TRACK_MODE=latest/' "${MODULES}/demo/sync.conf"
        rm -f "${MODULES}/demo/sync.conf.bak"
    fi
    wb remove demo
}

release v1.0.0
release v1.1.0
wb add demo "${BARE}" --private --use-files --yes
release v1.2.0
wb update demo
version_is v1.2.0 && ok "fixture: module on v1.2.0" || { fail "fixture"; cat "${OUT}"; }

# ── Pinned, no terminal: nothing moves ─────────────────────────────────────
removed_at_v1_1_0 pinned
wb add demo
[[ "${rc}" -eq 0 ]] && version_is v1.1.0 && [[ "$(conf_of demo TRACK_MODE)" == "tag:v1.1.0" && "$(conf_of demo REGISTERED)" == "true" ]] \
    && ok "pinned, no terminal: comes back on its version, still pinned" \
    || { fail "pinned no-tty (rc ${rc}): mode $(conf_of demo TRACK_MODE)"; cat "${OUT}"; }
grep -q 'pinned to v1.1.0' "${OUT}" && grep -q 'latest release is v1.2.0' "${OUT}" && grep -q 'wb track demo --latest' "${OUT}" \
    && ok "it says what it was on, what the latest is, and how to move" \
    || { fail "pinned no-tty message"; cat "${OUT}"; }
grep -q 'has no url' "${OUT}" \
    && fail "a returning custom module asked for its url" \
    || ok "a custom module doesn't need its url again"

# ── Pinned, offline: works from disk ───────────────────────────────────────
removed_at_v1_1_0 pinned
remote_off
wb add demo
[[ "${rc}" -eq 0 ]] && version_is v1.1.0 && [[ "$(conf_of demo REGISTERED)" == "true" ]] && grep -q "Couldn't check" "${OUT}" \
    && ok "pinned, offline: comes back from disk and says it couldn't check" \
    || { fail "offline (rc ${rc})"; cat "${OUT}"; }
remote_on

# ── The question ───────────────────────────────────────────────────────────
removed_at_v1_1_0 pinned
wb_tty '\n' add demo
grep -q 'pinned to v1.1.0' "${OUT}" && grep -q 'recommended' "${OUT}" && grep -q 'Stay on v1.1.0, pinned' "${OUT}" \
    && ok "with a terminal: shows the pin and both choices, recommending the latest" \
    || { fail "the question"; cat "${OUT}"; }
[[ "${rc}" -eq 0 ]] && version_is v1.2.0 && [[ "$(conf_of demo TRACK_MODE)" == "latest" ]] \
    && ok "Enter takes the recommendation: latest, following releases" \
    || { fail "Enter (rc ${rc}): mode $(conf_of demo TRACK_MODE)"; cat "${OUT}"; }

removed_at_v1_1_0 pinned
wb_tty '2\n' add demo
version_is v1.1.0 && [[ "$(conf_of demo TRACK_MODE)" == "tag:v1.1.0" ]] \
    && ok "choosing 2 stays on the pin" \
    || { fail "choice 2: mode $(conf_of demo TRACK_MODE)"; cat "${OUT}"; }

removed_at_v1_1_0 pinned
wb_tty 'x\n1\n' add demo
grep -q 'Please enter 1 or 2' "${OUT}" && version_is v1.2.0 \
    && ok "a bad answer asks again" \
    || { fail "bad answer"; cat "${OUT}"; }

# ── Following releases ─────────────────────────────────────────────────────
removed_at_v1_1_0 following
wb_tty '2\n' add demo
grep -q 'was on v1.1.0' "${OUT}" && version_is v1.1.0 && [[ "$(conf_of demo TRACK_MODE)" == "tag:v1.1.0" ]] \
    && ok "behind on releases, with a terminal: asks, and staying pins it so nothing moves it" \
    || { fail "following, stay: mode $(conf_of demo TRACK_MODE)"; cat "${OUT}"; }

removed_at_v1_1_0 following
wb add demo
version_is v1.2.0 && [[ "$(conf_of demo TRACK_MODE)" == "latest" ]] \
    && ok "behind on releases, no terminal: returns as left, following, so it moves to the latest" \
    || { fail "following, no tty"; cat "${OUT}"; }

wb remove demo
wb_tty '' add demo
[[ "${rc}" -eq 0 ]] && version_is v1.2.0 && ! grep -q 'Choose \[1/2\]' "${OUT}" \
    && ok "already on the latest and following: nothing to decide, so no question" \
    || { fail "nothing to decide (rc ${rc})"; cat "${OUT}"; }

# ── Flags ──────────────────────────────────────────────────────────────────
removed_at_v1_1_0 pinned
wb add demo --latest
version_is v1.2.0 && [[ "$(conf_of demo TRACK_MODE)" == "latest" ]] \
    && ok "--latest moves without asking" \
    || { fail "--latest"; cat "${OUT}"; }
removed_at_v1_1_0 following
wb add demo --keep-version
version_is v1.1.0 && [[ "$(conf_of demo TRACK_MODE)" == "tag:v1.1.0" ]] \
    && ok "--keep-version stays and pins without asking" \
    || { fail "--keep-version"; cat "${OUT}"; }
wb remove demo
wb add demo --latest --keep-version
[[ "${rc}" -eq 2 ]] \
    && ok "--latest and --keep-version together are refused" \
    || { fail "both flags (rc ${rc})"; cat "${OUT}"; }

remote_off
wb add demo --latest
[[ "$(conf_of demo TRACK_MODE)" == "tag:v1.1.0" ]] && version_is v1.1.0 && [[ "$(conf_of demo REGISTERED)" == "true" ]] && grep -q "couldn't reach" "${OUT}" \
    && ok "--latest with the remote gone: comes back on its version, pin intact" \
    || { fail "--latest offline: mode $(conf_of demo TRACK_MODE)"; cat "${OUT}"; }
remote_on

# ── Settings survive ───────────────────────────────────────────────────────
wb track demo --latest
wb sync disable demo
wb load disable demo
printf 'ALLOW_HOOKS=true\n' >> "${MODULES}/demo/sync.conf"
wb remove demo
wb add demo --keep-version
[[ "$(conf_of demo SYNC_ENABLED)" == "false" && "$(conf_of demo LOAD_ENABLED)" == "false" ]] \
    && grep -q 'wb sync enable demo' "${OUT}" && grep -q 'wb load enable demo' "${OUT}" \
    && grep -q '^ALLOW_HOOKS=true' "${MODULES}/demo/sync.conf" \
    && ok "sync, load and hook settings survive, and it says which are still off" \
    || { fail "settings"; cat "${OUT}" "${MODULES}/demo/sync.conf"; }
wb sync enable demo
wb load enable demo

# ── A different url is a different repo ────────────────────────────────────
wb track demo --latest
wb remove demo
git clone -q --bare "${BARE}" "${WORK}/other.git" 2>/dev/null
wb add demo "${WORK}/other.git" --private --keep-files
[[ "$(conf_of demo REPO_URL)" == "${WORK}/other.git" ]] && ! grep -q 'when you removed it' "${OUT}" \
    && ok "a different url registers as new" \
    || { fail "different url"; cat "${OUT}"; }
wb remove demo
wb add demo "${BARE}" --private --keep-files

# ── Several names ──────────────────────────────────────────────────────────
wb track demo --tag v1.1.0
wb remove demo
wb add demo nothing-here-either
[[ "${rc}" -eq 2 ]] && grep -q 'nothing-here-either' "${OUT}" && ! grep -q ' demo' <(grep 'not in the known-modules' "${OUT}") \
    && ok "several names: a returning custom module passes the catalog check" \
    || { fail "several names check (rc ${rc})"; cat "${OUT}"; }

# ── Config after --restore ─────────────────────────────────────────────────
wb track demo --latest 2>/dev/null
wb add demo --latest
wb files use demo .demo.conf --yes
wb remove demo --restore --yes
[[ "$(cat "${HOME}/.demo.conf")" == "THEIRS" ]] && ok "fixture: --restore put the user's file back" || { fail "fixture restore"; cat "${OUT}"; cat "${HOME}/.demo.conf"; }

wb add demo --latest
[[ "$(cat "${HOME}/.demo.conf")" == "THEIRS" ]] && grep -q "stays out" "${OUT}" \
    && ok "no terminal: config stays out, and it says how to put it back" \
    || { fail "restore no-tty"; cat "${OUT}"; }
wb update demo
[[ "$(cat "${HOME}/.demo.conf")" == "THEIRS" ]] \
    && ok "a later update doesn't put it back either" \
    || fail "an update overwrote the user's restored file"

wb remove demo
wb_tty '\n' add demo --latest
[[ "$(cat "${HOME}/.demo.conf")" == "THEIRS" ]] && grep -q 'Put it back? \[y/N\]' "${OUT}" && grep -q '~/.demo.conf' "${OUT}" \
    && ok "with a terminal: lists the files and asks, and Enter leaves them out" \
    || { fail "restore tty, Enter"; cat "${OUT}"; cat "${HOME}/.demo.conf"; }
wb update demo
[[ "$(cat "${HOME}/.demo.conf")" == "THEIRS" ]] \
    && ok "after answering no, a later update still leaves them out" \
    || fail "an update overwrote the file after the user said no"

wb remove demo
wb_tty 'y\n' add demo --latest
[[ "$(cat "${HOME}/.demo.conf")" == "MODULE v1.2.0" ]] \
    && ok "answering y puts it back" \
    || { fail "restore tty, y"; cat "${OUT}"; cat "${HOME}/.demo.conf"; }

wb remove demo --restore --yes
wb add demo --latest --keep-files
[[ "$(cat "${HOME}/.demo.conf")" == "THEIRS" ]] \
    && ok "--keep-files leaves it out without asking" \
    || { fail "--keep-files"; cat "${OUT}"; }
wb remove demo
wb add demo --latest --use-files --yes
[[ "$(cat "${HOME}/.demo.conf")" == "MODULE v1.2.0" ]] \
    && ok "--use-files --yes puts it back without asking" \
    || { fail "--use-files"; cat "${OUT}"; cat "${HOME}/.demo.conf"; }

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
