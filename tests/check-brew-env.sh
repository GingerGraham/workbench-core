#!/usr/bin/env bash
# tests/check-brew-env.sh — docs/decisions-log.md D134 (Core API 1.14).
#
# lib/loader.sh puts an installed Homebrew on PATH before any tier loads:
# bin and sbin (front on macOS, end on Linux, or as WORKBENCH_BREW_PATH says),
# HOMEBREW_PREFIX/CELLAR/REPOSITORY, and zsh's site-functions on fpath. An
# entry already on PATH is never moved.
#
# The default prefixes (/opt/homebrew, /home/linuxbrew/.linuxbrew) can't be
# created without root, so most cases build a fake prefix in a temp directory
# and point HOMEBREW_PREFIX at it, or use ~/.linuxbrew under a temp HOME. A
# stub `uname` makes one host stand in for the other OS. Only the last case
# needs a real Homebrew, and only runs on a macOS machine that has one.
#
# Every case runs in bash (${BASH}: bash 3.2 in the macOS job) and in zsh
# when it's installed.
#
# SC2016: '$' in single-quoted snippets is for the child shell.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOADER="${REPO_ROOT}/lib/loader.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

REAL_UNAME="$(command -v uname)"
SHELLS="bash"
command -v zsh >/dev/null 2>&1 && SHELLS="bash zsh"

# ── Fixture ──────────────────────────────────────────────────────────────────
HOME_DIR="${WORK}/home"
MODULES_DIR="${WORK}/modules"
mkdir -p "${HOME_DIR}" "${MODULES_DIR}/core"
cat > "${MODULES_DIR}/core/sync.conf" <<EOF
TRACK_MODE=latest
TRACK_REF=v0.1.0
REGISTERED=true
SYNC_ENABLED=true
EOF
cat > "${MODULES_DIR}/core/register.list" <<EOF
${REPO_ROOT}/lib/core/functions.sh|core
EOF

# uname stubs: -s answers for the OS being simulated, everything else is real.
for os_name in Linux Darwin; do
    stub_dir="${WORK}/uname-${os_name}"
    mkdir -p "${stub_dir}"
    printf '#!/bin/sh\ncase "$1" in -s) echo %s ;; *) exec "%s" "$@" ;; esac\n' \
        "${os_name}" "${REAL_UNAME}" > "${stub_dir}/uname"
    chmod +x "${stub_dir}/uname"
done
SYSTEM_PATH="/usr/bin:/bin"

# A fake Homebrew prefix: bin/brew, plus a zsh site-functions directory.
# make_prefix <dir>
make_prefix() {
    mkdir -p "$1/bin" "$1/sbin" "$1/share/zsh/site-functions"
    printf '#!/bin/sh\nexit 0\n' > "$1/bin/brew"
    chmod +x "$1/bin/brew"
}

# run_loader <shell> <os: Linux|Darwin> <path-prefix-dirs-or-empty> <snippet> [VAR=value ...]
# Runs the loader once in a clean environment, then <snippet>. Stdout lands
# in OUT, stderr in ERR. PATH starts as <uname stub>[:<extra>]:/usr/bin:/bin.
OUT=""
ERR=""
run_loader() {
    local shell_name="$1" os_name="$2" extra_path="$3" snippet="$4"
    shift 4
    local start_path="${WORK}/uname-${os_name}"
    [[ -n "${extra_path}" ]] && start_path="${start_path}:${extra_path}"
    start_path="${start_path}:${SYSTEM_PATH}"
    local -a shell_cmd
    if [[ "${shell_name}" == "zsh" ]]; then
        shell_cmd=(zsh -f -c)
    else
        shell_cmd=("${BASH}" -c)
    fi
    OUT="$(
        env -i \
            HOME="${HOME_DIR}" \
            XDG_CONFIG_HOME="${WORK}/xdgconfig" \
            XDG_DATA_HOME="${WORK}/xdgdata" \
            XDG_CACHE_HOME="${WORK}/xdgcache" \
            WORKBENCH_MODULES_DIR="${MODULES_DIR}" \
            WORKBENCH_USER_EXT_ENABLED=false \
            PATH="${start_path}" \
            LOADER="${LOADER}" \
            "$@" \
            "${shell_cmd[@]}" "source \"\${LOADER}\" >/dev/null
${snippet}" 2>"${WORK}/stderr"
    )"
    ERR="$(cat "${WORK}/stderr")"
}

