#!/usr/bin/env bash
# tests/check-release-cooldown.sh — docs/decisions-log.md D77 acceptance
# check (security review H3 tier 2): unattended syncs of a latest-tracked
# module adopt a newly-resolved release only after RELEASE_COOLDOWN_DAYS,
# and every adopt/cooldown/hook event is recorded in adoption.log.
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

ADOPTION_LOG="${XDG_DATA_HOME}/workbench/adoption.log"

setup_module() {
    local name="$1" repo_url="$2"
    mkdir -p "$(workbench_module_dir "${name}")"
    cat > "$(workbench_module_conf_path "${name}")" <<EOF
REPO_URL=${repo_url}
PRIVATE=true
TRACK_MODE=latest
REGISTERED=true
SYNC_ENABLED=true
ALLOW_HOOKS=false
EOF
}

make_bare_repo_with_tag() {
    local bare="$1" src="$2" tag="$3"
    mkdir -p "${src}"
    git init -q --bare "${bare}"
    git clone -q "${bare}" "${src}"
    (
        cd "${src}" || exit 1
        git config user.email t@t.com
        git config user.name Test
        echo "content for ${tag}" > file.txt
        git add -A && git commit -q -m "${tag}"
        git branch -M main
        git push -q origin main
        git tag "${tag}"
        git push -q origin "${tag}"
    )
}

add_tag() {
    local src="$1" tag="$2"
    (
        cd "${src}" || exit 1
        echo "content for ${tag}" >> file.txt
        git add -A && git commit -q -m "${tag}"
        git push -q origin main
        git tag "${tag}"
        git push -q origin "${tag}"
    )
}

# ── 1. Initial `add` sync → adopted, `adopt` line in the log ───────────────
BARE1="${WORK}/bare1.git"
SRC1="${WORK}/src1"
make_bare_repo_with_tag "${BARE1}" "${SRC1}" v1.0.0
setup_module cooldowntest "${BARE1}"
workbench_sync_module cooldowntest add >/tmp/wb-cooldown-1.log 2>&1
SHA1="$(git -C "${SRC1}" rev-parse v1.0.0)"
RESOLVED1="$(workbench_module_conf_get cooldowntest RESOLVED_SHA "")"
if [[ "${RESOLVED1}" == "${SHA1}" ]]; then
    ok "reason=add: v1.0.0 adopted immediately"
else
    fail "reason=add: RESOLVED_SHA is '${RESOLVED1}', expected ${SHA1} — see /tmp/wb-cooldown-1.log"
fi
if grep -qP "^\S+\tadopt\tcooldowntest\t" "${ADOPTION_LOG}" 2>/dev/null; then
    ok "reason=add: an 'adopt' line is in adoption.log"
else
    fail "reason=add: no 'adopt' line found in adoption.log"
    cat "${ADOPTION_LOG}" 2>/dev/null
fi

# ── 2. New tag, scheduled sync → not adopted; PENDING_SHA=new sha;
#    cooldown-start logged ─────────────────────────────────────────────────
add_tag "${SRC1}" v1.1.0
SHA2="$(git -C "${SRC1}" rev-parse v1.1.0)"
workbench_sync_module cooldowntest scheduled >/tmp/wb-cooldown-2.log 2>&1
RESOLVED2="$(workbench_module_conf_get cooldowntest RESOLVED_SHA "")"
if [[ "${RESOLVED2}" == "${SHA1}" ]]; then
    ok "reason=scheduled: v1.1.0 not adopted — still on v1.0.0"
else
    fail "reason=scheduled: RESOLVED_SHA advanced to '${RESOLVED2}', expected it to stay ${SHA1}"
fi
PENDING2="$(workbench_module_conf_get cooldowntest PENDING_SHA "")"
if [[ "${PENDING2}" == "${SHA2}" ]]; then
    ok "reason=scheduled: PENDING_SHA = the new (v1.1.0) sha"
else
    fail "reason=scheduled: PENDING_SHA is '${PENDING2}', expected ${SHA2}"
fi
if grep -qP "^\S+\tcooldown-start\tcooldowntest\t" "${ADOPTION_LOG}" 2>/dev/null; then
    ok "reason=scheduled: a 'cooldown-start' line is in adoption.log"
else
    fail "reason=scheduled: no 'cooldown-start' line found in adoption.log"
fi

# ── 3. Rewrite PENDING_SINCE to now - 3*86400 - 1, scheduled sync → adopted;
#    PENDING_* empty ───────────────────────────────────────────────────────
PAST=$(( $(date +%s) - (3 * 86400) - 1 ))
workbench_module_conf_set cooldowntest PENDING_SINCE "${PAST}"
workbench_sync_module cooldowntest scheduled >/tmp/wb-cooldown-3.log 2>&1
RESOLVED3="$(workbench_module_conf_get cooldowntest RESOLVED_SHA "")"
if [[ "${RESOLVED3}" == "${SHA2}" ]]; then
    ok "cooldown elapsed: v1.1.0 adopted"
else
    fail "cooldown elapsed: RESOLVED_SHA is '${RESOLVED3}', expected ${SHA2} — see /tmp/wb-cooldown-3.log"
