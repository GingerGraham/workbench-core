#!/usr/bin/env bash
# .github/scripts/module-ci/check-clean-shell.sh
#
# Clean-shell-start check (docs/decisions-log.md D94). Called by
# check-add-to-core.sh after its wb add / wb track / wb update steps, inside
# the same isolated HOME, with the module under test registered. Three
# checks:
#
#   1. Static rule: no register.shell file calls an install-* function
#      outside a comment line. Installer files are never sourced into the
#      user's shell; module code and messages say
#      'wb tools install|upgrade <name>'.
#   2. Clean start, tools absent: with a bare PATH (core's required prereqs
#      plus baseline utilities), interactive bash and zsh start with empty
#      stderr (bash's two job-control lines aside) and a
#      WORKBENCH_LOADER_PATH that names an existing file, and every
#      register.getters[] function exits 0 in each shell, lists at least
#      one of the module's own names (D98), and lists no name under
#      "module gave no reason" (D101).
#   3. Clean start, runner PATH: the same two shell starts with the
#      runner's normal PATH, stderr empty.
#
# Before the shell starts, 'wb apply' registers core from the core checkout
# under test and writes the real rc stubs — ~/.bashrc, ~/.zshrc and
# ~/.zshenv, as a zsh user's install does (D98) — so the shells load
# exactly what a user's would: core plus this module.
#
# Required env: WB, MODULE_NAME, MODULE_ROOT, and the HOME / XDG_DATA_HOME /
# XDG_CONFIG_HOME check-add-to-core.sh exported. Prints numbered OK:/FAIL:
# lines; exits non-zero if any check failed. Runs on GitHub-hosted runners
# only.
set -uo pipefail

: "${WB:?WB is required}"
: "${MODULE_NAME:?MODULE_NAME is required}"
: "${MODULE_ROOT:?MODULE_ROOT is required}"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [clean-shell ${check_no}] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [clean-shell ${check_no}] $*"; FAILED=$((FAILED + 1)); }

CORE_ROOT="$(cd -- "$(dirname -- "${WB}")/.." >/dev/null 2>&1 && pwd)"
# shellcheck source=lib/manifest/parse.sh
source "${CORE_ROOT}/lib/manifest/parse.sh"
# shellcheck source=lib/core/prereqs.sh
source "${CORE_ROOT}/lib/core/prereqs.sh" >/dev/null 2>&1
# log.sh and functions.sh for _extract_function_names/_extract_alias_names.
# shellcheck source=lib/core/log.sh
source "${CORE_ROOT}/lib/core/log.sh" >/dev/null 2>&1
# shellcheck source=lib/core/functions.sh
source "${CORE_ROOT}/lib/core/functions.sh" >/dev/null 2>&1
# Shared with the ecosystem smoke test (D99): the bare PATH, the shell
# start, the loader-path check and the module-name check.
# shellcheck source=.github/scripts/module-ci/shell-checks-lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/shell-checks-lib.sh"

MANIFEST="$(workbench_resolve_manifest_path "${MODULE_ROOT}")"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

# ── 1. Static rule ──────────────────────────────────────────────────────────
static_hits=""
while IFS='|' read -r src _tier; do
    [[ -z "${src}" ]] && continue
    file="${MODULE_ROOT}/${src}"
    [[ -f "${file}" ]] || continue
    hits="$(grep -nE '(^|[^A-Za-z0-9_-])install-[a-z0-9-]+' "${file}" \
        | grep -vE '^[0-9]+:[[:space:]]*#')"
    if [[ -n "${hits}" ]]; then
        static_hits="${static_hits}${src}:"$'\n'"${hits}"$'\n'
    fi
done < <(workbench_manifest_register_shell_entries "${MANIFEST}")
if [[ -z "${static_hits}" ]]; then
    ok "no register.shell file calls an install-* function (say 'wb tools install|upgrade <name>' instead)"
else
    fail "register.shell files call install-* functions — installer files are never sourced into the user's shell; use 'wb tools install|upgrade <name>':"
    printf '%s' "${static_hits}" | sed 's/^/        /'
fi

# ── Register core and write the rc stubs ────────────────────────────────────
# An existing ~/.zshrc is what makes wb apply write the zsh stubs, both
# ~/.zshrc and ~/.zshenv, exactly as a zsh user's install does (D98).
touch "${HOME}/.zshrc"
if "${WB}" apply </dev/null >"${SCRATCH}/apply.log" 2>&1; then
    ok "wb apply registered core and wrote the rc stubs"