# The common report: PATH, the three variables, fpath (zsh only).
REPORT='
printf "PATH=%s\n" "${PATH}"
printf "PREFIX=%s\n" "${HOMEBREW_PREFIX-UNSET}"
printf "CELLAR=%s\n" "${HOMEBREW_CELLAR-UNSET}"
printf "REPO=%s\n" "${HOMEBREW_REPOSITORY-UNSET}"
if [[ -n "${ZSH_VERSION:-}" ]]; then printf "FPATH=%s\n" "${fpath[*]}"; fi
'

# field <NAME> — one value from OUT.
field() { printf '%s\n' "${OUT}" | sed -n "s/^$1=//p" | head -n 1; }

# expect <description> <actual> <expected>
expect() {
    if [[ "$2" == "$3" ]]; then
        ok "$1"
    else
        fail "$1"
        echo "       expected: $3"
        echo "       actual:   $2"
        [[ -n "${ERR}" ]] && echo "       stderr:   ${ERR}"
    fi
}

# count_in <needle> <haystack> — how many times <needle> appears.
count_in() {
    printf '%s\n' "$2" | grep -oF -- "$1" | wc -l | tr -d ' '
}

P="${WORK}/brew-prefix"
make_prefix "${P}"
BASE="${WORK}/uname-Linux:${SYSTEM_PATH}"
BASE_MAC="${WORK}/uname-Darwin:${SYSTEM_PATH}"
LOCAL_BIN="${HOME_DIR}/.local/bin"