fi
PENDING3="$(workbench_module_conf_get cooldowntest PENDING_SHA "")"
PENDING_SINCE3="$(workbench_module_conf_get cooldowntest PENDING_SINCE "")"
if [[ -z "${PENDING3}" && -z "${PENDING_SINCE3}" ]]; then
    ok "cooldown elapsed: PENDING_SHA/PENDING_SINCE cleared"
else
    fail "cooldown elapsed: PENDING_SHA/PENDING_SINCE not cleared ('${PENDING3}' / '${PENDING_SINCE3}')"
fi

# ── 4. New tag, scheduled sync (pending), then manual sync → adopted
#    immediately ───────────────────────────────────────────────────────────
BARE4="${WORK}/bare4.git"
SRC4="${WORK}/src4"
make_bare_repo_with_tag "${BARE4}" "${SRC4}" v1.0.0
setup_module manualadopt "${BARE4}"
workbench_sync_module manualadopt add >/tmp/wb-cooldown-4a.log 2>&1
add_tag "${SRC4}" v1.1.0
SHA4="$(git -C "${SRC4}" rev-parse v1.1.0)"
workbench_sync_module manualadopt scheduled >/tmp/wb-cooldown-4b.log 2>&1
workbench_sync_module manualadopt manual >/tmp/wb-cooldown-4c.log 2>&1
RESOLVED4="$(workbench_module_conf_get manualadopt RESOLVED_SHA "")"
if [[ "${RESOLVED4}" == "${SHA4}" ]]; then
    ok "reason=manual: adopts a pending release immediately, bypassing cooldown"
else
    fail "reason=manual: RESOLVED_SHA is '${RESOLVED4}', expected ${SHA4} — see /tmp/wb-cooldown-4c.log"
fi

# ── 5. RELEASE_COOLDOWN_DAYS=0 → scheduled sync adopts immediately ─────────
mkdir -p "$(dirname "${XDG_CONFIG_HOME}/workbench/core/scheduler.conf")"
echo "RELEASE_COOLDOWN_DAYS=0" > "${XDG_CONFIG_HOME}/workbench/core/scheduler.conf"
BARE5="${WORK}/bare5.git"
SRC5="${WORK}/src5"
make_bare_repo_with_tag "${BARE5}" "${SRC5}" v1.0.0
setup_module disabledcooldown "${BARE5}"
workbench_sync_module disabledcooldown add >/tmp/wb-cooldown-5a.log 2>&1
add_tag "${SRC5}" v1.1.0
SHA5="$(git -C "${SRC5}" rev-parse v1.1.0)"
workbench_sync_module disabledcooldown scheduled >/tmp/wb-cooldown-5b.log 2>&1
RESOLVED5="$(workbench_module_conf_get disabledcooldown RESOLVED_SHA "")"
if [[ "${RESOLVED5}" == "${SHA5}" ]]; then
    ok "RELEASE_COOLDOWN_DAYS=0: scheduled sync adopts immediately"
else
    fail "RELEASE_COOLDOWN_DAYS=0: RESOLVED_SHA is '${RESOLVED5}', expected ${SHA5} — see /tmp/wb-cooldown-5b.log"
fi
rm -f "${XDG_CONFIG_HOME}/workbench/core/scheduler.conf"

# ── 6. New tag, scheduled sync (pending), delete the tag upstream,
#    scheduled sync → up to date, PENDING_SHA cleared ──────────────────────
BARE6="${WORK}/bare6.git"
SRC6="${WORK}/src6"
make_bare_repo_with_tag "${BARE6}" "${SRC6}" v1.0.0
setup_module withdrawn "${BARE6}"
workbench_sync_module withdrawn add >/tmp/wb-cooldown-6a.log 2>&1
add_tag "${SRC6}" v1.1.0
SHA6="$(git -C "${SRC6}" rev-parse v1.1.0)"
workbench_sync_module withdrawn scheduled >/tmp/wb-cooldown-6b.log 2>&1
PENDING6="$(workbench_module_conf_get withdrawn PENDING_SHA "")"
if [[ "${PENDING6}" == "${SHA6}" ]]; then
    ok "withdrawn: v1.1.0 is pending before it's withdrawn"
else
    fail "withdrawn: PENDING_SHA is '${PENDING6}', expected ${SHA6} before withdrawal"
fi
( cd "${SRC6}" && git push -q origin :refs/tags/v1.1.0 )
workbench_sync_module withdrawn scheduled >/tmp/wb-cooldown-6c.log 2>&1
if grep -q "up to date" /tmp/wb-cooldown-6c.log; then
    ok "withdrawn: resolves back to up-to-date once the tag is deleted upstream"
else
    fail "withdrawn: did not report up to date after the tag was withdrawn — see /tmp/wb-cooldown-6c.log"
    cat /tmp/wb-cooldown-6c.log
fi
PENDING6B="$(workbench_module_conf_get withdrawn PENDING_SHA "")"
if [[ -z "${PENDING6B}" ]]; then
    ok "withdrawn: PENDING_SHA cleared"
else
    fail "withdrawn: PENDING_SHA is still '${PENDING6B}', expected cleared"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
