#!/usr/bin/env bash
# tests/check-distro-id-tier.sh — docs/decisions-log.md D126 acceptance check.
#
# A distro-tier file loads when its basename equals WORKBENCH_DISTRO (the
# family) or WORKBENCH_DISTRO_ID (the exact os-release ID), and never on
# ID_LIKE. Covers the selector table (bash, and zsh when installed), live
# detection, the stale-shell re-detect, the character-set rule, and that the
# loader and the generated getter agree on which files apply.
# shellcheck disable=SC2016  # the bash -c bodies are single-quoted on purpose
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }
skip() { echo "SKIP: $*"; }

WORK="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/home"

# ── 1. Selector table ───────────────────────────────────────────────────────
# One row per line: family|id|basename|expected. An id of "-" means
# WORKBENCH_DISTRO_ID is unset.
cat > "${WORK}/table.txt" <<'TABLE'
rhel|fedora|rhel|load
rhel|fedora|fedora|load
rhel|rocky|fedora|skip
rhel|fedora|ubuntu|skip
debian|pop|pop|load
debian|pop|ubuntu|skip
debian|pop|debian|load
debian|ubuntu|ubuntu|load
suse|opensuse-leap|opensuse-leap|load
suse|opensuse-leap|opensuse-tumbleweed|skip
unknown|nixos|nixos|load
unknown|unknown|unknown|load
rhel|-|fedora|skip
rhel|-|rhel|load
TABLE

# The selector run, written once and run in each shell. It prints one line
# per row: family|id|base|expect|got.
cat > "${WORK}/selector-run.sh" <<RUN
source "${REPO_ROOT}/lib/loader-select.sh"
WORKBENCH_OS=Linux
WORKBENCH_WSL=false
while IFS='|' read -r family id base expect; do
    [ -n "\${family}" ] || continue
    WORKBENCH_DISTRO="\${family}"
    if [ "\${id}" = "-" ]; then
        unset WORKBENCH_DISTRO_ID
    else
        WORKBENCH_DISTRO_ID="\${id}"
    fi
    if _wb_loader_should_source_by_name distro "\${base}"; then
        got=load
    else
        got=skip
    fi
    printf '%s|%s|%s|%s|%s\n' "\${family}" "\${id}" "\${base}" "\${expect}" "\${got}"
done < "${WORK}/table.txt"
RUN

check_selector_table() {
    local shell="$1" family id base expect got out
    out="$(env -i HOME="${WORK}/home" PATH="${PATH}" "${shell}" -f "${WORK}/selector-run.sh" 2>&1 </dev/null)"
    if [[ -z "${out}" ]]; then
        fail "${shell}: selector table printed nothing"
        return
    fi
    while IFS='|' read -r family id base expect got; do
        if [[ "${expect}" == "${got}" ]]; then
            ok "${shell}: DISTRO=${family} DISTRO_ID=${id} base=${base} → ${got}"
        else
            fail "${shell}: DISTRO=${family} DISTRO_ID=${id} base=${base} → ${got} (expected ${expect})"
        fi
    done <<< "${out}"
}

check_selector_table bash
if command -v zsh >/dev/null 2>&1; then
    check_selector_table zsh
else
    skip "zsh is not installed — the zsh selector cases were not run"
fi

# ── 2. Live detection ───────────────────────────────────────────────────────
# Only meaningful on a Linux host with /etc/os-release. The expected ID is
# read from the file and run through the same character-set rule.
LIVE_ID=""
if [[ "$(uname -s)" == "Linux" && -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    LIVE_ID="$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")"
    case "${LIVE_ID}" in
        ''|*[!abcdefghijklmnopqrstuvwxyz0123456789._-]*) LIVE_ID="unknown" ;;
    esac

    detected="$(env -i HOME="${WORK}/home" PATH="${PATH}" bash -c '
        source "'"${REPO_ROOT}"'/lib/core/functions.sh" >/dev/null 2>&1
        printf "%s" "${WORKBENCH_DISTRO_ID:-}"
    ')"
    if [[ "${detected}" == "${LIVE_ID}" ]]; then
        ok "live detection: WORKBENCH_DISTRO_ID is '${detected}', the ID in /etc/os-release"
    else
        fail "live detection: WORKBENCH_DISTRO_ID is '${detected}', /etc/os-release says '${LIVE_ID}'"
    fi
else
    skip "no /etc/os-release on this host — live detection not run"
fi

# ── 3. Stale-shell re-detect ────────────────────────────────────────────────
# A shell started before D126 exported WORKBENCH_PLATFORM_DETECTED=true and
# no WORKBENCH_DISTRO_ID; _workbench_detect_platform must fill it in.
stale="$(env -i HOME="${WORK}/home" PATH="${PATH}" bash -c '
    source "'"${REPO_ROOT}"'/lib/core/functions.sh" >/dev/null 2>&1
    export WORKBENCH_PLATFORM_DETECTED=true
    unset WORKBENCH_DISTRO_ID
    _workbench_detect_platform
    printf "%s" "${WORKBENCH_DISTRO_ID:-}"