for SH in ${SHELLS}; do
    echo "# ── ${SH} ──"

    # 1. No brew anywhere. Skipped on a machine that has one at a default
    #    prefix: the loader would rightly find it.
    if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
        ok "[${SH}] no brew: skipped, this machine has Homebrew at /home/linuxbrew/.linuxbrew"
    else
        run_loader "${SH}" Linux "" "${REPORT}"
        expect "[${SH}] no brew: PATH is only the start plus ~/.local/bin" \
            "$(field PATH)" "${BASE}:${LOCAL_BIN}"
        expect "[${SH}] no brew: HOMEBREW_PREFIX stays unset" "$(field PREFIX)" "UNSET"
        expect "[${SH}] no brew: HOMEBREW_CELLAR stays unset" "$(field CELLAR)" "UNSET"
    fi

    # 2. Linux default: after ~/.local/bin, bin before sbin.
    run_loader "${SH}" Linux "" "${REPORT}" HOMEBREW_PREFIX="${P}"
    expect "[${SH}] Linux default: end of PATH, after ~/.local/bin, bin then sbin" \
        "$(field PATH)" "${BASE}:${LOCAL_BIN}:${P}/bin:${P}/sbin"
    expect "[${SH}] HOMEBREW_PREFIX exported" "$(field PREFIX)" "${P}"
    expect "[${SH}] HOMEBREW_CELLAR defaults to <prefix>/Cellar" "$(field CELLAR)" "${P}/Cellar"
    expect "[${SH}] HOMEBREW_REPOSITORY is the prefix when there is no Homebrew/ directory" \
        "$(field REPO)" "${P}"

    # 3. Explicit front.
    run_loader "${SH}" Linux "" "${REPORT}" HOMEBREW_PREFIX="${P}" WORKBENCH_BREW_PATH=front
    expect "[${SH}] front: <prefix>/bin:<prefix>/sbin lead PATH" \
        "$(field PATH)" "${P}/bin:${P}/sbin:${BASE}:${LOCAL_BIN}"

    # 3b. Explicit end on macOS, and the macOS default.
    run_loader "${SH}" Darwin "" "${REPORT}" HOMEBREW_PREFIX="${P}"
    expect "[${SH}] macOS default: front" \
        "$(field PATH)" "${P}/bin:${P}/sbin:${BASE_MAC}:${LOCAL_BIN}"
    run_loader "${SH}" Darwin "" "${REPORT}" HOMEBREW_PREFIX="${P}" WORKBENCH_BREW_PATH=end
    expect "[${SH}] macOS with WORKBENCH_BREW_PATH=end: end" \
        "$(field PATH)" "${BASE_MAC}:${LOCAL_BIN}:${P}/bin:${P}/sbin"

    # 4. <p>/bin already in the middle: not moved; sbin follows the mode.
    run_loader "${SH}" Linux "/opt/mid-a:${P}/bin:/opt/mid-b" "${REPORT}" HOMEBREW_PREFIX="${P}"
    expect "[${SH}] bin already mid-PATH: not moved, sbin added at the end" \
        "$(field PATH)" "${WORK}/uname-Linux:/opt/mid-a:${P}/bin:/opt/mid-b:${SYSTEM_PATH}:${LOCAL_BIN}:${P}/sbin"
    run_loader "${SH}" Linux "/opt/mid-a:${P}/bin:/opt/mid-b" "${REPORT}" HOMEBREW_PREFIX="${P}" WORKBENCH_BREW_PATH=front
    expect "[${SH}] bin already mid-PATH, front: not moved, sbin added at the front" \
        "$(field PATH)" "${P}/sbin:${WORK}/uname-Linux:/opt/mid-a:${P}/bin:/opt/mid-b:${SYSTEM_PATH}:${LOCAL_BIN}"

    # 5. off: nothing touched.
    run_loader "${SH}" Linux "" "${REPORT}" HOMEBREW_PREFIX="${P}" WORKBENCH_BREW_PATH=off
    expect "[${SH}] off: PATH has no brew directories" \
        "$(field PATH)" "${BASE}:${LOCAL_BIN}"
    expect "[${SH}] off: HOMEBREW_PREFIX is what the caller set" "$(field PREFIX)" "${P}"
    expect "[${SH}] off: HOMEBREW_CELLAR is not set" "$(field CELLAR)" "UNSET"
    expect "[${SH}] off: HOMEBREW_REPOSITORY is not set" "$(field REPO)" "UNSET"

    # 6. A value that isn't front, end or off: one warning, default applied.
    run_loader "${SH}" Linux "" "${REPORT}" HOMEBREW_PREFIX="${P}" WORKBENCH_BREW_PATH=sideways
    expect "[${SH}] invalid value: the Linux default applies" \
        "$(field PATH)" "${BASE}:${LOCAL_BIN}:${P}/bin:${P}/sbin"
    expect "[${SH}] invalid value: exactly one warning" \
        "$(count_in "WORKBENCH_BREW_PATH='sideways' isn't front, end or off" "${ERR}")" "1"

    # 7. Set only in settings.sh, never exported.
    mkdir -p "${WORK}/xdgconfig/workbench/local"
    printf 'WORKBENCH_BREW_PATH=front\n' > "${WORK}/xdgconfig/workbench/local/settings.sh"
    run_loader "${SH}" Linux "" "${REPORT}" HOMEBREW_PREFIX="${P}"
    expect "[${SH}] settings.sh without export is honoured" \
        "$(field PATH)" "${P}/bin:${P}/sbin:${BASE}:${LOCAL_BIN}"
    rm -f "${WORK}/xdgconfig/workbench/local/settings.sh"

    # 8. A second pass (wb reload) changes nothing.
    run_loader "${SH}" Linux "" '
