#!/usr/bin/env bash
# tests/check-alias-clash-report.sh — docs/decisions-log.md D124 acceptance check.
#
# When a module's alias is not set because the name is already an alias or a
# function, the loader tells the user once, in interactive shells only, and
# `wb status` lists what is clashed now.
#
#   alias-clashes.list   clashed now (name|module|kind); `wb status` reads it
#   alias-clashes.seen   already told; pruned when a clash goes away
#
# Both live under ${XDG_DATA_HOME}/workbench/ and are written only when their
# content changes. A shell start never fails because of them.
#
# The host is built by hand: a core module whose register.list carries only
# functions.sh (so the helper exists), and one module whose shell file calls
# workbench_alias_define for three names. The host's rc file defines whatever
# the case needs, then sources the real loader.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
WB="${REPO_ROOT}/bin/wb"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }
skip() { echo "SKIP: $*"; }

WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT

HOST_HOME="${WORK}/home"
HOST_DATA="${WORK}/data"
HOST_CONFIG="${WORK}/config"
HOST_CACHE="${WORK}/cache"
STATE_DIR="${HOST_DATA}/workbench"
MODS="${STATE_DIR}/modules"
LIST="${STATE_DIR}/alias-clashes.list"
SEEN="${STATE_DIR}/alias-clashes.seen"
mkdir -p "${HOST_HOME}" "${MODS}/core" "${MODS}/gitfix" "${HOST_CONFIG}" "${HOST_CACHE}"

for m in core gitfix; do
    printf 'TRACK_MODE=latest\nTRACK_REF=v1.0.0\nREGISTERED=true\nSYNC_ENABLED=true\n' > "${MODS}/${m}/sync.conf"
done
printf '%s|core\n' "${REPO_ROOT}/lib/core/functions.sh" > "${MODS}/core/register.list"
printf '%s|tools\n' "${WORK}/gitfix.sh" > "${MODS}/gitfix/register.list"
cat > "${WORK}/gitfix.sh" <<'EOF'
if true; then
    workbench_alias_define gd git "git diff"
fi
if true; then
    workbench_alias_define gst git "git status"
fi
if true; then
    workbench_alias_define gcm git "git commit -m"
fi
EOF

# host_rc <function-gd:yes|no> <alias-gcm:yes|no> — the host's profile, then
# the loader, as the rc stub does.
host_rc() {
    {
        [[ "$1" == "yes" ]] && printf 'gd() {\n    echo host-gd\n}\n'
        [[ "$2" == "yes" ]] && printf "alias gcm='git commit --signoff -m'\n"
        printf 'source "%s/lib/loader.sh"\n' "${REPO_ROOT}"
    } > "${WORK}/rc"
}

# start_interactive — a new interactive shell through the loader, stdout and
# stderr together, minus the two job-control lines bash prints without a tty.
# RUN_PREFIX lets a case run the shell as another user.
start_interactive() {
    # shellcheck disable=SC2086
    ${RUN_PREFIX:-} env -i HOME="${HOST_HOME}" XDG_DATA_HOME="${HOST_DATA}" XDG_CONFIG_HOME="${HOST_CONFIG}" \
        XDG_CACHE_HOME="${HOST_CACHE}" PATH="/usr/local/bin:/usr/bin:/bin" TERM=dumb \
        WORKBENCH_USER_EXT_ENABLED=false \
        bash --noprofile --rcfile "${WORK}/rc" -i -c 'echo SHELL-STARTED' 2>&1 </dev/null \
        | grep -vE 'cannot set terminal process group|no job control in this shell'
}

start_noninteractive() {
    env -i HOME="${HOST_HOME}" XDG_DATA_HOME="${HOST_DATA}" XDG_CONFIG_HOME="${HOST_CONFIG}" \
        XDG_CACHE_HOME="${HOST_CACHE}" PATH="/usr/local/bin:/usr/bin:/bin" TERM=dumb \
        WORKBENCH_USER_EXT_ENABLED=false \
        bash --noprofile --norc -c "source '${WORK}/rc'; echo SHELL-STARTED" 2>&1 </dev/null
}

wb_status() {
    env -i HOME="${HOST_HOME}" XDG_DATA_HOME="${HOST_DATA}" XDG_CONFIG_HOME="${HOST_CONFIG}" \
        XDG_CACHE_HOME="${HOST_CACHE}" PATH="/usr/local/bin:/usr/bin:/bin" TERM=dumb \
        bash "${WB}" status 2>&1 </dev/null
}

