#!/usr/bin/env bash
# tests/check-wb-lazy-load.sh — Fix 3 acceptance check (docs/decisions-log.md
# D65): bin/wb's _wb_require lazy-source helper and the trimmed always-load
# list.
#
# Three of the heaviest, least-often-needed lib files
# (distribution/fetch-tarball.sh, ssh/bootstrap.sh, sync/scheduler.sh) are
# no longer sourced unconditionally by bin/wb's own always-load pass —
# only the specific code path that actually needs each one requires it,
# the first time that path actually runs. This asserts: none of the three
# is loaded right after sourcing bin/wb with no dispatch yet; each becomes
# loaded once its own real trigger path runs; and _wb_require's own
# idempotency (source at most once per process, no matter how many call
# sites ask for the same path).
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
export XDG_CACHE_HOME="${WORK}/cache"
mkdir -p "${HOME}"

WB="${REPO_ROOT}/bin/wb"

# ── Source bin/wb with positional args cleared, so its own top-level
#    dispatch just prints the usage block (harmless) instead of trying to
#    run a real command — same pattern as tests/check-core-auto-apply.sh. ──
set --
# shellcheck source=bin/wb
source "${WB}" >/tmp/wb-lazy-load-source.log 2>&1

# ── 1. None of the three sampled lazy files is loaded right after
#    sourcing bin/wb, before any dispatch has run. Checked against
#    "lib/<path>", matching every file's own self-registration
#    convention (docs/decisions-log.md D18) — _wb_require's own comment
#    explains why. ────────────────────────────────────────────────────────
for f in lib/distribution/fetch-tarball.sh lib/ssh/bootstrap.sh lib/sync/scheduler.sh; do
    if _workbench_script_version_registered "${f}"; then
        fail "'${f}' is already registered as loaded immediately after sourcing bin/wb — the always-load list is not as trimmed as expected"
    else
        ok "'${f}' is NOT yet loaded immediately after sourcing bin/wb"
    fi
done

# ── 2. workbench_sync_module (the shared fetch/sync entry point) lazily
#    requires distribution/fetch-tarball.sh the moment a real sync runs. ───
SRC="${WORK}/src"
BARE="${WORK}/bare.git"
mkdir -p "${SRC}"
git init -q --bare "${BARE}" >/dev/null 2>&1
git clone -q "${BARE}" "${SRC}" >/dev/null 2>&1
(
    cd "${SRC}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    echo 'lazyfix-fn() { :; }' > shell/lazyfix.sh
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/lazyfix.sh
      tier: tools
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
) >/tmp/wb-lazy-load-fixture.log 2>&1

# modules/add.sh is lazy-loaded too, but it's not one of the three files
# under test here — require it explicitly to call workbench_cmd_add
# directly, the same as bin/wb's own 'add' dispatch arm does.
_wb_require modules/add.sh
workbench_cmd_add lazyfix-module "${BARE}" --private >/tmp/wb-lazy-load-add.log 2>&1

if _workbench_script_version_registered lib/distribution/fetch-tarball.sh; then
    ok "distribution/fetch-tarball.sh became loaded after a real workbench_sync_module run (via 'wb add')"
else
    fail "distribution/fetch-tarball.sh is still not loaded after a real sync ran"
    cat /tmp/wb-lazy-load-add.log
fi

# ── 3. 'wb add --private' lazily requires ssh/bootstrap.sh. ────────────────
if _workbench_script_version_registered lib/ssh/bootstrap.sh; then
    ok "ssh/bootstrap.sh became loaded after 'wb add --private' ran"
else
    fail "ssh/bootstrap.sh is still not loaded after a private 'wb add' ran"
    cat /tmp/wb-lazy-load-add.log
fi

# ── 4. 'wb scheduler status' lazily requires sync/scheduler.sh. ────────────
_wb_cmd_scheduler status >/tmp/wb-lazy-load-scheduler.log 2>&1
if _workbench_script_version_registered lib/sync/scheduler.sh; then
    ok "sync/scheduler.sh became loaded after 'wb scheduler status' ran"
else
    fail "sync/scheduler.sh is still not loaded after 'wb scheduler status' ran"
    cat /tmp/wb-lazy-load-scheduler.log
fi

# ── 5. _wb_require called twice for the same path only sources it once —
#    a load counter in a throwaway fixture file, same technique as
#    tests/check-availability-timeout.sh's call-counting probe. Points LIB
#    at a scratch directory so this doesn't touch the real lib/ tree; LIB
#    is a plain (non-readonly) assignment in bin/wb. ───────────────────────
FIXTURE_LIB="${WORK}/fixture-lib"
mkdir -p "${FIXTURE_LIB}"
REQUIRE_COUNTER="${WORK}/require-counter.log"
cat > "${FIXTURE_LIB}/counted.sh" <<EOF
echo call >> "${REQUIRE_COUNTER}"
# Registers itself exactly like every real lib file's own bottom line —
# "lib/counted.sh", not the bare lib-relative "counted.sh" passed to
# _wb_require — so _wb_require's own dedup check
# (_workbench_script_version_registered "lib/<path>") has something real
# to find on the second call, the same convention every real lib file
# under lib/ actually uses (docs/decisions-log.md D18).
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/counted.sh" "0.1.0" || true
EOF

LIB="${FIXTURE_LIB}"
_wb_require counted.sh
_wb_require counted.sh
_wb_require counted.sh

require_count="$(wc -l < "${REQUIRE_COUNTER}" 2>/dev/null | tr -d ' ')"
require_count="${require_count:-0}"
if [[ "${require_count}" -eq 1 ]]; then
    ok "_wb_require called three times for the same path sourced it exactly once"
else
    fail "counted.sh was sourced ${require_count} time(s), expected exactly 1"
    cat "${REQUIRE_COUNTER}" 2>/dev/null
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
