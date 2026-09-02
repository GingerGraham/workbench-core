#!/usr/bin/env bash
# tests/check-wb-on-path.sh — verifies `wb` is exposed on PATH after
# install/apply (bin/wb was never symlinked anywhere on PATH; see
# ARCHITECTURE.md §12 D19).
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

# ── Fixture: a bootstrapped core module with a stub bin/wb ─────────────────
CORE_DIR="${XDG_DATA_HOME}/workbench/modules/core"
mkdir -p "${CORE_DIR}/snapshots/fixture-0000000/bin"
cat > "${CORE_DIR}/snapshots/fixture-0000000/bin/wb" <<'EOF'
#!/usr/bin/env bash
echo "wb-stub: invoked"
EOF
chmod +x "${CORE_DIR}/snapshots/fixture-0000000/bin/wb"
ln -s "${CORE_DIR}/snapshots/fixture-0000000" "${CORE_DIR}/current"
cat > "${CORE_DIR}/sync.conf" <<'EOF'
TRACK_MODE=latest
REGISTERED=true
SYNC_ENABLED=true
EOF

# shellcheck disable=SC1090
run_link() { ( set --; source "${WB}" >/dev/null 2>&1; _wb_link_cli_bin ) ; }

# ── 1. First run creates the symlink, pointed through `current` ────────────
run_link
LINK="${HOME}/.local/bin/wb"
if [[ -L "${LINK}" ]]; then
    # shellcheck disable=SC2088
    ok "~/.local/bin/wb was created as a symlink"
else
    # shellcheck disable=SC2088
    fail "~/.local/bin/wb was not created (or is not a symlink)"
fi
if [[ "$(readlink "${LINK}")" == "${CORE_DIR}/current/bin/wb" ]]; then
    ok "symlink points through core/current, not a specific snapshot"
else
    fail "symlink target unexpected: $(readlink "${LINK}" 2>&1)"
fi
if [[ "$("${LINK}")" == "wb-stub: invoked" ]]; then
    ok "the linked wb is actually executable end-to-end"
else
    fail "executing ~/.local/bin/wb did not run the stub"
fi

# ── 2. Idempotent re-run: no error, target unchanged ────────────────────────
BEFORE="$(readlink "${LINK}")"
run_link
AFTER="$(readlink "${LINK}")"
if [[ "${BEFORE}" == "${AFTER}" ]]; then
    ok "re-running _wb_link_cli_bin is idempotent"
else
    fail "re-run changed the symlink target unexpectedly"
fi

# ── 3. Non-destructive: a pre-existing plain file is left alone ────────────
rm -f "${LINK}"
echo "not workbench's file" > "${LINK}"
OUT="$(run_link 2>&1 1>/dev/null)"
if [[ -f "${LINK}" && ! -L "${LINK}" ]]; then
    ok "a pre-existing non-symlink ~/.local/bin/wb was left untouched"
else
    fail "a foreign ~/.local/bin/wb was clobbered"
fi
# shellcheck disable=SC2015
echo "${OUT}" | grep -q "leaving it alone" && ok "a warning was logged for the foreign file" \
    || fail "no warning logged for the foreign file"

# ── 4. A failed `ln` is reported as an error, not logged as a false success ─
rm -f "${LINK}"
rm -rf "${HOME}/.local"
: > "${HOME}/.local"    # a plain file where a directory is expected -> mkdir -p and ln both fail
OUT_FAIL="$(run_link 2>&1 1>/dev/null)"
RC=$?
rm -f "${HOME}/.local"
mkdir -p "${HOME}/.local/bin"
if [[ "${RC}" -ne 0 ]] && echo "${OUT_FAIL}" | grep -qi "failed to link"; then
    ok "a failed ln is reported as an error, not logged as a false success"
else
    fail "ln failure was not detected/reported: rc=${RC} out=${OUT_FAIL}"
fi

