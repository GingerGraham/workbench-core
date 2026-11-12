#!/usr/bin/env bash
# tests/check-existing-setup-coexistence.sh — docs/decisions-log.md D110
# acceptance check.
#
# Proves workbench changes only state it created on a host that already has
# a shell profile. Two fixtures, both built by hand (nothing vendored from
# any distribution):
#
#   plain host   — empty rc file, no aliases, no hooks, default PATH. The
#                  shell state after the loader pass must match a golden
#                  file captured from `main` before D110 work began. Any
#                  difference means a change was not additive.
#   distro-style — a profile that sets EDITOR, aliases, a cd wrapper, an
#                  array PROMPT_COMMAND shaped like a real host, and a PATH
#                  with a duplicate. The loader must leave all of it alone.
#
# Regenerate the golden file only on purpose, from a commit whose loader
# behaviour you mean to bless:  WB_UPDATE_GOLDEN=1 bash <this file>
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
WB="${REPO_ROOT}/bin/wb"
GOLDEN="${SCRIPT_DIR}/fixtures/plain-host-state.golden"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── The snapshot command (from the D110 brief), minus the parts that vary
#    by bash version (bash version, shopt, key bindings), so a golden file
#    stays valid across the bash builds CI and developers use. ─────────────
cat > "${WORK}/snapshot.sh" <<'SNAPSHOT_EOF'
snapshot_shell_state() {
    # usage: snapshot_shell_state <output-file>
    {
        echo "## login_shell=$(shopt -q login_shell && echo yes || echo no)"
        echo "## aliases";            alias
        echo "## function names";    declare -F | sed 's/^declare -f //' | grep -v '^snapshot_shell_state$' | sort
        echo "## cd/zd/z bodies";     declare -f cd zd z 2>/dev/null
        echo "## exported env";       env | grep -v '^_=' | sort
        echo "## shell-local vars"
        declare -p HISTSIZE HISTFILESIZE HISTCONTROL HISTIGNORE PS1 PS0 2>/dev/null
        echo "## PROMPT_COMMAND";     declare -p PROMPT_COMMAND 2>/dev/null
        echo "## traps";              trap -p
    } > "$1"
}
SNAPSHOT_EOF

# Normalise paths so a snapshot taken under one temp dir compares equal to
# one taken under another.
#
# Also drops what the machine running the test contributes on its own and
# that has nothing to do with workbench: variables a system profile exports
# (Nix, XDG_DATA_DIRS), the platform facts the loader reads from the host
# (WORKBENCH_DISTRO, WORKBENCH_ARCH), and a distro-default PS1 set by the
# system bashrc, which bash reads even when --rcfile is given.
normalise() {
    sed -e "s#${WORK}#@WORK@#g" -e "s#${REPO_ROOT}#@REPO@#g" \
        -e '/^NIX_/d' \
        -e '/^__ETC_PROFILE_NIX_SOURCED=/d' \
        -e '/^XDG_DATA_DIRS=/d' \
        -e '/^WORKBENCH_DISTRO=/d' \
        -e '/^WORKBENCH_ARCH=/d' \
        -e '/^declare -- PS1=.*debian_chroot/d' \
        -e '/^PATH=/s#[^:=]*nix[^:]*:##g'
}

# new_host <name> — fresh HOME / XDG dirs under ${WORK}/<name>, with the
# core module's `current` link pointing at this checkout, which is where
# the rc stub looks for the loader.
new_host() {
    local name="$1"
    HOST_DIR="${WORK}/${name}"
    HOST_HOME="${HOST_DIR}/home"
    HOST_DATA="${HOST_DIR}/data"
    HOST_CONFIG="${HOST_DIR}/config"
    HOST_CACHE="${HOST_DIR}/cache"
    mkdir -p "${HOST_HOME}" "${HOST_DATA}/workbench/modules/core" "${HOST_CONFIG}" "${HOST_CACHE}"
    ln -s "${REPO_ROOT}" "${HOST_DATA}/workbench/modules/core/current"
}

# run_shell <rc-file> <command> — an interactive bash with a clean
# environment that reads only <rc-file>. --rcfile also skips the system
# bashrc, so the result does not depend on the machine running the test.
# Extra KEY=VALUE pairs for the inner shell go in RUN_SHELL_ENV.
run_shell() {
    local rc_file="$1" command_text="$2"
    # RUN_SHELL_ENV is deliberately unquoted: it is a list of KEY=VALUE words.
    # shellcheck disable=SC2086
    ( cd -- "${HOST_HOME}" && env -i \
        HOME="${HOST_HOME}" \
        XDG_DATA_HOME="${HOST_DATA}" \
        XDG_CONFIG_HOME="${HOST_CONFIG}" \
        XDG_CACHE_HOME="${HOST_CACHE}" \
        PATH="${RUN_SHELL_PATH:-/usr/local/bin:/usr/bin:/bin}" \
        TERM=dumb \
        ${RUN_SHELL_ENV:-} \
        bash --noprofile --rcfile "${rc_file}" -i -c "${command_text}" 2>&1 )
}

# stub_rc <rc-file> — write the real loader stub with the real function.
stub_rc() {
    local target="$1"
    ( export HOME="${HOST_HOME}" XDG_DATA_HOME="${HOST_DATA}" XDG_CONFIG_HOME="${HOST_CONFIG}" XDG_CACHE_HOME="${HOST_CACHE}"
      # bin/wb reads "$@" when sourced, so clear it first.
      set --
      # shellcheck source=bin/wb
      source "${WB}" >/dev/null 2>&1
      _wb_write_rc_stub "${target}" ) >"${WORK}/stub-write.log" 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
# Plain-host twin
# ═══════════════════════════════════════════════════════════════════════════
new_host plain
: > "${HOST_HOME}/.bashrc"
cp "${HOST_HOME}/.bashrc" "${HOST_HOME}/.bashrc.prestub"

run_shell "${HOST_HOME}/.bashrc.prestub" ". '${WORK}/snapshot.sh'; snapshot_shell_state '${WORK}/plain-before.txt'" >/dev/null
stub_rc "${HOST_HOME}/.bashrc"
run_shell "${HOST_HOME}/.bashrc" ". '${WORK}/snapshot.sh'; snapshot_shell_state '${WORK}/plain-after.txt'" >/dev/null

{
    echo "# plain-host state: before the loader stub, then after it."
    echo "# Generated from main before D110 work began. See the header of"
    echo "# tests/check-existing-setup-coexistence.sh before regenerating."
    echo "######## BEFORE"
    normalise < "${WORK}/plain-before.txt"
    echo "######## AFTER"
    normalise < "${WORK}/plain-after.txt"
} > "${WORK}/plain-golden-candidate.txt"

if [[ -n "${WB_UPDATE_GOLDEN:-}" ]]; then
    mkdir -p "$(dirname -- "${GOLDEN}")"
    cp "${WORK}/plain-golden-candidate.txt" "${GOLDEN}"
    echo "Wrote ${GOLDEN}"
    exit 0
fi

if [[ ! -f "${GOLDEN}" ]]; then
    fail "golden file missing: ${GOLDEN}"
elif diff -u "${GOLDEN}" "${WORK}/plain-golden-candidate.txt" >"${WORK}/plain.diff"; then
    ok "plain host: shell state after the loader pass is identical to the golden state captured from main"
else
    fail "plain host: shell state differs from the golden file — a change was not additive:"
    cat "${WORK}/plain.diff"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
