#!/usr/bin/env bash
# tests/check-prompt-reset-on-reload.sh — ARCHITECTURE.md §12 D50
# acceptance check.
#
# Two synthetic prompt-owning modules, each appending to PROMPT_COMMAND
# and preserving whatever was already there — the same shape real
# well-behaved prompt tools (starship's documented bash init, for one)
# use to coexist with unrelated tools, which is exactly the shape that
# leaves a stale hook behind when one engine is meant to *replace*
# another across a reload rather than coexist with it. Verifies: a
# second engine's hook doesn't inherit the first's leftover
# PROMPT_COMMAND entry on re-source, WORKBENCH_PROMPT_ENGINE flips
# correctly either way (regression guard — that part already worked), and
# a genuinely first-ever load with no module electing at all leaves a
# user's own pre-stub PROMPT_COMMAND customisation untouched.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export XDG_CONFIG_HOME="${WORK}/config"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CACHE_HOME="${WORK}/cache"
export WORKBENCH_MODULES_DIR="${WORK}/modules"
export HOME="${WORK}/home"
mkdir -p "${HOME}" "${WORK}/modules/engine-a" "${WORK}/modules/engine-b" "${WORK}/src-a" "${WORK}/src-b"

# Both fixtures append-and-preserve, exactly like a real, well-behaved
# prompt tool's init script — deliberately NOT a plain overwrite, since
# that shape wouldn't reproduce the bug this test guards against.
cat > "${WORK}/src-a/tool.sh" <<'EOF'
if [[ -n "${FAKE_ENGINE_OVERRIDE:-}" ]]; then
    [[ "${FAKE_ENGINE_OVERRIDE}" == "a" ]] || return 0
fi
engine_a_hook() { PS1="[a]$ "; }
PROMPT_COMMAND="engine_a_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
export WORKBENCH_PROMPT_ENGINE="engine-a"
export WORKBENCH_PROMPT_SET=true
EOF

cat > "${WORK}/src-b/tool.sh" <<'EOF'
if [[ -n "${FAKE_ENGINE_OVERRIDE:-}" ]]; then
    [[ "${FAKE_ENGINE_OVERRIDE}" == "b" ]] || return 0
else
    return 0
fi
engine_b_hook() { PS1="[b]$ "; }
PROMPT_COMMAND="engine_b_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
export WORKBENCH_PROMPT_ENGINE="engine-b"
export WORKBENCH_PROMPT_SET=true
EOF

for m in engine-a engine-b; do
    cat > "${WORK}/modules/${m}/sync.conf" <<EOF
TRACK_MODE=latest
TRACK_REF=v1.0.0
REGISTERED=true
SYNC_ENABLED=true
EOF
done
echo "${WORK}/src-a/tool.sh|tools" > "${WORK}/modules/engine-a/register.list"
echo "${WORK}/src-b/tool.sh|tools" > "${WORK}/modules/engine-b/register.list"

# ── 1-2. Switching engines across a reload: no stale hook, correct
#    election. ──────────────────────────────────────────────────────────
# Isolated with 'env -i' plus an explicit allowlist, matching the sibling
# loader suites (tests/check-loader-multi-root.sh,
# tests/check-local-overrides.sh) — lib/loader.sh reads many env vars, and
# a bare 'bash -c' would otherwise inherit the caller's full environment.
# That matters concretely here: if this suite is run from inside an
# already-active workbench shell, WORKBENCH_PROMPT_SET=true would already
# be exported, so the loader's reset would fire on this very first
# 'source' before engine-a ever runs — a false pass/fail depending on the
# caller's shell state instead of a reproducible result.
# Fed to the isolated bash via a heredoc rather than 'bash -c "...${VAR}..."'
# — with 'env -i' in front, shellcheck's parser loses track of the
# single/double-quote boundaries in the latter form and misreports
# SC2016 on every 'source' line after the first; a heredoc lets
# REPO_ROOT expand normally (unquoted delimiter) while every
# runtime-only variable is backslash-escaped to defer its expansion to
# the inner shell, with no embedded quote-switching trick needed at all.
OUT="$(
    env -i \
        HOME="${HOME}" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
        WORKBENCH_MODULES_DIR="${WORKBENCH_MODULES_DIR}" \
        PATH="${PATH}" \
        FAKE_ENGINE_OVERRIDE=a \
        bash <<INNER_EOF
        source "${REPO_ROOT}/lib/loader.sh" >/dev/null 2>&1
        source "${REPO_ROOT}/lib/loader.sh" >/dev/null 2>&1
        echo "STAGE1_PC=\${PROMPT_COMMAND:-unset}"
        export FAKE_ENGINE_OVERRIDE=b
        source "${REPO_ROOT}/lib/loader.sh" >/dev/null 2>&1
        echo "STAGE2_PC=\${PROMPT_COMMAND:-unset}"
        echo "STAGE2_ENGINE=\${WORKBENCH_PROMPT_ENGINE:-unset}"
        eval "\${PROMPT_COMMAND}" 2>/dev/null
        echo "STAGE2_PS1=\${PS1:-unset}"
INNER_EOF
)"

stage2_pc="$(printf '%s\n' "${OUT}" | grep '^STAGE2_PC=' | sed 's/^STAGE2_PC=//')"
if [[ "${stage2_pc}" == "engine_b_hook" ]]; then
    ok "switching engines across a reload leaves no stale hook in PROMPT_COMMAND"
else
    fail "PROMPT_COMMAND still contains a stale entry after switching engines: '${stage2_pc}'"
fi

stage2_engine="$(printf '%s\n' "${OUT}" | grep '^STAGE2_ENGINE=' | sed 's/^STAGE2_ENGINE=//')"
if [[ "${stage2_engine}" == "engine-b" ]]; then
    ok "WORKBENCH_PROMPT_ENGINE correctly reflects the newly-elected engine"
else
    fail "WORKBENCH_PROMPT_ENGINE did not update correctly: '${stage2_engine}'"
fi

stage2_ps1="$(printf '%s\n' "${OUT}" | grep '^STAGE2_PS1=' | sed 's/^STAGE2_PS1=//')"
if [[ "${stage2_ps1}" == "[b]\$ " ]]; then
    ok "the visible prompt reflects the newly-elected engine, not the stale one"
else
    fail "the visible prompt did not update: '${stage2_ps1}' (this is the exact symptom reported)"
fi

# ── 3. A genuinely first-ever load, nothing electing, never touches a
#    user's own pre-stub PROMPT_COMMAND customisation. ────────────────────
# Same env -i isolation as stages 1-2, for the same reason — plus
# FAKE_ENGINE_OVERRIDE is deliberately set to a sentinel neither fixture
# matches, so both engine-a's and engine-b's guards skip and genuinely
# nothing elects, matching what this stage's name claims.
OUT2="$(
    env -i \
        HOME="${HOME}" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
        WORKBENCH_MODULES_DIR="${WORKBENCH_MODULES_DIR}" \
        PATH="${PATH}" \
        FAKE_ENGINE_OVERRIDE=none \
        bash <<INNER_EOF
        PROMPT_COMMAND="my_own_custom_hook"
        source "${REPO_ROOT}/lib/loader.sh" >/dev/null 2>&1
        echo "\${PROMPT_COMMAND:-unset}"
INNER_EOF
)"
if [[ "${OUT2}" == *"my_own_custom_hook"* ]]; then
    ok "a user's own pre-stub PROMPT_COMMAND customisation survives a first, never-reloaded load"
else
    fail "pre-existing PROMPT_COMMAND customisation was wiped on first load: '${OUT2}'"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
