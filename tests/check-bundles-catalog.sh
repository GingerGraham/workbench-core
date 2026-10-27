#!/usr/bin/env bash
# tests/check-bundles-catalog.sh — docs/decisions-log.md D88 acceptance check.
#
# The shipped bundles.list and modules.list stay in step: every bundle
# member resolves in the catalog, and 'full' lists exactly the catalog's
# modules. README.md's "Modules and bundles" section names every module
# and bundle. An unknown bundle name is a usage error that changes nothing.
# Offline: no module is fetched.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
export XDG_CACHE_HOME="${WORK}/cache"
mkdir -p "${HOME}"

WB="${REPO_ROOT}/bin/wb"
# shellcheck source=bin/wb
source "${WB}" >"${WORK}/source.log" 2>&1
_wb_require modules/catalog.sh

# No host override in this HOME, so these are the shipped files.
SHIPPED_MODULES="$(workbench_catalog_list_modules | sort)"

# ── 1. Every member of every shipped bundle resolves in the catalog. ───────
unresolved=""
while IFS= read -r bundle; do
    [[ -z "${bundle}" ]] && continue
    while IFS= read -r member; do
        [[ -z "${member}" ]] && continue
        workbench_catalog_lookup "${member}" >/dev/null || unresolved="${unresolved} ${bundle}:${member}"
    done < <(workbench_catalog_bundle_modules "${bundle}")
done < <(workbench_catalog_list_bundles)
if [[ -z "${unresolved}" ]]; then
    ok "every member of every shipped bundle resolves in the shipped modules.list"
else
    fail "bundle members with no catalog entry:${unresolved}"
fi

# ── 2. 'full' is exactly the catalog (order-insensitive). ──────────────────
FULL_MEMBERS="$(workbench_catalog_bundle_modules full | sort)"
if [[ -n "${FULL_MEMBERS}" && "${FULL_MEMBERS}" == "${SHIPPED_MODULES}" ]]; then
    ok "'full' lists exactly the modules in modules.list"
else
    fail "'full' and modules.list differ"
    diff <(echo "${FULL_MEMBERS}") <(echo "${SHIPPED_MODULES}")
fi

# ── 3-4. README's "Modules and bundles" section names every module and ─────
# bundle, so the table can't go stale when one is added. Each name must
# appear in backticks inside that section.
readme_section="$(awk '
    /^## Modules and bundles$/ { in_section = 1; next }
    /^## / && in_section { exit }
    in_section { print }
' "${REPO_ROOT}/README.md")"

missing_modules=""
while IFS= read -r module; do
    [[ -z "${module}" ]] && continue
    case "${readme_section}" in
        *"\`${module}\`"*) ;;
        *) missing_modules="${missing_modules} ${module}" ;;
    esac
done <<< "${SHIPPED_MODULES}"
if [[ -n "${readme_section}" && -z "${missing_modules}" ]]; then
    ok "README's Modules and bundles section names every module in modules.list"
else
    fail "README's Modules and bundles section is missing or lacks modules:${missing_modules}"
fi

missing_bundles=""
while IFS= read -r bundle; do
    [[ -z "${bundle}" ]] && continue
    case "${readme_section}" in
        *"\`${bundle}\`"*) ;;
        *) missing_bundles="${missing_bundles} ${bundle}" ;;
    esac
done < <(workbench_catalog_list_bundles)
if [[ -n "${readme_section}" && -z "${missing_bundles}" ]]; then
    ok "README's Modules and bundles section names every bundle in bundles.list"
else
    fail "README's Modules and bundles section is missing or lacks bundles:${missing_bundles}"
fi

# ── 5-8. wb install --bundle <unknown> changes nothing. ────────────────────
bash "${WB}" install --bundle no-such-bundle </dev/null >"${WORK}/install.log" 2>&1
rc=$?
if [[ "${rc}" -eq 2 ]]; then
    ok "'wb install --bundle no-such-bundle' exits 2"
else
    fail "'wb install --bundle no-such-bundle' exited ${rc}, expected 2"
    cat "${WORK}/install.log"
fi

known_line="$(grep 'Known bundles:' "${WORK}/install.log")"
missing_names=""
for bundle in workstation server minimal full; do
    case "${known_line} " in
        *" ${bundle} "*) ;;
        *) missing_names="${missing_names} ${bundle}" ;;
    esac
done
if [[ -z "${missing_names}" ]]; then
    ok "the error names the known bundles"
else
    fail "the error does not name:${missing_names}"
    cat "${WORK}/install.log"
fi

if [[ ! -e "${XDG_DATA_HOME}/workbench/modules" ]] \
    || [[ -z "$(ls -A "${XDG_DATA_HOME}/workbench/modules" 2>/dev/null)" ]]; then
    ok "nothing was created under XDG_DATA_HOME/workbench/modules"
else
    fail "modules were created despite the unknown bundle: $(ls -A "${XDG_DATA_HOME}/workbench/modules")"
fi

if [[ ! -e "${HOME}/.bashrc" && ! -e "${HOME}/.zshrc" && ! -e "${HOME}/.zshenv" ]]; then
    ok "no rc stub was written"
else
    fail "an rc file was written despite the unknown bundle"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