source "${LOADER}" >/dev/null 2>&1
first_path="${PATH}"
first_fpath=""
if [[ -n "${ZSH_VERSION:-}" ]]; then first_fpath="${fpath[*]}"; fi
source "${LOADER}" >/dev/null 2>&1
second_fpath=""
if [[ -n "${ZSH_VERSION:-}" ]]; then second_fpath="${fpath[*]}"; fi
printf "SAME_PATH=%s\n" "$([[ "${first_path}" == "${PATH}" ]] && echo yes || echo no)"
printf "SAME_FPATH=%s\n" "$([[ "${first_fpath}" == "${second_fpath}" ]] && echo yes || echo no)"
' HOMEBREW_PREFIX="${P}"
    expect "[${SH}] second pass: PATH identical" "$(field SAME_PATH)" "yes"
    expect "[${SH}] second pass: fpath identical" "$(field SAME_FPATH)" "yes"

    # 10. A stale HOMEBREW_PREFIX (no bin/brew) is ignored.
    run_loader "${SH}" Linux "" "${REPORT}" HOMEBREW_PREFIX="${WORK}/gone"
    if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
        ok "[${SH}] stale prefix: skipped, this machine has Homebrew at /home/linuxbrew/.linuxbrew"
    else
        expect "[${SH}] stale prefix: PATH unchanged" "$(field PATH)" "${BASE}:${LOCAL_BIN}"
    fi
    # ...and the candidates are still checked: ~/.linuxbrew under the test HOME.
    if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
        ok "[${SH}] stale prefix falls through to candidates: skipped (Homebrew at /home/linuxbrew/.linuxbrew)"
    else
        make_prefix "${HOME_DIR}/.linuxbrew"
        run_loader "${SH}" Linux "" "${REPORT}" HOMEBREW_PREFIX="${WORK}/gone"
        expect "[${SH}] stale prefix falls through to ~/.linuxbrew on Linux" \
            "$(field PATH)" "${BASE}:${LOCAL_BIN}:${HOME_DIR}/.linuxbrew/bin:${HOME_DIR}/.linuxbrew/sbin"
        expect "[${SH}] stale prefix: HOMEBREW_PREFIX becomes the one found" \
            "$(field PREFIX)" "${HOME_DIR}/.linuxbrew"
        rm -rf "${HOME_DIR}/.linuxbrew"
    fi

    # Variables the caller set are kept; a Homebrew/ directory is the repository.
    mkdir -p "${P}/Homebrew"
    run_loader "${SH}" Linux "" "${REPORT}" HOMEBREW_PREFIX="${P}"
    expect "[${SH}] HOMEBREW_REPOSITORY is <prefix>/Homebrew when that directory exists" \
        "$(field REPO)" "${P}/Homebrew"
    run_loader "${SH}" Linux "" "${REPORT}" HOMEBREW_PREFIX="${P}" HOMEBREW_CELLAR=/mine/cellar HOMEBREW_REPOSITORY=/mine/repo
    expect "[${SH}] HOMEBREW_CELLAR set by the caller is kept" "$(field CELLAR)" "/mine/cellar"
    expect "[${SH}] HOMEBREW_REPOSITORY set by the caller is kept" "$(field REPO)" "/mine/repo"
    rmdir "${P}/Homebrew"

    # The loader leaves no variables of its own behind.
    run_loader "${SH}" Linux "" 'printf "LEFT=%s\n" "${_wb_brew_mode-}${_wb_brew_prefix-}${_wb_brew_dir-}"' HOMEBREW_PREFIX="${P}"
    expect "[${SH}] no _wb_brew_* variables left in the shell" "$(field LEFT)" ""

    # 9. zsh: site-functions on fpath once, on the same side as PATH.
    if [[ "${SH}" == "zsh" ]]; then
        SF="${P}/share/zsh/site-functions"
        run_loader zsh Linux "" "${REPORT}" HOMEBREW_PREFIX="${P}"
        expect "[zsh] site-functions is on fpath exactly once" "$(count_in "${SF}" "$(field FPATH)")" "1"
        case "$(field FPATH)" in
            *" ${SF}") ok "[zsh] default (end): site-functions is last on fpath" ;;
            *) fail "[zsh] default (end): site-functions is last on fpath ($(field FPATH))" ;;
        esac
        run_loader zsh Linux "" "${REPORT}" HOMEBREW_PREFIX="${P}" WORKBENCH_BREW_PATH=front
        case "$(field FPATH)" in
            "${SF} "*) ok "[zsh] front: site-functions is first on fpath" ;;
            *) fail "[zsh] front: site-functions is first on fpath ($(field FPATH))" ;;
        esac
        run_loader zsh Linux "" "${REPORT}" HOMEBREW_PREFIX="${P}" WORKBENCH_BREW_PATH=off
        expect "[zsh] off: fpath is untouched" "$(count_in "${SF}" "$(field FPATH)")" "0"
        # Already there, in the middle: not moved, not repeated. zsh imports
        # FPATH from the environment as its fpath array.
        run_loader zsh Linux "" "${REPORT}" HOMEBREW_PREFIX="${P}" FPATH="/a:${SF}:/b"
        expect "[zsh] site-functions already on fpath: not repeated" "$(count_in "${SF}" "$(field FPATH)")" "1"
        case "$(field FPATH)" in
            "/a ${SF} /b") ok "[zsh] site-functions already on fpath: not moved" ;;
            *) fail "[zsh] site-functions already on fpath: not moved ($(field FPATH))" ;;
        esac
    fi
