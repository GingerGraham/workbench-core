#!/usr/bin/env bash
# tests/check-prompt-reset-on-reload.sh — docs/decisions-log.md D50
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

# Engines c and d append the way the array-aware prompt tools do (a scalar
# gets "; hook" added, an array gets a new element), which is the shape the
# D110 stages below need. Same override convention as a and b.
for letter in c d; do
    mkdir -p "${WORK}/modules/engine-${letter}" "${WORK}/src-${letter}"
    cat > "${WORK}/src-${letter}/tool.sh" <<EOF
[[ "\${FAKE_ENGINE_OVERRIDE:-}" == "${letter}" ]] || return 0
engine_${letter}_hook() { :; }
case "\$(declare -p PROMPT_COMMAND 2>/dev/null)" in
    "declare -a"*) PROMPT_COMMAND[\${#PROMPT_COMMAND[@]}]="engine_${letter}_hook" ;;
    *)             PROMPT_COMMAND="\${PROMPT_COMMAND:+\${PROMPT_COMMAND}; }engine_${letter}_hook" ;;
esac
export WORKBENCH_PROMPT_ENGINE="engine-${letter}"
export WORKBENCH_PROMPT_SET=true
EOF
done

for m in engine-a engine-b engine-c engine-d; do
    cat > "${WORK}/modules/${m}/sync.conf" <<EOF
TRACK_MODE=latest
TRACK_REF=v1.0.0
REGISTERED=true
SYNC_ENABLED=true
EOF
done
echo "${WORK}/src-a/tool.sh|tools" > "${WORK}/modules/engine-a/register.list"
echo "${WORK}/src-b/tool.sh|tools" > "${WORK}/modules/engine-b/register.list"
echo "${WORK}/src-c/tool.sh|tools" > "${WORK}/modules/engine-c/register.list"
echo "${WORK}/src-d/tool.sh|tools" > "${WORK}/modules/engine-d/register.list"

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

# ═══════════════════════════════════════════════════════════════════════════
# D110: a reload removes only what workbench added.
# ═══════════════════════════════════════════════════════════════════════════
# scenario <body> — run <body> in a clean non-interactive bash with a
# `load` helper that sources the loader quietly. Prints what the body prints.
scenario() {
    printf '%s\n' "load() { source \"${REPO_ROOT}/lib/loader.sh\" >/dev/null 2>&1; }" "$1" > "${WORK}/scenario.sh"
    env -i \
        HOME="${HOME}" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
        WORKBENCH_MODULES_DIR="${WORKBENCH_MODULES_DIR}" \
        PATH="${PATH}" \
        bash "${WORK}/scenario.sh" 2>&1
}

# expect <label> <expected> <actual>
expect() {
    if [[ "$3" == "$2" ]]; then
        ok "$1"
    else
        fail "$1"
        printf '      expected: %s\n      actual:   %s\n' "$2" "$3"
    fi
}

# Shapes that exist on real hosts (measured on one): hooks in element
# order, a duplicate, and in a login shell an empty element and a hook from
# the system's own profile script.
HOST_TITLE='printf "\033]0;title\007"'

# ── 4. Starting with PROMPT_COMMAND unset ─────────────────────────────────
# shellcheck disable=SC2016  # the scenario body is meant to expand inside the inner shell
OUT="$(scenario '
export FAKE_ENGINE_OVERRIDE=c
load; echo "FIRST=$(declare -p PROMPT_COMMAND 2>&1)"
load; load; echo "TWICE=$(declare -p PROMPT_COMMAND 2>&1)"
export FAKE_ENGINE_OVERRIDE=d
load; echo "SWAPPED=$(declare -p PROMPT_COMMAND 2>&1)"')"
expect "unset: first load leaves only the engine hook" \
    'FIRST=declare -- PROMPT_COMMAND="engine_c_hook"' "$(printf '%s\n' "${OUT}" | grep '^FIRST=')"
expect "unset: two reloads add nothing" \
    'TWICE=declare -- PROMPT_COMMAND="engine_c_hook"' "$(printf '%s\n' "${OUT}" | grep '^TWICE=')"
expect "unset: switching engine leaves the new hook only" \
    'SWAPPED=declare -- PROMPT_COMMAND="engine_d_hook"' "$(printf '%s\n' "${OUT}" | grep '^SWAPPED=')"

# ── 5. Starting with a scalar PROMPT_COMMAND ──────────────────────────────
# shellcheck disable=SC2016  # the scenario body is meant to expand inside the inner shell
OUT="$(scenario '
PROMPT_COMMAND="host_a; host_b"
export FAKE_ENGINE_OVERRIDE=c
load; echo "FIRST=$(declare -p PROMPT_COMMAND 2>&1)"
load; load; echo "TWICE=$(declare -p PROMPT_COMMAND 2>&1)"
export FAKE_ENGINE_OVERRIDE=d
load; echo "SWAPPED=$(declare -p PROMPT_COMMAND 2>&1)"
# Foreign hook added after workbench loaded survives the next reload.
PROMPT_COMMAND="${PROMPT_COMMAND}; foreign_late"
load; echo "FOREIGN=$(declare -p PROMPT_COMMAND 2>&1)"')"
expect "scalar: first load keeps the host text and appends the engine hook" \
    'FIRST=declare -- PROMPT_COMMAND="host_a; host_b; engine_c_hook"' "$(printf '%s\n' "${OUT}" | grep '^FIRST=')"
expect "scalar: two reloads do not grow it" \
    'TWICE=declare -- PROMPT_COMMAND="host_a; host_b; engine_c_hook"' "$(printf '%s\n' "${OUT}" | grep '^TWICE=')"
expect "scalar: switching engine swaps only the engine hook" \
    'SWAPPED=declare -- PROMPT_COMMAND="host_a; host_b; engine_d_hook"' "$(printf '%s\n' "${OUT}" | grep '^SWAPPED=')"
expect "scalar: a foreign hook added after the first load survives a reload" \
    'FOREIGN=declare -- PROMPT_COMMAND="host_a; host_b; foreign_late; engine_d_hook"' "$(printf '%s\n' "${OUT}" | grep '^FOREIGN=')"

# A prepending engine (a and b, the shape D50's fixtures used) on a scalar.
# shellcheck disable=SC2016  # the scenario body is meant to expand inside the inner shell
OUT="$(scenario '
PROMPT_COMMAND="host_a; host_b"
export FAKE_ENGINE_OVERRIDE=a
load; load; echo "TWICE=$(declare -p PROMPT_COMMAND 2>&1)"
export FAKE_ENGINE_OVERRIDE=b
load; echo "SWAPPED=$(declare -p PROMPT_COMMAND 2>&1)"')"
expect "scalar, engine that prepends: two reloads do not grow it" \
    'TWICE=declare -- PROMPT_COMMAND="engine_a_hook;host_a; host_b"' "$(printf '%s\n' "${OUT}" | grep '^TWICE=')"
expect "scalar, engine that prepends: switching engine swaps only its hook" \
    'SWAPPED=declare -- PROMPT_COMMAND="engine_b_hook;host_a; host_b"' "$(printf '%s\n' "${OUT}" | grep '^SWAPPED=')"

# Array-form PROMPT_COMMAND is only meaningful from bash 5.1.
if [[ "${BASH_VERSINFO[0]}" -gt 5 ]] || { [[ "${BASH_VERSINFO[0]}" -eq 5 ]] && [[ "${BASH_VERSINFO[1]}" -ge 1 ]]; }; then
    # ── 6. Starting with an array PROMPT_COMMAND ──────────────────────────
    # shellcheck disable=SC2016  # the scenario body is meant to expand inside the inner shell
OUT="$(scenario '
PROMPT_COMMAND=(host_a host_b host_c)
export FAKE_ENGINE_OVERRIDE=c
load; echo "FIRST=$(declare -p PROMPT_COMMAND 2>&1)"
load; load; echo "TWICE=$(declare -p PROMPT_COMMAND 2>&1)"
export FAKE_ENGINE_OVERRIDE=d
load; echo "SWAPPED=$(declare -p PROMPT_COMMAND 2>&1)"
PROMPT_COMMAND+=(foreign_late)
load; echo "FOREIGN=$(declare -p PROMPT_COMMAND 2>&1)"')"
    expect "array: first load keeps the host entries in order and adds the engine hook" \
        'FIRST=declare -a PROMPT_COMMAND=([0]="host_a" [1]="host_b" [2]="host_c" [3]="engine_c_hook")' "$(printf '%s\n' "${OUT}" | grep '^FIRST=')"
    expect "array: two reloads do not grow it" \
        'TWICE=declare -a PROMPT_COMMAND=([0]="host_a" [1]="host_b" [2]="host_c" [3]="engine_c_hook")' "$(printf '%s\n' "${OUT}" | grep '^TWICE=')"
    expect "array: switching engine swaps only the engine hook" \
        'SWAPPED=declare -a PROMPT_COMMAND=([0]="host_a" [1]="host_b" [2]="host_c" [3]="engine_d_hook")' "$(printf '%s\n' "${OUT}" | grep '^SWAPPED=')"
    expect "array: a foreign hook added after the first load survives a reload" \
        'FOREIGN=declare -a PROMPT_COMMAND=([0]="host_a" [1]="host_b" [2]="host_c" [3]="foreign_late" [4]="engine_d_hook")' "$(printf '%s\n' "${OUT}" | grep '^FOREIGN=')"

    # ── 7. The measured host shape, duplicate included. ───────────────────
    OUT="$(scenario "
PROMPT_COMMAND=(starship_precmd '${HOST_TITLE}' __zoxide_hook __zoxide_hook)
export FAKE_ENGINE_OVERRIDE=c
load; echo \"FIRST=\$(declare -p PROMPT_COMMAND 2>&1)\"
load; load; echo \"TWICE=\$(declare -p PROMPT_COMMAND 2>&1)\"
export FAKE_ENGINE_OVERRIDE=d
load; echo \"SWAPPED=\$(declare -p PROMPT_COMMAND 2>&1)\"")"
    HOST_FIRST='declare -a PROMPT_COMMAND=([0]="starship_precmd" [1]="printf \"\\033]0;title\\007\"" [2]="__zoxide_hook" [3]="__zoxide_hook" [4]="engine_c_hook")'
    expect "host shape: both __zoxide_hook entries survive the first load, in place" \
        "FIRST=${HOST_FIRST}" "$(printf '%s\n' "${OUT}" | grep '^FIRST=')"
    expect "host shape: repeated reloads leave the host's entries exactly as they were" \
        "TWICE=${HOST_FIRST}" "$(printf '%s\n' "${OUT}" | grep '^TWICE=')"
    expect "host shape: switching engine touches only the engine hook" \
        "SWAPPED=${HOST_FIRST//engine_c_hook/engine_d_hook}" "$(printf '%s\n' "${OUT}" | grep '^SWAPPED=')"

    # ── 8. The host's init runs again between two loader passes
    #    (`source ~/.bashrc` typed by hand): its second run appends another
    #    __zoxide_hook. The result is the host's entries as they now stand,
    #    plus exactly one set of workbench entries. ─────────────────────────
    OUT="$(scenario "