warning_count() { grep -c 'not set because the name is already in use' <<<"$1"; }

# ── 0. A plain host: nothing recorded, nothing on disk, nothing written. ────
host_rc no no
out="$(start_interactive)"
if [[ "$(warning_count "${out}")" -eq 0 ]] && [[ ! -e "${LIST}" && ! -e "${SEEN}" ]] \
    && [[ "$(grep -c . <<<"${out}")" -eq 1 ]]; then
    ok "no clash: interactive start prints nothing but the command's own output, and writes no state file"
else
    fail "no clash: expected a silent start"; printf '%s\n' "${out}"; ls -la "${STATE_DIR}"
fi
out="$(wb_status)"
if grep -q 'Alias clashes' <<<"${out}" && grep -q '^  none$' <<<"${out}"; then
    ok "wb status without clashes: the section prints 'none'"
else
    fail "wb status without clashes"; printf '%s\n' "${out}"
fi

# ── 1. One clash (a host function named gd). ────────────────────────────────
host_rc yes no
out="$(start_interactive)"
if [[ "$(warning_count "${out}")" -eq 1 ]] && grep -q '1 alias was not set' <<<"${out}" \
    && grep -q 'gd' <<<"${out}" && grep -q 'existing function' <<<"${out}" \
    && grep -q 'would set: git diff' <<<"${out}" && grep -q 'left as they are' <<<"${out}"; then
    ok "one clash, interactive: exactly one consolidated warning naming gd, its kind and the value workbench would have set"
else
    fail "one clash, interactive: warning missing or wrong"; printf '%s\n' "${out}"
fi
if [[ "$(cat "${LIST}" 2>/dev/null)" == "gd|git|function" && "$(cat "${SEEN}" 2>/dev/null)" == "gd|git|function" ]]; then
    ok "one clash: alias-clashes.list and alias-clashes.seen both hold 'gd|git|function'"
else
    fail "one clash: state files wrong"; cat "${LIST}" "${SEEN}" 2>&1
fi
if grep -qiE 'override|force|take over|replace' <<<"${out}"; then
    fail "the warning mentions a way to make workbench win; none exists yet"
else
    ok "the warning does not offer an override (none exists)"
fi

# ── 2. The same clash on the next start: silent; wb status still lists it. ──
out="$(start_interactive)"
if [[ "$(warning_count "${out}")" -eq 0 ]] && [[ "$(grep -c . <<<"${out}")" -eq 1 ]]; then
    ok "second interactive start, same clash: no warning"
else
    fail "second start warned again"; printf '%s\n' "${out}"
fi
out="$(wb_status)"
if grep -q 'Alias clashes' <<<"${out}" && grep -Eq '^  gd +git +function' <<<"${out}"; then
    ok "wb status lists the clash (name, module, kind)"
else
    fail "wb status does not list the clash"; printf '%s\n' "${out}"
fi

# ── 7. Steady state: a pass with no change does not rewrite either file. ────
# A hard link to each file: if the loader rewrites a file (temp file and
# rename), the path gets a new inode and stops being the same file as the link.
ln "${LIST}" "${WORK}/list.link"
ln "${SEEN}" "${WORK}/seen.link"
touch -t 200001010000 "${LIST}" "${SEEN}"
touch -t 200101010000 "${WORK}/reference"
start_interactive >/dev/null
if [[ "${LIST}" -ot "${WORK}/reference" && "${SEEN}" -ot "${WORK}/reference" ]] \
    && [[ "${LIST}" -ef "${WORK}/list.link" && "${SEEN}" -ef "${WORK}/seen.link" ]]; then
    ok "steady state: a second pass with no change leaves both files' inode and mtime alone"
else
    fail "steady state: a file was rewritten with no change"; ls -l "${LIST}" "${SEEN}"
fi

# ── 3. A new clash appears: only the new one is warned. ─────────────────────
host_rc yes yes
out="$(start_interactive)"
if [[ "$(warning_count "${out}")" -eq 1 ]] && grep -q '1 alias was not set' <<<"${out}" \
    && grep -q 'gcm' <<<"${out}" && ! grep -qE '^ +gd ' <<<"${out}" \
    && grep -q "existing gcm='git commit --signoff -m'" <<<"${out}" && grep -q 'would set: git commit -m' <<<"${out}"; then
    ok "a new clash (alias gcm): only gcm is warned, with the host's alias text and the value workbench would set"