')"
if [[ -n "${stale}" ]]; then
    ok "stale shell: WORKBENCH_DISTRO_ID re-detected as '${stale}'"
else
    fail "stale shell: WORKBENCH_DISTRO_ID still empty after _workbench_detect_platform"
fi

# The guard still short-circuits when the variable is present, so detection
# doesn't re-run on every call.
kept="$(env -i HOME="${WORK}/home" PATH="${PATH}" bash -c '
    source "'"${REPO_ROOT}"'/lib/core/functions.sh" >/dev/null 2>&1
    export WORKBENCH_PLATFORM_DETECTED=true
    WORKBENCH_DISTRO_ID=sentinel-id
    _workbench_detect_platform
    printf "%s" "${WORKBENCH_DISTRO_ID}"
')"
if [[ "${kept}" == "sentinel-id" ]]; then
    ok "idempotent: an already-detected platform is left alone"
else
    fail "idempotent: WORKBENCH_DISTRO_ID was overwritten ('${kept}') on an already-detected platform"
fi

# ── 4. Character-set rule ───────────────────────────────────────────────────
# The detection reads a fixed path, so the rule's own case pattern is run
# here, in bash and in zsh, against values that must and must not pass.
cat > "${WORK}/charset.sh" <<'CHARSET'
for v in fedora opensuse-leap a.b_c-1 '' 'Fedora' 'fed ora' 'fed;ora' 'fed$ora' 'ünï'; do
    case "${v}" in
        ''|*[!abcdefghijklmnopqrstuvwxyz0123456789._-]*) r="unknown" ;;
        *)                 r="${v}" ;;
    esac
    printf '%s=>%s\n' "${v}" "${r}"
done
CHARSET
# shellcheck disable=SC2016  # the value with a dollar sign is literal on purpose
expected_charset="$(printf '%s\n' 'fedora=>fedora' 'opensuse-leap=>opensuse-leap' 'a.b_c-1=>a.b_c-1' '=>unknown' 'Fedora=>unknown' 'fed ora=>unknown' 'fed;ora=>unknown' 'fed$ora=>unknown' 'ünï=>unknown')"
# The rule has to be the same text in both detection copies, or this test
# stops covering the code.
RULE="''|*[!abcdefghijklmnopqrstuvwxyz0123456789._-]*) WORKBENCH_DISTRO_ID="
for detection_file in lib/loader.sh lib/core/functions.sh; do
    if grep -qF -- "${RULE}" "${REPO_ROOT}/${detection_file}"; then
        ok "${detection_file} uses the listed-characters rule this test checks"
    else
        fail "${detection_file} does not contain the rule this test checks"
    fi
done
# A range like a-z follows the locale's collation, and on macOS bash 3.2 in a
# UTF-8 locale accepts uppercase and accented letters. Run the rule in a
# UTF-8 locale too, when the host has one.
LOCALES="C"
for candidate in en_US.UTF-8 C.UTF-8; do
    if locale -a 2>/dev/null | grep -qix "$(printf '%s' "${candidate}" | sed 's/UTF-8/utf8/')\|${candidate}"; then
        LOCALES="${LOCALES} ${candidate}"
    fi
done
for shell in bash zsh; do
    if ! command -v "${shell}" >/dev/null 2>&1; then
        skip "${shell} is not installed — character-set rule not run there"
        continue
    fi
    for loc in ${LOCALES}; do
    got="$(LC_ALL="${loc}" "${shell}" -f "${WORK}/charset.sh" 2>&1 </dev/null)"
    if [[ "${got}" == "${expected_charset}" ]]; then
        ok "${shell}, locale ${loc}: the character-set rule accepts a-z 0-9 . _ - and nothing else"
    else
        fail "${shell}, locale ${loc}: character-set rule gave unexpected results"
        printf '%s\n' "${got}"
    fi
    done
done

# ── 5. Loader and getter agree ──────────────────────────────────────────────
# A module registers a family file, a file for this host's exact ID and a
# third file for an ID that isn't this host's. The loader must source the
# first two only, and the generated getter must list functions from the
# first two only.
if [[ -n "${LIVE_ID}" && "${LIVE_ID}" != "unknown" ]]; then
    FAMILY="$(env -i HOME="${WORK}/home" PATH="${PATH}" bash -c '
        source "'"${REPO_ROOT}"'/lib/core/functions.sh" >/dev/null 2>&1
        printf "%s" "${WORKBENCH_DISTRO}"
    ')"
    OTHER=""
    for candidate in fedora ubuntu pop nixos; do
        if [[ "${candidate}" != "${LIVE_ID}" && "${candidate}" != "${FAMILY}" ]]; then
            OTHER="${candidate}"
            break
        fi
    done

    MODULES_DIR="${WORK}/modules"
    SRC="${WORK}/acme-src"
    mkdir -p "${MODULES_DIR}/core" "${MODULES_DIR}/acme-widget" "${SRC}"
    cat > "${MODULES_DIR}/core/sync.conf" <<CONF