PROMPT_COMMAND=(starship_precmd '${HOST_TITLE}' __zoxide_hook __zoxide_hook)
export FAKE_ENGINE_OVERRIDE=c
load
PROMPT_COMMAND+=(__zoxide_hook)
load; echo \"RERUN=\$(declare -p PROMPT_COMMAND 2>&1)\"")"
    expect "host init re-run between passes: host entries as they stand, one engine hook" \
        'RERUN=declare -a PROMPT_COMMAND=([0]="starship_precmd" [1]="printf \"\\033]0;title\\007\"" [2]="__zoxide_hook" [3]="__zoxide_hook" [4]="__zoxide_hook" [5]="engine_c_hook")' \
        "$(printf '%s\n' "${OUT}" | grep '^RERUN=')"

    # ── 9. Login-shell shape: an empty element and a hook from the system's
    #    own profile script are kept, in place. ─────────────────────────────
    OUT="$(scenario "
PROMPT_COMMAND=(starship_precmd '' __systemd_osc_context_precmdline '${HOST_TITLE}' __zoxide_hook __zoxide_hook)
export FAKE_ENGINE_OVERRIDE=c
load; load; echo \"LOGIN=\$(declare -p PROMPT_COMMAND 2>&1)\"")"
    expect "login-shell shape: the empty element and the system hook stay in place" \
        'LOGIN=declare -a PROMPT_COMMAND=([0]="starship_precmd" [1]="" [2]="__systemd_osc_context_precmdline" [3]="printf \"\\033]0;title\\007\"" [4]="__zoxide_hook" [5]="__zoxide_hook" [6]="engine_c_hook")' \
        "$(printf '%s\n' "${OUT}" | grep '^LOGIN=')"
else
    echo "SKIP: array PROMPT_COMMAND stages need bash 5.1 or later (this is ${BASH_VERSION})"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
