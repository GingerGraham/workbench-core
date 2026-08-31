#!/usr/bin/env bash
# tests/check-wb-help.sh — Action 2 acceptance check (follow-up brief:
# "workbench-core follow-up: core auto-reconvergence + wb help").
#
# Covers: every dispatch-case command has detail reachable via both
# `wb help <command>` and `wb <command> --help`/`-h`, with matching output;
# an unknown command degrades gracefully instead of erroring; the four
# top-level forms (`wb`, `wb help`, `wb -h`, `wb --help`) agree; and the
# top-level block actually contains the disambiguating text this rewrite
# exists to add (update/apply, track/dev).
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
mkdir -p "${HOME}"

# ── 1. Every command in the dispatch case has detail reachable both ways,
#    and both forms agree exactly. 'help' is excluded from the --help/-h
#    equivalence: 'wb help --help' passes the literal string '--help' as the
#    command name to look up (there is no argument-form equivalent of "help
#    about the help command" the way there is for every real command), so
#    it's checked separately below instead. ─────────────────────────────────
COMMANDS=(install apply add remove track dev sync update status functions version)

for cmd in "${COMMANDS[@]}"; do
    via_help="$(bash "${WB}" help "${cmd}" 2>&1)"
    via_flag_long="$(bash "${WB}" "${cmd}" --help 2>&1)"
    via_flag_short="$(bash "${WB}" "${cmd}" -h 2>&1)"

    if [[ -z "${via_help}" ]]; then
        fail "'wb help ${cmd}' produced no output"
    else
        ok "'wb help ${cmd}' produces detail"
    fi

    if [[ "${via_help}" == "${via_flag_long}" ]]; then
        ok "'wb help ${cmd}' and 'wb ${cmd} --help' agree"
    else
        fail "'wb help ${cmd}' and 'wb ${cmd} --help' differ"
    fi

    if [[ "${via_help}" == "${via_flag_short}" ]]; then
        ok "'wb help ${cmd}' and 'wb ${cmd} -h' agree"
    else
        fail "'wb help ${cmd}' and 'wb ${cmd} -h' differ"
    fi
done

via_help_help="$(bash "${WB}" help help 2>&1)"
if [[ -n "${via_help_help}" ]] && ! echo "${via_help_help}" | grep -qi "unknown command"; then
    ok "'wb help help' produces its own detail (not the unknown-command fallback)"
else
    fail "'wb help help' did not produce detail: ${via_help_help}"
fi

# ── 2. Unknown command degrades gracefully — no crash, top-level block +
#    note, and (specifically for plain `wb help <unknown>`) exit 0, unlike
#    an actually-invalid top-level command. ─────────────────────────────────
top_level="$(bash "${WB}" 2>&1)"

out_help_unknown="$(bash "${WB}" help totally-bogus 2>&1)"
rc_help_unknown=$?
if [[ "${rc_help_unknown}" -eq 0 ]]; then
    ok "'wb help <unknown>' exits 0 (does not error like an invalid top-level command)"
else
    fail "'wb help <unknown>' exited non-zero (${rc_help_unknown})"
fi
if echo "${out_help_unknown}" | grep -qi "unknown command 'totally-bogus'" && echo "${out_help_unknown}" | grep -qF "${top_level}" >/dev/null; then
    ok "'wb help <unknown>' prints an unknown-command note plus the top-level block"
else
    fail "'wb help <unknown>' did not print the expected note + top-level block: ${out_help_unknown}"
fi

out_flag_unknown="$(bash "${WB}" totally-bogus --help 2>&1)"
if echo "${out_flag_unknown}" | grep -qi "unknown command 'totally-bogus'"; then
    ok "'wb <unknown> --help' also degrades gracefully with the same note"
else
    fail "'wb <unknown> --help' did not degrade gracefully: ${out_flag_unknown}"
fi