done

# 11. detect-package-manager: with brew on PATH, a native manager still wins.
echo "# ── detect-package-manager ──"
DNF_BIN="${WORK}/dnf-only"
mkdir -p "${DNF_BIN}"
printf '#!/bin/sh\nexit 0\n' > "${DNF_BIN}/dnf"
chmod +x "${DNF_BIN}/dnf"
for SH in ${SHELLS}; do
    run_loader "${SH}" Linux "" '
PATH="${HOMEBREW_PREFIX}/bin:'"${DNF_BIN}"'"
detect-package-manager >/dev/null 2>&1
printf "PM=%s\n" "${PACKAGE_MANAGER-UNSET}"
printf "BREW=%s\n" "$(command -v brew)"
' HOMEBREW_PREFIX="${P}"
    expect "[${SH}] brew and dnf on PATH: detect-package-manager reports dnf" "$(field PM)" "dnf"
    expect "[${SH}] ...and brew is on PATH in the same shell" "$(field BREW)" "${P}/bin/brew"
done

# 12. A real macOS machine with Homebrew installed. Real uname, real default
#     prefix; PATH starts without it.
echo "# ── real macOS ──"
REAL_PREFIX=""
if [[ "$("${REAL_UNAME}" -s)" == "Darwin" ]]; then
    if [[ -x /opt/homebrew/bin/brew ]]; then
        REAL_PREFIX="/opt/homebrew"
    elif [[ -x /usr/local/bin/brew ]]; then
        REAL_PREFIX="/usr/local"
    fi
fi
if [[ -z "${REAL_PREFIX}" ]]; then
    ok "real macOS: skipped, not a Mac with Homebrew installed"
else
    for SH in ${SHELLS}; do
        OUT="$(
            env -i \
                HOME="${HOME_DIR}" \
                XDG_CONFIG_HOME="${WORK}/xdgconfig" \
                XDG_DATA_HOME="${WORK}/xdgdata" \
                XDG_CACHE_HOME="${WORK}/xdgcache" \
                WORKBENCH_MODULES_DIR="${MODULES_DIR}" \
                WORKBENCH_USER_EXT_ENABLED=false \
                PATH="${SYSTEM_PATH}" \
                LOADER="${LOADER}" \
                "$([[ "${SH}" == "zsh" ]] && echo zsh || echo "${BASH}")" \
                -c "source \"\${LOADER}\" >/dev/null 2>&1
${REPORT}" 2>/dev/null
        )"
        expect "[${SH}] real macOS: ${REAL_PREFIX}/bin leads PATH, then sbin" \
            "$(field PATH | cut -d: -f1-2)" "${REAL_PREFIX}/bin:${REAL_PREFIX}/sbin"
        expect "[${SH}] real macOS: ${REAL_PREFIX}/bin appears once" \
            "$(printf '%s\n' "$(field PATH)" | tr ':' '\n' | grep -cxF "${REAL_PREFIX}/bin")" "1"
        expect "[${SH}] real macOS: HOMEBREW_PREFIX=${REAL_PREFIX}" "$(field PREFIX)" "${REAL_PREFIX}"
    done
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks failed."
exit 1
