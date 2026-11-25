#!/usr/bin/env bash
# tests/check-port-helpers.sh — docs/decisions-log.md D129 acceptance check.
#
# workbench_port_in_use and workbench_port_pick (Core API 1.12) find a free
# TCP port for any module. The search is tested here, against a stub `ss`
# and `lsof`, so the modules that call it (workbench-cloud, workbench-
# containers) only need to test that they call it.
#
# Every case runs in bash, and in zsh when it is installed, in a clean
# `env -i` shell whose PATH holds only awk and the stubs this script
# builds: "no ss and no lsof" must mean that, whatever the host has.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
FUNCTIONS_SH="${REPO_ROOT}/lib/core/functions.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }
skip() { echo "SKIP: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
FAKE_HOME="${WORK}/home"
HOSTBIN="${WORK}/hostbin"
STUBS="${WORK}/stubs"
LISTENING="${WORK}/listening"
mkdir -p "${FAKE_HOME}" "${HOSTBIN}" "${STUBS}"

# The only host tools the helpers (awk) and functions.sh at load time
# (dirname, uname) need.
for tool in awk dirname uname; do
    tool_path="$(command -v "${tool}")"
    if [[ -z "${tool_path}" ]]; then
        echo "FAIL: ${tool} is required to run this test"
        exit 1
    fi
    ln -s "${tool_path}" "${HOSTBIN}/${tool}"
done

# set_listening <port>... — the ports the stubs report as listening.
set_listening() {
    : > "${LISTENING}"
    local p
    for p in "$@"; do
        printf '%s\n' "${p}" >> "${LISTENING}"
    done
}

# add_ss [<local-address-format>] — a stub `ss -Hltn`. The format is a
# printf template taking the port: "0.0.0.0:%s" (default) or "[::]:%s".
add_ss() {
    local fmt="${1:-0.0.0.0:%s}"
    cat > "${STUBS}/ss" <<EOF
#!/bin/sh
while IFS= read -r port; do
    printf 'LISTEN 0 4096 ${fmt} 0.0.0.0:*\n' "\${port}"
done < "${LISTENING}"
EOF
    chmod +x "${STUBS}/ss"
}

# add_lsof — a stub `lsof -nP -iTCP:<port> -sTCP:LISTEN -t`: prints a pid
# when <port> is in the listening file.
add_lsof() {
    cat > "${STUBS}/lsof" <<EOF
#!/bin/sh
for arg in "\$@"; do
    case "\${arg}" in
        -iTCP:*) port="\${arg#-iTCP:}" ;;
    esac
done
while IFS= read -r listening_port; do
    if [ "\${listening_port}" = "\${port}" ]; then
        echo 4242
    fi
done < "${LISTENING}"
EOF
    chmod +x "${STUBS}/lsof"
}

reset_world() {
    rm -f "${STUBS}/ss" "${STUBS}/lsof"
    set_listening
}

# run_in <bash|zsh> <command...> — runs the command in a clean shell that
# has loaded core's functions.sh. Prints stdout and stderr together.
run_in() {
    local shell="$1" prelude
    shift
    prelude="${WORK}/prelude-${shell}.sh"
    printf 'source "%s" >/dev/null 2>&1\n%s\n' "${FUNCTIONS_SH}" "$*" > "${prelude}"
    env -i HOME="${FAKE_HOME}" PATH="${STUBS}:${HOSTBIN}" TERM=dumb \
        "$(command -v "${shell}")" -f "${prelude}" 2>&1 </dev/null
}

expect_eq() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected '$3', got '$2'"; fi
}
expect_has() {
    case "$2" in
        *"$3"*) ok "$1" ;;
        *) fail "$1 — expected output to contain '$3', got: $2" ;;
    esac
}

SHELLS="bash"
if command -v zsh >/dev/null 2>&1; then
    SHELLS="bash zsh"
else
    skip "zsh is not installed — the zsh runs are skipped"
fi