else
    fail "a new clash: wrong warning"; printf '%s\n' "${out}"
fi
if [[ "$(grep -c . "${LIST}")" -eq 2 ]] && grep -qx 'gcm|git|alias' "${LIST}" && grep -qx 'gd|git|function' "${LIST}"; then
    ok "the list now holds both clashes"
else
    fail "list after a second clash"; cat "${LIST}"
fi

# ── 4. A clash disappears, then returns. ────────────────────────────────────
host_rc no yes
out="$(start_interactive)"
if [[ "$(warning_count "${out}")" -eq 0 ]] && ! grep -q '^gd|' "${LIST}" && ! grep -q '^gd|' "${SEEN}" \
    && grep -qx 'gcm|git|alias' "${LIST}" && grep -qx 'gcm|git|alias' "${SEEN}"; then
    ok "a clash the user fixed (gd) leaves both files; the one still present (gcm) stays, and nothing is warned"
else
    fail "a clash disappeared"; printf '%s\n' "${out}"; cat "${LIST}" "${SEEN}"
fi
out="$(wb_status)"
if grep -Eq '^  gcm +git +alias' <<<"${out}" && ! grep -Eq '^  gd +git' <<<"${out}"; then
    ok "wb status shows only what is clashed now"
else
    fail "wb status after a clash disappeared"; printf '%s\n' "${out}"
fi
host_rc yes yes
out="$(start_interactive)"
if [[ "$(warning_count "${out}")" -eq 1 ]] && grep -q 'gd' <<<"${out}" && ! grep -qE '^ +gcm ' <<<"${out}"; then
    ok "a clash that returns (gd) warns again; the unchanged one (gcm) does not"
else
    fail "a returning clash"; printf '%s\n' "${out}"
fi
host_rc no no
start_interactive >/dev/null
if [[ ! -e "${LIST}" && ! -e "${SEEN}" ]]; then
    ok "with no clash left, both files are removed (the plain-host state)"
else
    fail "files remain with no clash"; ls -la "${STATE_DIR}"
fi

# ── 5. A non-interactive shell: no output, no files. ────────────────────────
host_rc yes yes
out="$(start_noninteractive)"
if [[ "${out}" == "SHELL-STARTED" ]] && [[ ! -e "${LIST}" && ! -e "${SEEN}" ]]; then
    ok "non-interactive shell with clashes present: no output and no state file written"
else
    fail "non-interactive shell"; printf '%s\n' "${out}"; ls -la "${STATE_DIR}"
fi

# ── 6. An unwritable state directory never stops the shell. ─────────────────
# As root, permissions do not bind, so the shell runs as an unprivileged user.
host_rc yes no
can_test_unwritable=true
RUN_PREFIX=""
if [[ "$(id -u)" -eq 0 ]]; then
    if command -v setpriv >/dev/null 2>&1; then
        chmod -R a+rX "${WORK}"
        chmod -R a+rwX "${HOST_CACHE}" "${HOST_HOME}"
        RUN_PREFIX="setpriv --reuid=65534 --regid=65534 --clear-groups"
    else
        can_test_unwritable=false
    fi
fi
if [[ "${can_test_unwritable}" == "true" ]]; then
    chmod a-w "${STATE_DIR}"
    out="$(start_interactive; echo "EXIT=$?")"
    if grep -q 'SHELL-STARTED' <<<"${out}" && [[ ! -e "${LIST}" && ! -e "${SEEN}" ]] \
        && ! grep -qiE 'permission denied|cannot create|read-only' <<<"${out}"; then
        ok "state directory unwritable: the shell still starts, nothing is written, no error leaks"
    else
        fail "state directory unwritable"; printf '%s\n' "${out}"
    fi
    if [[ "$(warning_count "${out}")" -eq 1 ]]; then
        ok "state directory unwritable: the clash is still reported for that shell (without persistence)"
    else
        fail "state directory unwritable: expected the warning for this shell"; printf '%s\n' "${out}"
    fi
    chmod u+w,a+w "${STATE_DIR}"
else
    skip "state directory unwritable: running as root with no setpriv, so permissions cannot be tested"
fi
RUN_PREFIX=""

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks failed."
exit 1