# ── 5. Executing the real bin/wb through the ~/.local/bin symlink resolves
#    its own lib/ correctly. bin/wb derives WB_ROOT from its own path; a
#    plain, symlink-naive `dirname "${BASH_SOURCE[0]}"` resolves against the
#    symlink's own location (~/.local/bin), not its target, and would look
#    for lib/ in entirely the wrong tree. The trivial stub used in checks
#    1-4 above has no path-resolution logic of its own to break, so it can't
#    catch this — this check runs the actual bin/wb + lib/ (flagged in PR
#    review). ───────────────────────────────────────────────────────────
REAL_CORE="${WORK}/real-core-current"
mkdir -p "${REAL_CORE}/bin"
cp -r "${REPO_ROOT}/lib" "${REAL_CORE}/lib"
cp "${REPO_ROOT}/bin/wb" "${REAL_CORE}/bin/wb"
chmod +x "${REAL_CORE}/bin/wb"
rm -f "${LINK}"
ln -s "${REAL_CORE}/bin/wb" "${LINK}"
OUT_REAL="$("${LINK}" version 2>&1)"
if echo "${OUT_REAL}" | grep -q "loaded script versions"; then
    ok "invoking wb through the ~/.local/bin symlink resolves its own lib/ correctly"
else
    fail "invoking wb through the ~/.local/bin symlink failed to resolve lib/: ${OUT_REAL}"
fi

# ── 6. lib/loader.sh defensively ensures ~/.local/bin is on PATH ───────────
LOADER="${REPO_ROOT}/lib/loader.sh"
OUT_PATH="$(PATH="/usr/bin:/bin" HOME="${HOME}" bash -c "source '${LOADER}' >/dev/null 2>&1; printf '%s' \"\${PATH}\"")"
case ":${OUT_PATH}:" in
    *":${HOME}/.local/bin:"*) ok "sourcing lib/loader.sh prepends ~/.local/bin onto PATH" ;;
    *) fail "lib/loader.sh did not add ~/.local/bin to PATH: ${OUT_PATH}" ;;
esac

# Split on ':' and match whole segments — `grep -o ":X:"` would consume the
# shared colon between adjacent duplicates (…:X:X:…) and undercount them,
# masking exactly the regression this check exists to catch (flagged in PR
# review).
count_path_entries() { printf '%s' "$1" | tr ':' '\n' | grep -Fxc "$2"; }

occurrences="$(count_path_entries "${OUT_PATH}" "${HOME}/.local/bin")"
if [[ "${occurrences}" -eq 1 ]]; then
    # shellcheck disable=SC2088
    ok "~/.local/bin appears exactly once on PATH"
else
    # shellcheck disable=SC2088
    fail "~/.local/bin appears ${occurrences} times on PATH, expected 1"
fi

# shellcheck disable=SC2097,SC2098
OUT_PATH2="$(PATH="${HOME}/.local/bin:/usr/bin:/bin" HOME="${HOME}" bash -c "source '${LOADER}' >/dev/null 2>&1; printf '%s' \"\${PATH}\"")"
occurrences2="$(count_path_entries "${OUT_PATH2}" "${HOME}/.local/bin")"
if [[ "${occurrences2}" -eq 1 ]]; then
    # shellcheck disable=SC2088
    ok "sourcing lib/loader.sh again does not duplicate an already-present ~/.local/bin"
else
    # shellcheck disable=SC2088
    fail "~/.local/bin was duplicated on re-source (${occurrences2} occurrences)"
fi

# ── 7. An empty/unset PATH doesn't leave a trailing colon (cwd) element ────
# Uses bash's own absolute path since PATH="" below means the outer shell
# can no longer resolve a bare `bash` to exec the nested shell.
BASH_BIN="$(command -v bash)"
# shellcheck disable=SC2097,SC2098
OUT_EMPTY="$(PATH="" HOME="${HOME}" "${BASH_BIN}" -c "source '${LOADER}' >/dev/null 2>&1; printf '%s' \"\${PATH}\"")"
if [[ "${OUT_EMPTY}" == "${HOME}/.local/bin" ]]; then
    ok "an empty PATH becomes exactly ~/.local/bin, with no trailing colon"
else
    fail "empty PATH produced an unexpected value (possible cwd-in-PATH): '${OUT_EMPTY}'"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