for sh in ${SHELLS}; do
    # 1. 9297 and 9298 listening → 9299.
    reset_world; add_ss; set_listening 9297 9298
    expect_eq "${sh}: pick skips 9297 and 9298 → 9299" "$(run_in "${sh}" 'workbench_port_pick 9297 test')" "9299"

    # 2. Nothing listening → the base port.
    reset_world; add_ss
    expect_eq "${sh}: pick takes the base port when it is free" "$(run_in "${sh}" 'workbench_port_pick 9297 test')" "9297"

    # 3. 9297 listening only on [::] → 9298.
    reset_world; add_ss '[::]:%s'; set_listening 9297
    expect_eq "${sh}: pick counts a port used on another address (IPv6) as used" "$(run_in "${sh}" 'workbench_port_pick 9297 test')" "9298"

    # 4. Taken list, nothing listening.
    reset_world; add_ss
    expect_eq "${sh}: pick skips taken ports → 9299" "$(run_in "${sh}" 'workbench_port_pick 9297 test 9297 9298')" "9299"

    # 5. Taken plus listening.
    reset_world; add_ss; set_listening 9297
    expect_eq "${sh}: pick skips a listening port and a taken one → 9299" "$(run_in "${sh}" 'workbench_port_pick 9297 test 9298')" "9299"

    # 6. The whole range listening.
    reset_world; add_ss
    all=""; p=9297; while [[ ${p} -le 9396 ]]; do all="${all} ${p}"; p=$((p + 1)); done
    # shellcheck disable=SC2086 # one argument per port
    set_listening ${all}
    out="$(run_in "${sh}" 'workbench_port_pick 9297 test; echo "rc=$?"')"
    expect_has "${sh}: pick fails when the whole range is used" "${out}" "test: no free port from 9297 to 9396"
    expect_has "${sh}: ... with status 1" "${out}" "rc=1"

    # 7. No ss and no lsof → a warning and the base port.
    reset_world
    out="$(run_in "${sh}" 'workbench_port_pick 9297 test')"
    expect_has "${sh}: pick without ss or lsof warns with the label ..." "${out}" "test: can't check ports (no ss or lsof) — trying 9297"
    expect_eq "${sh}: ... and prints the base port" "$(run_in "${sh}" 'workbench_port_pick 9297 test 2>/dev/null')" "9297"

    # 8. No ss or lsof, base taken → the next port.
    reset_world
    expect_eq "${sh}: pick without ss or lsof still skips a taken port → 9298" "$(run_in "${sh}" 'workbench_port_pick 9297 test 9297 2>/dev/null')" "9298"

    # 9. A non-numeric base.
    reset_world; add_ss
    out="$(run_in "${sh}" 'workbench_port_pick abc test; echo "rc=$?"')"
    expect_has "${sh}: pick refuses a non-numeric base, naming it ..." "${out}" "test: port base must be a number (got 'abc')"
    expect_has "${sh}: ... with status 2" "${out}" "rc=2"
    out="$(run_in "${sh}" 'workbench_port_pick "" test; echo "rc=$?"')"
    expect_has "${sh}: pick refuses an empty base with status 2" "${out}" "rc=2"

    # 10. workbench_port_in_use: 0 / 1 / 2.
    reset_world; add_ss; set_listening 9297
    expect_eq "${sh}: in_use is 0 for a listening port" "$(run_in "${sh}" 'workbench_port_in_use 9297; echo "rc=$?"')" "rc=0"
    expect_eq "${sh}: in_use is 1 for a port nothing listens on" "$(run_in "${sh}" 'workbench_port_in_use 9298; echo "rc=$?"')" "rc=1"
    expect_eq "${sh}: in_use does not match a longer port (929 vs 9297)" "$(run_in "${sh}" 'workbench_port_in_use 929; echo "rc=$?"')" "rc=1"
    reset_world
    expect_eq "${sh}: in_use is 2 with neither ss nor lsof" "$(run_in "${sh}" 'workbench_port_in_use 9297; echo "rc=$?"')" "rc=2"
    reset_world; add_lsof; set_listening 9297
    expect_eq "${sh}: in_use uses lsof when ss is missing (listening → 0)" "$(run_in "${sh}" 'workbench_port_in_use 9297; echo "rc=$?"')" "rc=0"
    expect_eq "${sh}: ... and not listening → 1" "$(run_in "${sh}" 'workbench_port_in_use 9298; echo "rc=$?"')" "rc=1"
    expect_eq "${sh}: pick works through lsof → 9298" "$(run_in "${sh}" 'workbench_port_pick 9297 test')" "9298"
done

echo ""
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