out_invalid="$(bash "${WB}" totally-bogus 2>&1)"
rc_invalid=$?
if [[ "${rc_invalid}" -ne 0 ]]; then
    ok "a plain invalid top-level command ('wb totally-bogus') still exits non-zero, unlike 'wb help totally-bogus'"
else
    fail "'wb totally-bogus' unexpectedly exited 0"
fi

# ── 3. Top-level `wb` / `wb help` / `wb -h` / `wb --help` all agree. ────────
out_bare="$(bash "${WB}" 2>&1)"
out_help="$(bash "${WB}" help 2>&1)"
out_h="$(bash "${WB}" -h 2>&1)"
out_help_flag="$(bash "${WB}" --help 2>&1)"

if [[ "${out_bare}" == "${out_help}" && "${out_bare}" == "${out_h}" && "${out_bare}" == "${out_help_flag}" ]]; then
    ok "'wb' / 'wb help' / 'wb -h' / 'wb --help' all produce identical output"
else
    fail "top-level invocations did not all agree"
fi

# ── 4. Content checks — the top-level block must actually disambiguate the
#    pairs this rewrite exists to fix. Pinned here so future wording edits
#    can't silently drop the distinction. ───────────────────────────────────
if echo "${out_bare}" | grep -qi "host-level setup" && echo "${out_bare}" | grep -qi "code-level only"; then
    ok "top-level block distinguishes 'update' (code-level) from 'apply' (host-level)"
else
    fail "top-level block does not clearly distinguish update vs apply"
fi

if echo "${out_bare}" | grep -qi "auto-triggers 'wb apply'"; then
    ok "top-level block mentions core update auto-triggering convergence (Action 1)"
else
    fail "top-level block does not mention core's auto-triggered convergence"
fi

if echo "${out_bare}" | grep -qi "wrapping 'track'"; then
    ok "top-level block identifies 'dev' as a wrapper over 'track'"
else
    fail "top-level block does not distinguish track vs dev"
fi

if echo "${out_bare}" | grep -qi "independent of WHAT it tracks"; then
    ok "top-level block distinguishes 'sync enable|disable' from 'track'"
else
    fail "top-level block does not distinguish sync enable|disable vs track"
fi

# ── 5. Per-command detail also carries the cross-reference (the actual fix
#    for the underlying confusion, per the brief — the top-level block alone
#    is not enough). ─────────────────────────────────────────────────────────
help_update="$(bash "${WB}" help update 2>&1)"
echo "${help_update}" | grep -qi "confused with 'wb apply'" && ok "'wb help update' cross-references 'wb apply'" \
    || fail "'wb help update' is missing the update/apply cross-reference"

help_apply="$(bash "${WB}" help apply 2>&1)"
echo "${help_apply}" | grep -qi "update core" && ok "'wb help apply' cross-references 'wb update core'" \
    || fail "'wb help apply' is missing the apply/update cross-reference"

help_track="$(bash "${WB}" help track 2>&1)"
echo "${help_track}" | grep -qi "confused with 'wb dev'" && ok "'wb help track' cross-references 'wb dev'" \
    || fail "'wb help track' is missing the track/dev cross-reference"

help_dev="$(bash "${WB}" help dev 2>&1)"
echo "${help_dev}" | grep -qi "confused with 'wb track'" && ok "'wb help dev' cross-references 'wb track'" \
    || fail "'wb help dev' is missing the dev/track cross-reference"

help_sync="$(bash "${WB}" help sync 2>&1)"
echo "${help_sync}" | grep -qi "confused with 'wb track'" && ok "'wb help sync' cross-references 'wb track'" \
    || fail "'wb help sync' is missing the sync/track cross-reference"

help_install="$(bash "${WB}" help install 2>&1)"
echo "${help_install}" | grep -qi "confused with 'wb apply'" && ok "'wb help install' cross-references 'wb apply'" \
    || fail "'wb help install' is missing the install/apply cross-reference"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
