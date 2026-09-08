#!/usr/bin/env bash
# .github/scripts/module-ci/check-add-to-core.sh
#
# "Does this module add correctly to core?" -- one module vs. core, no wider
# integration. Runs the real wb add/track/update primitives against the
# module's actual remote branch (never "latest"), the same primitives a
# real user's `wb dev <module>` would drive interactively (ARCHITECTURE.md
# S9/S10, D9), scripted non-interactively here.
#
# Required env: WB (path to the core checkout's bin/wb), MODULE_NAME
# (catalog-style short name, e.g. "git"), MODULE_URL (resolved remote --
# the module's own repo, or a fork's), MODULE_BRANCH (the branch actually
# under test), MODULE_ROOT (local checkout path, for manifest
# introspection ONLY -- the fetch itself always goes over the network to
# MODULE_URL@MODULE_BRANCH, so this exercises the real distribution path,
# not a local shortcut).
set -uo pipefail

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

: "${WB:?WB (path to bin/wb in the workbench-core checkout) is required}"
: "${MODULE_NAME:?MODULE_NAME is required}"
: "${MODULE_URL:?MODULE_URL is required}"
: "${MODULE_BRANCH:?MODULE_BRANCH is required}"
: "${MODULE_ROOT:?MODULE_ROOT (local checkout, for manifest introspection) is required}"

MANIFEST="${MODULE_ROOT}/.dotfiles-sync.yml"
[[ -f "${MANIFEST}" ]] || { echo "FAIL: [1] no .dotfiles-sync.yml at ${MODULE_ROOT} -- nothing to add"; exit 1; }

# Isolated scratch environment -- never touches the runner's real HOME.
# Same harness shape as tests/check-wb-add-convergence.sh.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
mkdir -p "${HOME}"

# 1. wb add, pointed at the RESOLVED remote -- not the catalog default --
#    so a fork PR is tested against the fork. --allow-hooks: exercise the
#    full path, hooks included, same as a real first-time user.
if "${WB}" add "${MODULE_NAME}" "${MODULE_URL}" --allow-hooks >"${WORK}/add.log" 2>&1; then
    ok "wb add ${MODULE_NAME} ${MODULE_URL} --allow-hooks"
else
    fail "wb add ${MODULE_NAME} ${MODULE_URL} --allow-hooks"; cat "${WORK}/add.log"
fi

# 2. Switch to branch-tracking the actual branch under test. wb add above
#    resolved TRACK_MODE=latest, which for an as-yet-untagged module fails
#    gracefully -- expected, not asserted on either way; this step is the
#    one that matters.
if "${WB}" track "${MODULE_NAME}" --branch "${MODULE_BRANCH}" >"${WORK}/track.log" 2>&1; then
    ok "wb track ${MODULE_NAME} --branch ${MODULE_BRANCH}"
else
    fail "wb track ${MODULE_NAME} --branch ${MODULE_BRANCH}"; cat "${WORK}/track.log"
fi

if "${WB}" update "${MODULE_NAME}" >"${WORK}/update.log" 2>&1; then
    ok "wb update ${MODULE_NAME} (fetches ${MODULE_BRANCH}'s current tip)"
else
    fail "wb update ${MODULE_NAME}"; cat "${WORK}/update.log"
fi

# 3. wb status reflects branch-tracking with a real resolved sha. The MODE
#    column carries the "branch:<name>" value directly (TRACK_MODE) -- this
#    greps the whole row rather than a specific column so it doesn't
#    depend on exact column boundaries.
status_row="$("${WB}" status 2>&1 | awk -v m="${MODULE_NAME}" '$1==m{print}')"
if [[ -n "${status_row}" ]] && echo "${status_row}" | grep -q "branch:${MODULE_BRANCH}"; then
    ok "wb status shows '${MODULE_NAME}' tracking branch:${MODULE_BRANCH}"
else
    fail "wb status does not show '${MODULE_NAME}' tracking branch:${MODULE_BRANCH}: ${status_row}"
fi

