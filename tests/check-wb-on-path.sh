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

run_link() { ( set --; source "${WB}" >/dev/null 2>&1; _wb_link_cli_bin ) ; }

# ── 1. First run creates the symlink, pointed through `current` ────────────
run_link
LINK="${HOME}/.local/bin/wb"
if [[ -L "${LINK}" ]]; then
    ok "~/.local/bin/wb was created as a symlink"
else
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
echo "${OUT}" | grep -q "leaving it alone" && ok "a warning was logged for the foreign file" \
    || fail "no warning logged for the foreign file"

# ── 4. lib/loader.sh defensively ensures ~/.local/bin is on PATH ───────────
LOADER="${REPO_ROOT}/lib/loader.sh"
OUT_PATH="$(PATH="/usr/bin:/bin" HOME="${HOME}" bash -c "source '${LOADER}' >/dev/null 2>&1; printf '%s' \"\${PATH}\"")"
case ":${OUT_PATH}:" in
    *":${HOME}/.local/bin:"*) ok "sourcing lib/loader.sh prepends ~/.local/bin onto PATH" ;;
    *) fail "lib/loader.sh did not add ~/.local/bin to PATH: ${OUT_PATH}" ;;
esac

occurrences="$(printf '%s' ":${OUT_PATH}:" | grep -o ":${HOME}/.local/bin:" | wc -l | tr -d ' ')"
[[ "${occurrences}" -eq 1 ]] && ok "~/.local/bin appears exactly once on PATH" \
    || fail "~/.local/bin appears ${occurrences} times on PATH, expected 1"

OUT_PATH2="$(PATH="${HOME}/.local/bin:/usr/bin:/bin" HOME="${HOME}" bash -c "source '${LOADER}' >/dev/null 2>&1; printf '%s' \"\${PATH}\"")"
occurrences2="$(printf '%s' ":${OUT_PATH2}:" | grep -o ":${HOME}/.local/bin:" | wc -l | tr -d ' ')"
[[ "${occurrences2}" -eq 1 ]] && ok "sourcing lib/loader.sh again does not duplicate an already-present ~/.local/bin" \
    || fail "~/.local/bin was duplicated on re-source (${occurrences2} occurrences)"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
