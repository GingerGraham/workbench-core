#!/usr/bin/env bash
# .github/scripts/ecosystem/check-ecosystem.sh
#
# Ecosystem smoke test (docs/decisions-log.md D99). Module CI tests each
# module with only core installed (D40); the bugs found since were in shell
# start, zsh and cross-module listings, and showed only with many modules
# installed together. This installs the whole 'full' bundle the way a user
# gets it — every module at the catalog's latest release — on top of the
# core checkout under test, into an isolated HOME, and checks:
#
#   1. every module in 'full' is registered, with a RESOLVED_SHA;
#   2. interactive bash and zsh start with empty stderr (bash's two
#      job-control lines aside) and a WORKBENCH_LOADER_PATH that names an
#      existing file — with a bare PATH, then the runner's PATH;
#   3. in both shells, every module's register.getters[] function exits 0
#      and lists at least one of that module's own names;
#   4. 'wb functions --no-pager' shows no "module gave no reason" and no
#      timed-out predicate;
#   5. 'wb tools list --status' reports no unresponsive tool, apart from
#      the allowlist below;
#   6. for git, gpg, ssh and shell: 'wb remove <m> --restore --yes', a
#      clean zsh start, 'wb add <m> --keep-files', a clean zsh start;
#   7. 'wb update' exits 0.
#
# Usage: check-ecosystem.sh   (from anywhere; uses the checkout it lives in)
# Set WORKBENCH_GITHUB_TOKEN to authenticate the GitHub API calls.
# Prints numbered OK:/FAIL: lines, and the captured stderr and getter output
# of anything that failed; exits non-zero if any check failed.
#
# GitHub-runner-only script (Bash 4+ allowed per AGENTS.md), kept to bash
# 3.2 anyway so it runs locally on macOS too.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CORE_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd)"
WB="${CORE_ROOT}/bin/wb"

# `unresponsive` in 'wb tools list --status' is allowed only for these
# friendly names. Each must also be an *accepted* row in the launch ledger
# (reviews/launch-ledger-2026-10-26.md):
#   bitwarden (workbench-security) — no reliable installed check across its
#   four install paths; documented in that module's README.
UNRESPONSIVE_ALLOWED="bitwarden"

