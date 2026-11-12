#!/usr/bin/env bash
# tests/check-cd-wrapper.sh — docs/decisions-log.md D110 acceptance check.
#
# Behavioural half of tests/check-no-bare-cd.sh. Builds a shell the way a
# host with its own profile builds one — `ls` aliased to something noisy,
# `cd` both aliased and wrapped by a function — and then sources
# workbench's code. None of the host wrappers may run, and every directory
# workbench resolves for itself must still be right.
#
# An alias is expanded when a line is read, so the wrappers are defined on
# lines of their own BEFORE anything is sourced, and aliases are switched
# on explicitly for the non-interactive shell that runs the fixture.
set -uo pipefail

SCRIPT_DIR="$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(builtin cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wb-cd-wrapper.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
export XDG_CACHE_HOME="${WORK}/cache"
mkdir -p "${HOME}" "${XDG_DATA_HOME}" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"
: > "${HOME}/.bashrc"

# The host's wrappers. Written to a file that each fixture shell sources
# first. The function comes before the aliases: once the `cd` alias exists,
# the line `cd() {` would itself be alias-expanded and fail to parse.
cat > "${WORK}/host-wrappers.sh" <<'WRAPPERS_EOF'
shopt -s expand_aliases
cd() { printf 'WRAPPER-CALLED\n' >&2; return 1; }
alias ls='printf "ALIAS-LS-RAN\n"; command ls -1 --'
alias cd='printf "ALIAS-CD-RAN\n" >&2; false; :'
WRAPPERS_EOF

MARKERS_RE='ALIAS-LS-RAN|ALIAS-CD-RAN|WRAPPER-CALLED'

# run_fixture <script-body> — run <script-body> in a clean bash that has the
# host wrappers installed first. Prints stdout and stderr together.
run_fixture() {
    local body="$1"
    env -i \
        HOME="${HOME}" \
        XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
        PATH="${PATH}" \
        bash -c ". '${WORK}/host-wrappers.sh'
${body}" 2>&1
}

assert_no_markers() {
    local label="$1" output="$2"
    if printf '%s\n' "${output}" | grep -Eq "${MARKERS_RE}"; then
        fail "${label}: a host alias or wrapper ran inside workbench code:"
        printf '%s\n' "${output}" | grep -E "${MARKERS_RE}" | sort | uniq -c
    else
        ok "${label}: no host alias or wrapper ran"
    fi
}

# ── 1. The loader resolves its own directory despite the wrappers. ─────────
OUT="$(run_fixture ". '${REPO_ROOT}/lib/loader.sh'
echo \"LOADER_PATH=\${WORKBENCH_LOADER_PATH:-unset}\"")"
assert_no_markers "sourcing lib/loader.sh" "${OUT}"
loader_path="$(printf '%s\n' "${OUT}" | grep '^LOADER_PATH=' | sed 's/^LOADER_PATH=//')"
if [[ "${loader_path}" == "${REPO_ROOT}/lib/loader.sh" ]]; then
    ok "the loader resolved its own path correctly: ${loader_path}"
else
    fail "loader path is wrong or empty: '${loader_path}' (expected ${REPO_ROOT}/lib/loader.sh)"
fi

# ── 2. The wb() wrapper's reload path re-sources the loader. ───────────────
OUT="$(run_fixture ". '${REPO_ROOT}/lib/loader.sh' >/dev/null 2>&1
wb reload
echo \"AFTER_RELOAD=\${WORKBENCH_LOADER_PATH:-unset}\"")"
assert_no_markers "wb reload (the wrapper's re-source path)" "${OUT}"
after_reload="$(printf '%s\n' "${OUT}" | grep '^AFTER_RELOAD=' | sed 's/^AFTER_RELOAD=//')"
if [[ "${after_reload}" == "${REPO_ROOT}/lib/loader.sh" ]]; then
    ok "the loader path is still right after a wb reload"
else
    fail "loader path after reload is wrong or empty: '${after_reload}'"
fi

# ── 3. bin/wb, sourced, resolves its own root. ─────────────────────────────
# bin/wb reads "$@" when sourced, so clear it first.
OUT="$(run_fixture "set --
. '${REPO_ROOT}/bin/wb' >/dev/null 2>&1
echo \"WB_ROOT=\${WB_ROOT:-unset}\"")"
assert_no_markers "sourcing bin/wb" "${OUT}"
wb_root="$(printf '%s\n' "${OUT}" | grep '^WB_ROOT=' | sed 's/^WB_ROOT=//')"
if [[ "${wb_root}" == "${REPO_ROOT}" ]]; then
    ok "bin/wb resolved its own root correctly"
else
    fail "bin/wb root is wrong or empty: '${wb_root}' (expected ${REPO_ROOT})"
fi

# ── 4. Every library file that resolves its own directory does so right. ───
# Each file is sourced on its own; only the variable it sets is read back.
# Errors from the rest of the file (it may need functions its caller would
# normally have loaded) are not what this checks.
lib_dir_checks="
lib/modules/catalog.sh:_wb_catalog_lib_dir
lib/manifest/parse.sh:_wb_manifest_lib_dir
lib/ssh/bootstrap.sh:_wb_ssh_lib_dir
lib/sync/scheduler.sh:_wb_scheduler_lib_dir
lib/sync/state.sh:_wb_state_lib_dir
lib/sync/engine.sh:_wb_engine_lib_dir
lib/distribution/snapshot.sh:_wb_snapshot_lib_dir
lib/distribution/resolve.sh:_wb_resolve_lib_dir
lib/core/functions.sh:log_info
lib/core/prereqs.sh:_wb_prereqs_lib_dir
lib/core/completion.sh:log_info
lib/core/tools.sh:_wb_tools_lib_dir
lib/core/version.sh:_wb_version_lib_dir
"
# functions.sh and completion.sh unset their directory variable once they
# have used it to source log.sh, so for those the entry names log_info, and
# the check is that log.sh got sourced — which only happens if the directory
# resolved.
for entry in ${lib_dir_checks}; do
    file="${entry%%:*}"
    var="${entry##*:}"
    expected="${REPO_ROOT}/$(dirname -- "${file}")"
    if [[ "${var}" == "log_info" ]]; then
        OUT="$(run_fixture "set --
. '${REPO_ROOT}/${file}' >/dev/null 2>&1
declare -F log_info >/dev/null && echo LOG_SOURCED=yes || echo LOG_SOURCED=no")"
        assert_no_markers "sourcing ${file}" "${OUT}"
        if printf '%s\n' "${OUT}" | grep -q '^LOG_SOURCED=yes$'; then
            ok "${file} resolved its own directory (it sourced log.sh from it)"
        else
            fail "${file} did not find log.sh next to itself"
        fi
        continue
    fi
    OUT="$(run_fixture "set --
. '${REPO_ROOT}/${file}' >/dev/null 2>&1
echo \"DIR=\${${var}:-unset}\"")"
    assert_no_markers "sourcing ${file}" "${OUT}"
    resolved="$(printf '%s\n' "${OUT}" | grep '^DIR=' | sed 's/^DIR=//')"
    if [[ "${resolved}" == "${expected}" ]]; then
        ok "${file} resolved its own directory (${var})"
    else
        fail "${file}: ${var} is '${resolved}', expected '${expected}'"
    fi
done

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
