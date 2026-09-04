#!/usr/bin/env bash
# tests/check-wb-track-parsing.sh — regression check for `wb track`'s
# <name>-vs-flag argument parsing (ARCHITECTURE.md §9.2/§10).
#
# A missing <name> whose slot gets filled by the first flag instead (e.g.
# `wb track --latest` with nothing else) must be caught as a missing-name
# error, not fall through to "'<flag>' is not registered — run 'wb add
# <flag>' first" — traced to lib/modules/track.sh capturing $1
# unconditionally as <name> regardless of whether it looks like a flag.
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

# shellcheck source=lib/sync/engine.sh
source "${REPO_ROOT}/lib/sync/engine.sh"
# shellcheck source=lib/modules/track.sh
source "${REPO_ROOT}/lib/modules/track.sh"

# Isolate this test from real network/git activity — only track.sh's own
# parsing/validation logic is under test here. _wb_maybe_reconverge_core is
# normally defined in bin/wb (not sourced standalone here); track.sh's own
# guard skips calling it when undefined, but that guard's exit status would
# otherwise leak out as workbench_cmd_track's own return code — stub it so
# this test observes track.sh's real result, matching how bin/wb always
# sees it in production.
workbench_sync_module() { return 0; }
_wb_maybe_reconverge_core() { return 0; }

setup_module() {
    local name="$1" mode="$2"
    mkdir -p "$(workbench_module_dir "${name}")"
    cat > "$(workbench_module_conf_path "${name}")" <<EOF
TRACK_MODE=${mode}
REGISTERED=true
SYNC_ENABLED=true
EOF
}
setup_module core "branch:main"

# ── 1. No arguments at all — unchanged pre-existing behaviour. ─────────────
out="$(workbench_cmd_track 2>&1)"; rc=$?
# shellcheck disable=SC2015
[[ "${rc}" -eq 2 ]] && echo "${out}" | grep -qi "usage: wb track <name>" \
    && ok "no args at all: exit 2 with the usage line" \
    || fail "no args at all: unexpected result (rc=${rc}): ${out}"

# ── 2. A known flag in the <name> slot ('wb track --latest') gets a
#    targeted 'did you mean' hint, not the not-registered path. ────────────
out="$(workbench_cmd_track --latest 2>&1)"; rc=$?
if [[ "${rc}" -eq 2 ]] && echo "${out}" | grep -qi "did you mean 'wb track <module> --latest'"; then
    ok "'wb track --latest' (no name): targeted did-you-mean hint"
else
    fail "'wb track --latest' (no name): missing hint (rc=${rc}): ${out}"
fi
if echo "${out}" | grep -qi "is not registered\|wb add"; then
    fail "'wb track --latest' (no name): still mentions the misleading 'wb add' path"
else
    ok "'wb track --latest' (no name): no more misleading 'wb add' suggestion"
fi

# ── 3. Same for the other three flags. ──────────────────────────────────────
for flag in --branch --tag --commit; do
    out="$(workbench_cmd_track "${flag}" 2>&1)"; rc=$?
    # shellcheck disable=SC2015
    [[ "${rc}" -eq 2 ]] && echo "${out}" | grep -qi "did you mean 'wb track <module> ${flag}'" \
        && ok "'wb track ${flag}' (no name): targeted did-you-mean hint" \
        || fail "'wb track ${flag}' (no name): missing hint (rc=${rc}): ${out}"
done

# ── 4. An unrecognised '--*' token in the <name> slot falls back to the
#    generic usage line, not a fabricated 'did you mean'. ──────────────────
out="$(workbench_cmd_track --bogus 2>&1)"; rc=$?
if [[ "${rc}" -eq 2 ]] && echo "${out}" | grep -qi "usage: wb track <name>" && ! echo "${out}" | grep -qi "did you mean"; then
    ok "'wb track --bogus' (no name): generic usage line, no fabricated hint"
else
    fail "'wb track --bogus' (no name): unexpected result (rc=${rc}): ${out}"
fi

# ── 5. A genuinely unregistered (non-flag) name still gets the real
#    not-registered path — this fix must not touch that case. ─────────────
out="$(workbench_cmd_track ghost --latest 2>&1)"; rc=$?
# shellcheck disable=SC2015
[[ "${rc}" -eq 1 ]] && echo "${out}" | grep -q "'ghost' is not registered — run 'wb add ghost' first" \
    && ok "unregistered real name: still reports not-registered, suggesting 'wb add ghost'" \
    || fail "unregistered real name: unexpected result (rc=${rc}): ${out}"

# ── 6. Happy path is unaffected: 'wb track core --latest' still works. ─────
workbench_cmd_track core --latest >/tmp/wb-track-happy.log 2>&1; rc=$?
mode_after="$(workbench_module_conf_get core TRACK_MODE latest)"
if [[ "${rc}" -eq 0 && "${mode_after}" == "latest" ]]; then
    ok "'wb track core --latest': still sets TRACK_MODE=latest and exits 0"
else
    fail "'wb track core --latest': unexpected result (rc=${rc}, mode=${mode_after})"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