# The modules step 6 removes and re-adds: the ones that write into the
# user's own config files (layers, whole files) as well as shell content.
READD_MODULES="git gpg ssh shell"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [ecosystem ${check_no}] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [ecosystem ${check_no}] $*"; FAILED=$((FAILED + 1)); }
indent() { sed "s/^/        $1/"; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
SCRATCH="${WORK}/scratch"
mkdir -p "${SCRATCH}"

export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
export XDG_CACHE_HOME="${WORK}/cache"
mkdir -p "${HOME}" "${XDG_DATA_HOME}" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"

# bin/wb is sourceable: it defines its commands and _wb_require without
# running anything. The catalog needs its module-name validation.
# shellcheck source=bin/wb
source "${WB}" >/dev/null 2>&1
_wb_require modules/catalog.sh
# shellcheck source=lib/manifest/parse.sh
source "${CORE_ROOT}/lib/manifest/parse.sh"
# shellcheck source=lib/core/prereqs.sh
source "${CORE_ROOT}/lib/core/prereqs.sh" >/dev/null 2>&1
# shellcheck source=lib/core/functions.sh
source "${CORE_ROOT}/lib/core/functions.sh" >/dev/null 2>&1
# shellcheck source=.github/scripts/module-ci/shell-checks-lib.sh
source "${CORE_ROOT}/.github/scripts/module-ci/shell-checks-lib.sh"

MODULES="$(workbench_catalog_bundle_modules full | tr "\n" " ")"
if [[ -z "${MODULES}" ]]; then
    fail "the 'full' bundle lists no modules — nothing to test"
    exit 1
fi

# ── Install ─────────────────────────────────────────────────────────────────
# An existing ~/.zshrc makes wb install write the zsh stubs (.zshrc and
# .zshenv), exactly as a zsh user's install does.
touch "${HOME}/.zshrc"
echo "ecosystem: wb install --bundle full --keep-files (core from ${CORE_ROOT})"
if "${WB}" install --bundle full --keep-files </dev/null >"${SCRATCH}/install.log" 2>&1; then
    ok "wb install --bundle full --keep-files exits 0"
else
    fail "wb install --bundle full --keep-files failed:"
    indent "" < "${SCRATCH}/install.log"
fi

# ── 1. Every module registered, with a resolved sha ─────────────────────────
unregistered=""
for m in ${MODULES}; do
    conf="${XDG_DATA_HOME}/workbench/modules/${m}/sync.conf"
    sha="$(grep -E '^RESOLVED_SHA=' "${conf}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
    [[ -n "${sha}" ]] || unregistered="${unregistered} ${m}"
done
if [[ -z "${unregistered}" ]]; then
    ok "every module in 'full' is registered with a RESOLVED_SHA: ${MODULES}"
else
    fail "not registered, or no RESOLVED_SHA:${unregistered}"
    indent "" < "${SCRATCH}/install.log"
fi

# ── Shells ──────────────────────────────────────────────────────────────────
# zsh on ubuntu comes from the workflow; macOS ships it.
BARE_BIN="${SCRATCH}/bare-bin"
_wb_ci_make_bare_bin "${BARE_BIN}"
SHELLS=""
for shell in bash zsh; do
    if [[ -x "${BARE_BIN}/${shell}" ]]; then
        SHELLS="${SHELLS} ${shell}"
    else
        fail "${shell} is not installed on this runner — the workflow must install it"
    fi
done

# check_start <label> <shell> <PATH> — the shell starts clean and the
# loader's own path survives the start.
check_start() {
    local label="$1" shell="$2" path="$3"
    local err="${SCRATCH}/${shell}-${label// /-}.err"
    _wb_ci_shell_start "${BARE_BIN}/${shell}" "${path}" "${_WB_CI_LOADER_PATH_CHECK}" "${err}" >/dev/null
    if [[ -z "$(_wb_ci_filtered_stderr "${err}")" ]]; then
        ok "${label}: interactive ${shell} starts with empty stderr and a valid WORKBENCH_LOADER_PATH"
    else
        fail "${label}: interactive ${shell} wrote to stderr:"
        _wb_ci_filtered_stderr "${err}" | indent ""
    fi
}

# ── 2. Clean starts ─────────────────────────────────────────────────────────
for shell in ${SHELLS}; do
    check_start "bare PATH" "${shell}" "${BARE_BIN}"
    check_start "runner PATH" "${shell}" "${PATH}"
done

# ── 3. Every getter lists its module's names, in both shells ───────────────
for m in ${MODULES}; do
    manifest="$(workbench_resolve_manifest_path "${XDG_DATA_HOME}/workbench/modules/${m}/current" 2>/dev/null)"
    [[ -n "${manifest}" && -f "${manifest}" ]] || continue
    getters=""
    while IFS='|' read -r _gname gfn _glabel; do
        [[ -n "${gfn}" ]] && getters="${getters} ${gfn}"
    done < <(workbench_manifest_register_getter_entries "${manifest}")
    [[ -n "${getters}" ]] || continue
    names="$(_wb_ci_module_names "${m}")"
    for shell in ${SHELLS}; do
        for fn in ${getters}; do
            out_file="${SCRATCH}/${shell}-${fn}.out"
            err_file="${SCRATCH}/${shell}-${fn}.err"
            _wb_ci_shell_start "${BARE_BIN}/${shell}" "${BARE_BIN}" "${fn}" "${err_file}" >"${out_file}"
            rc=$?
            if [[ "${rc}" -eq 0 ]] && _wb_ci_lists_a_module_name "${out_file}" "${names}"; then
                ok "${shell}: ${m}'s getter ${fn} exits 0 and lists the module's names"
            else
                fail "${shell}: ${m}'s getter ${fn} exited ${rc} or listed none of the module's names"
                indent "out: " < "${out_file}"
                _wb_ci_filtered_stderr "${err_file}" | indent "err: "
            fi
        done
    done
done

# ── 4. wb functions: every listed name has a reason, nothing timed out ─────
for shell in ${SHELLS}; do
    out_file="${SCRATCH}/${shell}-wb-functions.out"
    err_file="${SCRATCH}/${shell}-wb-functions.err"
    _wb_ci_shell_start "${BARE_BIN}/${shell}" "${BARE_BIN}" "wb functions --no-pager" "${err_file}" >"${out_file}"
    rc=$?
    problems="$(grep -hE 'module gave no reason|timed out|were killed' "${out_file}" "${err_file}")"
    if [[ "${rc}" -eq 0 && -z "${problems}" ]] && grep -q '\[INFO\]' "${out_file}"; then
        ok "${shell}: wb functions --no-pager exits 0, every unavailable name has a reason, nothing timed out"
    else
        fail "${shell}: wb functions --no-pager exited ${rc}, or lists names with no reason or a timed-out predicate:"
        if [[ -n "${problems}" ]]; then
            # The section for each problem line, so the names show.
            sed -E -n '/module gave no reason|timed out|were killed/,/^$/p' "${out_file}" | indent ""
            grep -E 'timed out|were killed' "${err_file}" | indent "err: "
        else
            indent "out: " < "${out_file}"
            _wb_ci_filtered_stderr "${err_file}" | indent "err: "
        fi
    fi
done

# ── 5. wb tools list --status: no unresponsive tool, bar the allowlist ─────
"${WB}" tools list --status </dev/null >"${SCRATCH}/tools.out" 2>"${SCRATCH}/tools.err"
rc=$?
unresponsive=""
allowed_seen=""
tools_seen=0
while read -r friendly func status; do
    case "${func}" in install-*) ;; *) continue ;; esac
    tools_seen=$((tools_seen + 1))
    [[ "${status}" == "unresponsive" ]] || continue
    case " ${UNRESPONSIVE_ALLOWED} " in
        *" ${friendly} "*) allowed_seen="${allowed_seen} ${friendly}" ;;
        *) unresponsive="${unresponsive} ${friendly}" ;;
    esac
