#!/usr/bin/env bash
# tests/check-availability-timeout.sh — Fix 2 acceptance check
# (docs/decisions-log.md D65): _wb_run_with_timeout/_wb_cache_bool wired
# into _wb_function_available.
#
# A hand-written "_<name>-available" predicate that hangs past
# WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS must be killed rather than
# blocking `wb functions` indefinitely — the gated name is then hidden
# (same as any predicate reporting unavailable) and named in a warning
# line. Separately, _wb_cache_bool lets several predicates share one
# expensive real check: this asserts the underlying command runs exactly
# once per `wb functions` invocation even when two different predicates
# both ask for it under the same cache key.
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

WB="${REPO_ROOT}/bin/wb"

# A real, external, call-counting script — deliberately NOT inside the
# fixture module's own repo (which gets fetched into a throwaway snapshot
# dir), so its call count log lives at a fixed, stable path this test can
# read back regardless of where the module's snapshot lands.
COUNTER_LOG="${WORK}/cache-counter.log"
COUNTER_SCRIPT="${WORK}/counter.sh"
cat > "${COUNTER_SCRIPT}" <<EOF
#!/usr/bin/env bash
echo call >> "${COUNTER_LOG}"
exit 0
EOF
chmod +x "${COUNTER_SCRIPT}"

# ── Synthetic module: one predicate that sleeps well past the timeout
#    (must be killed, hidden, and named in the warning), and two more
#    predicates sharing one _wb_cache_bool key wrapping the call-counting
#    script above (the real check must run exactly once). ─────────────────
SRC="${WORK}/src"
BARE="${WORK}/bare.git"
mkdir -p "${SRC}"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}"
(
    cd "${SRC}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    cat > shell/timeoutfix.sh <<EOF
slow-thing() { :; }
_slow-thing-available() { sleep 5; }

fast-thing() { :; }

cached-thing-a() { :; }
_cached-thing-a-available() { _wb_cache_bool shared-probe -- "${COUNTER_SCRIPT}"; }

cached-thing-b() { :; }
_cached-thing-b-available() { _wb_cache_bool shared-probe -- "${COUNTER_SCRIPT}"; }
EOF
    cat > .dotfiles-sync.yml <<'MANIFEST'
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/timeoutfix.sh
      tier: tools
MANIFEST
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)

bash "${WB}" add timeoutfix-module "${BARE}" --private >/tmp/wb-availability-timeout-add.log 2>&1

# ── 1. A predicate that hangs past the timeout doesn't block 'wb
#    functions' indefinitely — asserted by wall-clock duration, well
#    under the predicate's own 5s sleep. ────────────────────────────────────
export WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS=1
START_TS="$(date +%s)"
FUNCTIONS_OUT="$(bash "${WB}" functions 2>&1)"
END_TS="$(date +%s)"
ELAPSED=$((END_TS - START_TS))

if [[ "${ELAPSED}" -le 3 ]]; then
    ok "'wb functions' completed in ${ELAPSED}s — the hung predicate (5s sleep) was killed at the ${WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS}s timeout, not waited out"
else
    fail "'wb functions' took ${ELAPSED}s — the timeout does not appear to have killed the hung predicate"
fi

# ── 2. The timed-out name is hidden, same as any predicate reporting
#    unavailable. ───────────────────────────────────────────────────────────
if echo "${FUNCTIONS_OUT}" | grep -v '^\[WARN\]' | grep -q "slow-thing"; then
    fail "'wb functions' listed slow-thing — its predicate hung past the timeout and should have been hidden"
    echo "${FUNCTIONS_OUT}"
else
    ok "'wb functions' hides a name whose predicate hung past the timeout (outside the warning line itself)"
fi

if echo "${FUNCTIONS_OUT}" | grep -q "fast-thing"; then
    ok "'wb functions' still lists fast-thing (no predicate, unaffected by the timeout)"
else
    fail "'wb functions' did not list fast-thing"
    echo "${FUNCTIONS_OUT}"
fi

# ── 3. The warning line names the timed-out predicate by name. ─────────────
if echo "${FUNCTIONS_OUT}" | grep -q "predicate(s) for \[slow-thing\]" \
    && echo "${FUNCTIONS_OUT}" | grep -q "exceeded ${WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS}s"; then
    ok "warning line names slow-thing and the timeout that was exceeded"
else
    fail "warning line did not name the timed-out predicate as expected"
    echo "${FUNCTIONS_OUT}"
fi

# ── 4. Two predicates sharing one _wb_cache_bool key: the real check runs
#    exactly once per 'wb functions' invocation, not once per name. ────────
CALL_COUNT="$(wc -l < "${COUNTER_LOG}" 2>/dev/null | tr -d ' ')"
CALL_COUNT="${CALL_COUNT:-0}"
if [[ "${CALL_COUNT}" -eq 1 ]]; then
    ok "the shared probe behind cached-thing-a/cached-thing-b ran exactly once"
else
    fail "the shared probe ran ${CALL_COUNT} time(s), expected exactly 1"
    cat "${COUNTER_LOG}" 2>/dev/null
fi

if echo "${FUNCTIONS_OUT}" | grep -q "cached-thing-a" && echo "${FUNCTIONS_OUT}" | grep -q "cached-thing-b"; then
    ok "both cache-sharing names show as available (the shared probe succeeded)"
else
    fail "cached-thing-a/cached-thing-b were not both listed as available"
    echo "${FUNCTIONS_OUT}"
fi

# ── 5. WORKBENCH_FUNCTIONS_SHOW_ALL bypass path stays fast and unaffected
#    — it never even calls the predicate, so the hung one can't slow it
#    down either. ────────────────────────────────────────────────────────────
START_TS2="$(date +%s)"
ALL_OUT="$(WORKBENCH_FUNCTIONS_SHOW_ALL=true bash "${WB}" functions 2>&1)"
END_TS2="$(date +%s)"
ELAPSED2=$((END_TS2 - START_TS2))
if [[ "${ELAPSED2}" -le 3 ]] && echo "${ALL_OUT}" | grep -q "slow-thing"; then
    ok "WORKBENCH_FUNCTIONS_SHOW_ALL=true stays fast (${ELAPSED2}s) and shows slow-thing regardless of its predicate"
else
    fail "WORKBENCH_FUNCTIONS_SHOW_ALL=true did not behave as expected (elapsed=${ELAPSED2}s)"
    echo "${ALL_OUT}"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
