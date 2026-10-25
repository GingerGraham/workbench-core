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
#      stderr (bash's two job-control lines aside), and every
#      register.getters[] function exits 0 and prints an [INFO] header in
#      each shell.
#   3. Clean start, runner PATH: the same two shell starts with the
#      runner's normal PATH, stderr empty.
#
# Before the shell starts, 'wb apply' registers core from the core checkout
# under test and writes the real rc stubs, so the shells load exactly what a
# user's would: core plus this module.
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

CORE_ROOT="$(cd "$(dirname "${WB}")/.." && pwd)"
# shellcheck source=lib/manifest/parse.sh
source "${CORE_ROOT}/lib/manifest/parse.sh"
# shellcheck source=lib/core/prereqs.sh
source "${CORE_ROOT}/lib/core/prereqs.sh" >/dev/null 2>&1

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
if "${WB}" apply </dev/null >"${SCRATCH}/apply.log" 2>&1; then
    ok "wb apply registered core and wrote the rc stubs"
else
    fail "wb apply failed — the shell-start checks below may be meaningless"
    cat "${SCRATCH}/apply.log"
fi
# wb apply writes ~/.zshrc only when one exists or it runs under zsh.
[[ -f "${HOME}/.zshrc" ]] || cp "${HOME}/.bashrc" "${HOME}/.zshrc"

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
mkdir -p "${BARE_BIN}"
baseline=(
    bash zsh uname sleep kill
    cat cp mv rm mkdir rmdir ln ls touch chmod readlink basename dirname
    head tail sort uniq wc cut tee date env mktemp id groups printf test expr
    find xargs stat hostname tput
    # macOS's /etc/zshrc runs `locale` in every interactive zsh (D95).
    locale
)
for bin in "${_WB_SHELL_PREREQS_REQUIRED[@]}" "${baseline[@]}"; do
    path="$(command -v "${bin}" 2>/dev/null)"
    [[ -n "${path}" && "${path}" == /* ]] && ln -sf "${path}" "${BARE_BIN}/${bin}"
done

# shell_start <bash|zsh> <PATH> <commands> <stderr-file> — an interactive
# shell, through the rc stub, in a clean environment. skip_global_compinit:
# Ubuntu's /etc/zsh/zshrc runs compinit in every interactive zsh, and on a
# GitHub runner compinit finds an fpath directory it calls insecure and,
# with no terminal to ask on, prints "compinit: initialization aborted" —
# runner noise, not the module's. Setting it is the documented opt-out.
shell_start() {
    local shell="$1" path="$2" cmds="$3" err="$4"
    env -i \
        HOME="${HOME}" \
        XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}" \
        USER="${USER:-runner}" \
        TERM=dumb \
        skip_global_compinit=1 \
        PATH="${path}" \
        "${BARE_BIN}/${shell}" -i -c "${cmds}" 2>"${err}" </dev/null
}

# Bash prints two job-control lines when -i has no terminal; nothing else
# on stderr is acceptable.
filtered_stderr() {
    grep -vE 'cannot set terminal process group|no job control in this shell' "$1"
}

check_start() {
    local label="$1" shell="$2" path="$3"
    local err="${SCRATCH}/${shell}-${label// /-}.err"
    # ':' rather than 'exit': an interactive bash prints "exit" to stderr
    # when the exit builtin runs.
    shell_start "${shell}" "${path}" ':' "${err}" >/dev/null
    if [[ -z "$(filtered_stderr "${err}")" ]]; then
        ok "${label}: interactive ${shell} starts with empty stderr"
    else
        fail "${label}: interactive ${shell} wrote to stderr:"
        filtered_stderr "${err}" | sed 's/^/        /'
    fi
}

getters=()
while IFS='|' read -r _gname gfn _glabel; do
    [[ -n "${gfn}" ]] && getters+=("${gfn}")
done < <(workbench_manifest_register_getter_entries "${MANIFEST}")

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
        shell_start "${shell}" "${BARE_BIN}" "${fn}" "${err_file}" >"${out_file}"
        rc=$?
        if [[ "${rc}" -eq 0 ]] && grep -q '\[INFO\]' "${out_file}"; then
            ok "tools absent: ${shell}: getter ${fn} exits 0 and lists something"
        else
            fail "tools absent: ${shell}: getter ${fn} exited ${rc} or printed no [INFO] header"
            sed 's/^/        out: /' "${out_file}"
            filtered_stderr "${err_file}" | sed 's/^/        err: /'
        fi
    done

    # ── 3. Clean start, runner PATH ─────────────────────────────────────────
    check_start "runner PATH" "${shell}" "${PATH}"
done

echo "clean-shell: ${check_no} checks, ${FAILED} failed"
[[ "${FAILED}" -eq 0 ]]