else
    fail "wb apply failed — the shell-start checks below may be meaningless"
    cat "${SCRATCH}/apply.log"
fi
for rc in .bashrc .zshrc .zshenv; do
    if grep -qF "# workbench-core loader" "${HOME}/${rc}" 2>/dev/null; then
        ok "wb apply wrote the loader stub to ~/${rc}"
    else
        fail "wb apply did not write the loader stub to ~/${rc}"
    fi
done

# ── zsh on Linux runners ────────────────────────────────────────────────────
# Each module pins its own copy of module-ci.yml, and pins older than
# v2.21.0 have no "Install zsh" step, while this script always comes from
# core's latest release (D40). So install zsh here when it's missing rather
# than depend on the caller's workflow version (docs/decisions-log.md D95).
if ! command -v zsh &>/dev/null && [[ "$(uname -s)" == "Linux" ]] \
    && command -v apt-get &>/dev/null && sudo -n true 2>/dev/null; then
    echo "clean-shell: zsh not installed — installing it (apt-get)"
    sudo -n apt-get update -q >/dev/null 2>&1
    sudo -n apt-get install -y -q zsh >/dev/null 2>&1 \
        || echo "clean-shell: apt-get install zsh failed"
fi

# ── Bare PATH: core's required prereqs, baseline utilities, the shells ─────
BARE_BIN="${SCRATCH}/bare-bin"
_wb_ci_make_bare_bin "${BARE_BIN}"

check_start() {
    local label="$1" shell="$2" path="$3"
    local err="${SCRATCH}/${shell}-${label// /-}.err"
    # The command fails by name when the loader's own path didn't survive
    # the start (D98).
    _wb_ci_shell_start "${BARE_BIN}/${shell}" "${path}" "${_WB_CI_LOADER_PATH_CHECK}" "${err}" >/dev/null
    if [[ -z "$(_wb_ci_filtered_stderr "${err}")" ]]; then
        ok "${label}: interactive ${shell} starts with empty stderr and a valid WORKBENCH_LOADER_PATH"
    else
        fail "${label}: interactive ${shell} wrote to stderr:"
        _wb_ci_filtered_stderr "${err}" | sed 's/^/        /'
    fi
}

getters=()
while IFS='|' read -r _gname gfn _glabel; do
    [[ -n "${gfn}" ]] && getters+=("${gfn}")
done < <(workbench_manifest_register_getter_entries "${MANIFEST}")

# The module's own public names, from its registered shell files: what any
# working getter must show, either as usable or under "available once
# tooling is installed" (D98). Empty for a module that registers no names;
# then any [INFO] header is enough.
module_names="$(_wb_ci_module_names "${MODULE_NAME}")"

for shell in bash zsh; do
    if [[ ! -x "${BARE_BIN}/${shell}" ]]; then
        fail "${shell} is not installed on this runner — the workflow must install it"
        continue
    fi

    # ── 2. Clean start, tools absent ────────────────────────────────────────
    check_start "tools absent" "${shell}" "${BARE_BIN}"

    for fn in ${getters[@]+"${getters[@]}"}; do
        out_file="${SCRATCH}/${shell}-${fn}.out"
        err_file="${SCRATCH}/${shell}-${fn}.err"
        _wb_ci_shell_start "${BARE_BIN}/${shell}" "${BARE_BIN}" "${fn}" "${err_file}" >"${out_file}"
        rc=$?
        if [[ "${rc}" -eq 0 ]] && _wb_ci_lists_a_module_name "${out_file}" "${module_names}"; then
            ok "tools absent: ${shell}: getter ${fn} exits 0 and lists the module's names"
        else
            fail "tools absent: ${shell}: getter ${fn} exited ${rc} or listed none of the module's names"
            sed 's/^/        out: /' "${out_file}"
            _wb_ci_filtered_stderr "${err_file}" | sed 's/^/        err: /'
        fi
        # Every name a getter shows as unavailable says why (D101).
        if grep -q "module gave no reason" "${out_file}"; then
            fail "tools absent: ${shell}: getter ${fn} lists names with no reason — give each predicate a --needs text (docs/module-authoring.md, 'Declaring function availability')"
            sed -n '/module gave no reason/,/^$/p' "${out_file}" | sed 's/^/        /'
        fi
    done

    # ── 3. Clean start, runner PATH ─────────────────────────────────────────
    check_start "runner PATH" "${shell}" "${PATH}"
done

echo "clean-shell: ${check_no} checks, ${FAILED} failed"
[[ "${FAILED}" -eq 0 ]]