TRACK_MODE=latest
TRACK_REF=v0.1.0
REGISTERED=true
SYNC_ENABLED=true
CONF
    printf '%s|core\n' "${REPO_ROOT}/lib/core/functions.sh" > "${MODULES_DIR}/core/register.list"
    cat > "${MODULES_DIR}/acme-widget/sync.conf" <<CONF
TRACK_MODE=latest
TRACK_REF=v1.0.0
REGISTERED=true
SYNC_ENABLED=true
CONF
    : > "${MODULES_DIR}/acme-widget/register.list"
    printf 'get-acme-functions|Acme helpers\n' > "${MODULES_DIR}/acme-widget/getters.list"

    # add_distro_file <basename> <function name>: a distro-tier file that
    # logs its own name when sourced and defines one function.
    add_distro_file() {
        local name="$1" fn="$2"
        # shellcheck disable=SC2016
        printf 'WB_TEST_LOG="${WB_TEST_LOG}%s "\n%s() { :; }\n' "${name}" "${fn}" > "${SRC}/${name}.sh"
        printf '%s|distro\n' "${SRC}/${name}.sh" >> "${MODULES_DIR}/acme-widget/register.list"
    }
    # Family file first, then the ID file, then the one that must not load.
    # When the family and the ID are the same word it is one file.
    add_distro_file "${FAMILY}" "acme_family_fn"
    if [[ "${LIVE_ID}" != "${FAMILY}" ]]; then
        add_distro_file "${LIVE_ID}" "acme_id_fn"
    fi
    add_distro_file "${OTHER}" "acme_other_fn"

    out="$(env -i \
        HOME="${WORK}/home" \
        XDG_CONFIG_HOME="${WORK}/xdgconfig" \
        XDG_DATA_HOME="${WORK}/xdgdata" \
        XDG_CACHE_HOME="${WORK}/xdgcache" \
        WORKBENCH_MODULES_DIR="${MODULES_DIR}" \
        WORKBENCH_USER_EXT_ENABLED=false \
        PATH="${PATH}" \
        bash -c '
            source "'"${REPO_ROOT}"'/lib/loader.sh"
            echo "TEST_LOG=${WB_TEST_LOG}"
            _wb_module_getter acme-widget get-acme-functions
        ' 2>&1)"

    test_log="$(printf '%s\n' "${out}" | grep '^TEST_LOG=' | sed 's/^TEST_LOG=//')"

    case " ${test_log}" in
        *" ${FAMILY} "*) ok "loader: sourced the family file (${FAMILY}.sh)" ;;
        *) fail "loader: did not source the family file (${FAMILY}.sh); log: '${test_log}'" ;;
    esac
    if [[ "${LIVE_ID}" != "${FAMILY}" ]]; then
        case " ${test_log}" in
            *" ${LIVE_ID} "*) ok "loader: sourced the exact-ID file (${LIVE_ID}.sh)" ;;
            *) fail "loader: did not source the exact-ID file (${LIVE_ID}.sh); log: '${test_log}'" ;;
        esac
    else
        skip "this host's ID equals its family (${FAMILY}), so there is no separate exact-ID file"
    fi
    case " ${test_log}" in
        *" ${OTHER} "*) fail "loader: sourced ${OTHER}.sh, which is for another distribution; log: '${test_log}'" ;;
        *) ok "loader: skipped ${OTHER}.sh, which is for another distribution" ;;
    esac

    if printf '%s\n' "${out}" | grep -q 'acme_family_fn'; then
        ok "getter: lists the family file's functions"
    else
        fail "getter: does not list the family file's functions"
    fi
    if [[ "${LIVE_ID}" != "${FAMILY}" ]]; then
        if printf '%s\n' "${out}" | grep -q 'acme_id_fn'; then
            ok "getter: lists the exact-ID file's functions"
        else
            fail "getter: does not list the exact-ID file's functions"
        fi
    fi
    if printf '%s\n' "${out}" | grep -q 'acme_other_fn'; then
        fail "getter: lists functions from ${OTHER}.sh, which doesn't apply to this host"
    else
        ok "getter: leaves out ${OTHER}.sh, which doesn't apply to this host"
    fi
else
    skip "no usable os-release ID on this host — loader/getter agreement not run"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