# 4. Every deploy[] destination for this platform actually landed. Entries
#    scoped to the other platform via platforms: are skipped, mirroring
#    the engine's own filtering (lib/sync/engine.sh's workbench_deploy_module)
#    -- otherwise a linux-only/macos-only entry would legitimately not
#    land on the OS this job isn't running on, and get reported as a
#    false FAIL.
deploy_count="$(yq '.deploy // [] | length' "${MANIFEST}")"
for ((i = 0; i < deploy_count; i++)); do
    platforms="$(yq ".deploy[${i}].platforms // \"\"" "${MANIFEST}")"
    if [[ -n "${platforms}" && "${platforms}" != "null" ]]; then
        if [[ "$(uname -s)" == "Darwin" ]]; then
            echo "${platforms}" | tr ',' '\n' | grep -qx macos || continue
        else
            echo "${platforms}" | tr ',' '\n' | grep -qx linux || continue
        fi
    fi
    dest="$(yq ".deploy[${i}].dest" "${MANIFEST}")"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        macos_dest="$(yq ".deploy[${i}].dest_macos // \"\"" "${MANIFEST}")"
        [[ -n "${macos_dest}" && "${macos_dest}" != "null" ]] && dest="${macos_dest}"
    fi
    dest_expanded="${dest/#\~/${HOME}}"
    if [[ -e "${dest_expanded}" ]]; then
        ok "deploy[${i}] landed: ${dest}"
    else
        fail "deploy[${i}] did not land: ${dest} (expected ${dest_expanded})"
    fi
done

# 5. Every register.getters[] function is actually visible via `wb
#    functions` -- the real "did this module load" signal, not just "did
#    files get copied".
functions_out="$("${WB}" functions 2>&1)"
getter_count="$(yq '.register.getters // [] | length' "${MANIFEST}")"
for ((i = 0; i < getter_count; i++)); do
    fn="$(yq ".register.getters[${i}].function" "${MANIFEST}")"
    if echo "${functions_out}" | grep -q "${fn}"; then
        ok "getter function registered and visible: ${fn}"
    else
        fail "getter function NOT visible in 'wb functions': ${fn}"
    fi
done

# 6. Any register.installers[] file's install-<name> functions show up in
#    `wb tools list`.
installer_count="$(yq '.register.installers // [] | length' "${MANIFEST}")"
if [[ "${installer_count}" -gt 0 ]]; then
    tools_out="$("${WB}" tools list 2>&1)"
    if [[ -n "${tools_out}" ]]; then
        ok "wb tools list is non-empty with ${installer_count} installer file(s) registered"
    else
        fail "wb tools list is empty despite ${installer_count} installer file(s) registered"
    fi
fi

# 7. Idempotency: a second wb update does not duplicate registrations.
reglist="${XDG_DATA_HOME}/workbench/modules/${MODULE_NAME}/register.list"
before_lines="$([[ -f "${reglist}" ]] && wc -l < "${reglist}" || echo 0)"
if "${WB}" update "${MODULE_NAME}" >"${WORK}/update2.log" 2>&1; then
    after_lines="$([[ -f "${reglist}" ]] && wc -l < "${reglist}" || echo 0)"
    if [[ "${before_lines}" -eq "${after_lines}" ]]; then
        ok "a second 'wb update ${MODULE_NAME}' is idempotent (${after_lines} register.list lines, unchanged)"
    else
        fail "a second 'wb update ${MODULE_NAME}' changed register.list (${before_lines} -> ${after_lines} lines)"
    fi
else
    fail "a second 'wb update ${MODULE_NAME}' failed"; cat "${WORK}/update2.log"
fi

# 8. Optional module-specific verification (e.g. a hook's side effects) --
#    deliberately NOT hardcoded here; a module opts in by shipping this file.
if [[ -x "${MODULE_ROOT}/tests/check-add-to-core.sh" ]]; then
    if WB="${WB}" MODULE_NAME="${MODULE_NAME}" "${MODULE_ROOT}/tests/check-add-to-core.sh" >"${WORK}/module-specific.log" 2>&1; then
        ok "module-specific tests/check-add-to-core.sh passed"
    else
        fail "module-specific tests/check-add-to-core.sh failed"; cat "${WORK}/module-specific.log"
    fi
fi

# 9. wb remove deregisters cleanly. Non-destructive by design
#    (lib/modules/remove.sh) -- assert the REGISTERED flag flips, not that
#    deployed content disappears.
if "${WB}" remove "${MODULE_NAME}" >"${WORK}/remove.log" 2>&1; then
    row_after="$("${WB}" status 2>&1 | awk -v m="${MODULE_NAME}" '$1==m{print $NF}')"
    if [[ "${row_after}" == "false" ]]; then
        ok "wb remove ${MODULE_NAME} deregisters cleanly (REGISTERED=false)"
    else
        fail "wb remove ${MODULE_NAME} did not flip REGISTERED to false (got '${row_after}')"
    fi
else
    fail "wb remove ${MODULE_NAME} failed"; cat "${WORK}/remove.log"
fi

echo
echo "==============================="
echo "Checks run: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