done < "${SCRATCH}/tools.out"
if [[ "${rc}" -eq 0 && "${tools_seen}" -gt 0 && -z "${unresponsive}" ]]; then
    ok "wb tools list --status: ${tools_seen} tools, none unresponsive apart from the allowlist (seen:${allowed_seen:- none})"
else
    fail "wb tools list --status exited ${rc}, listed ${tools_seen} tools; unresponsive tools not on the allowlist:${unresponsive:- (none)}"
    indent "" < "${SCRATCH}/tools.out"
    indent "err: " < "${SCRATCH}/tools.err"
fi

# ── 6. Remove and re-add, with a clean zsh start after each ────────────────
zsh_clean_after() {
    local label="$1" err="${SCRATCH}/zsh-${1// /-}.err"
    if [[ ! -x "${BARE_BIN}/zsh" ]]; then
        fail "${label}: zsh is not installed"
        return
    fi
    _wb_ci_shell_start "${BARE_BIN}/zsh" "${PATH}" "${_WB_CI_LOADER_PATH_CHECK}" "${err}" >/dev/null
    if [[ -z "$(_wb_ci_filtered_stderr "${err}")" ]]; then
        ok "${label}: interactive zsh starts clean"
    else
        fail "${label}: interactive zsh wrote to stderr:"
        _wb_ci_filtered_stderr "${err}" | indent ""
    fi
}
for m in ${READD_MODULES}; do
    if "${WB}" remove "${m}" --restore --yes </dev/null >"${SCRATCH}/remove-${m}.log" 2>&1; then
        ok "wb remove ${m} --restore --yes exits 0"
    else
        fail "wb remove ${m} --restore --yes failed:"
        indent "" < "${SCRATCH}/remove-${m}.log"
    fi
    zsh_clean_after "after removing ${m}"
    if "${WB}" add "${m}" --keep-files </dev/null >"${SCRATCH}/add-${m}.log" 2>&1; then
        ok "wb add ${m} --keep-files exits 0"
    else
        fail "wb add ${m} --keep-files failed:"
        indent "" < "${SCRATCH}/add-${m}.log"
    fi
    zsh_clean_after "after re-adding ${m}"
done

# ── 7. wb update ────────────────────────────────────────────────────────────
if "${WB}" update </dev/null >"${SCRATCH}/update.log" 2>&1; then
    ok "wb update exits 0"
else
    fail "wb update failed:"
    indent "" < "${SCRATCH}/update.log"
fi

echo
echo "ecosystem: ${check_no} checks, ${FAILED} failed"
[[ "${FAILED}" -eq 0 ]]
