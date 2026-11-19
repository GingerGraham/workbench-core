#!/usr/bin/env bash
# lib/core/prereqs.sh — prerequisite detection and, once the user says
# yes, installation for `wb install` (docs/decisions-log.md D117).
#
# Confirmed gap fixed here (docs/architecture.md §7 item 1, build brief §2/Phase
# 1): the donor codebase's install.sh never checked awk (a hard dependency
# of dedupe-path() and the host-vars reader), which is confirmed absent on
# minimal Fedora WSL images. This enumerates every external binary any
# Core API function or the distribution engine calls — the shell prereqs,
# needed for the Core API library and the hot sync path (register.shell/
# loader/wb add/wb track/timer). Since D92 there is no separate
# install-time list: wb install/apply need nothing beyond these.

_wb_prereqs_lib_dir="$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib/core/functions.sh
[[ -f "${_wb_prereqs_lib_dir}/functions.sh" ]] && source "${_wb_prereqs_lib_dir}/functions.sh"
# shellcheck source=lib/core/semver.sh
[[ -f "${_wb_prereqs_lib_dir}/semver.sh" ]] && source "${_wb_prereqs_lib_dir}/semver.sh"

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/core/prereqs.sh" "0.2.0" || true

# Binary -> minimum-viable description, in check order. gpg is optional
# (only needed if GPG-related functionality is used later, e.g. by a future
# workbench-gpg module) — checked and reported, never blocks install.
# unzip/zip are optional for the same reason gpg is: nothing in
# workbench-core itself needs them, but Wave C modules distributing
# .zip-packaged tools will. Checked and reported now (same as gpg) so a
# module author knows before shipping whether they can rely on it being
# present — like every other optional prereq, wb install/wb apply only
# offer to install missing REQUIRED prereqs (workbench_ensure_shell_prereqs
# below); optional ones are checked/reported only, never installed.
# No install-mapping needed either way — the binary and package names
# match on every package manager checked (apt/dnf/yum/zypper/pacman/brew).
# ssh-keygen is required alongside ssh-keyscan (Phase 6's deploy-key
# generation, lib/ssh/bootstrap.sh) — not called out as a separate line item
# in the original gap list, but bundled in the same openssh-client(s)
# package on every distro checked, so no separate install-mapping is needed
# beyond what ssh-keyscan already requires (see _wb_prereq_package below).
_WB_SHELL_PREREQS_REQUIRED=(awk sed tr grep column git curl ssh-keyscan ssh-keygen)
_WB_SHELL_PREREQS_OPTIONAL=(gpg unzip zip)

# workbench_check_shell_prereqs
# Prints one INFO/WARN line per binary and returns the count of missing
# required binaries via stdout (0 = all present). Never installs anything —
# see workbench_ensure_shell_prereqs for that.
workbench_check_shell_prereqs() {
    local bin missing=0
    for bin in "${_WB_SHELL_PREREQS_REQUIRED[@]}"; do
        if command -v "${bin}" &>/dev/null; then
            log_info "prereq: ${bin}: found"
        else
            log_warn "prereq: ${bin}: not found (required)"
            missing=$((missing + 1))
        fi
    done
    for bin in "${_WB_SHELL_PREREQS_OPTIONAL[@]}"; do
        if command -v "${bin}" &>/dev/null; then
            log_info "prereq: ${bin}: found (optional)"
        else
            log_info "prereq: ${bin}: not found (optional — skip if unused)"
        fi
    done
    echo "${missing}"
}

# workbench_missing_shell_prereqs
# Prints the names of missing required shell prereqs, one per line.
workbench_missing_shell_prereqs() {
    local bin
    for bin in "${_WB_SHELL_PREREQS_REQUIRED[@]}"; do
        command -v "${bin}" &>/dev/null || echo "${bin}"
    done
}

# _wb_prereq_package <package-manager> <binary>
# The package that provides <binary> under <package-manager>, named
# explicitly rather than left to the package manager's "provides" lookup,
# so the question shows exactly what will be installed. bootstrap.sh
# carries its own copy of the rows for the six binaries it checks itself
# (curl tar awk sed tr grep); tests/check-prereqs.sh keeps the two in step.
#   awk      apt's 'awk' is a virtual package apt won't pick a provider
#            for; mawk is Debian/Ubuntu's default. gawk elsewhere.
#   tr       part of coreutils everywhere; there is no 'tr' package.
#   column   moved out of util-linux into bsdextrautils on modern
#            Debian/Ubuntu (confirmed on Ubuntu 24.04); still util-linux
#            on RHEL/Fedora, SUSE, Arch and Homebrew.
#   git      git-core on dnf/yum: /usr/bin/git without the Perl tooling
#            (git-svn, git send-email, ...) the full 'git' package pulls
#            in. Core only needs the binary.
#   ssh-*    one package provides both ssh-keyscan and ssh-keygen; its
#            name differs per distro (Arch and Homebrew: openssh).
_wb_prereq_package() {
    case "$1:$2" in
        apt:awk)                                    echo "mawk" ;;
        *:awk)                                      echo "gawk" ;;
        *:tr)                                       echo "coreutils" ;;
        apt:column)                                 echo "bsdextrautils" ;;
        *:column)                                   echo "util-linux" ;;
        dnf:git|yum:git)                            echo "git-core" ;;
        apt:ssh-keyscan|apt:ssh-keygen)             echo "openssh-client" ;;
        pacman:ssh-keyscan|pacman:ssh-keygen)       echo "openssh" ;;
        brew:ssh-keyscan|brew:ssh-keygen)           echo "openssh" ;;
        *:ssh-keyscan|*:ssh-keygen)                 echo "openssh-clients" ;;
        *)                                          echo "$2" ;;
    esac
}

# _wb_prereq_elevation <package-manager>
# Prints the elevation command shown in the question: nothing for brew
# (never runs as root) or when already root, else sudo, else run0.
# Returns 1 when none is available. The real call goes through
# elevate-cmd (_wb_prereq_elevated), which can pick run0 over sudo when
# sudo is present but not permitted; this is only for display.
_wb_prereq_elevation() {
    [[ "$1" == "brew" ]] && return 0
    [[ "$(id -u)" -eq 0 ]] && return 0
    if command -v sudo &>/dev/null; then echo "sudo"; return 0; fi
    if command -v run0 &>/dev/null; then echo "run0"; return 0; fi
    return 1
}

# _wb_prereq_elevated <command> [args...]
# Runs directly as root (a bare container has no sudo), else via
# elevate-cmd.
_wb_prereq_elevated() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        elevate-cmd "$@"
    fi
}

# _wb_prereq_describe <package-manager> <elevation> <package>...
# _wb_prereq_run <package-manager> <package>...
# The install command as shown in the question, and the same command run.
# Keep the two case statements in step.
_wb_prereq_describe() {
    local pm="$1" elev="$2"
    shift 2
    local p=""
    [[ -n "${elev}" ]] && p="${elev} "
    case "${pm}" in
        apt)    echo "${p}apt-get update -qq && ${p}apt-get install -y $*" ;;
        dnf)    echo "${p}dnf install -y $*" ;;
        yum)    echo "${p}yum install -y $*" ;;
        zypper) echo "${p}zypper install -y $*" ;;
        pacman) echo "${p}pacman -Sy --noconfirm $*" ;;
        brew)   echo "brew install $*" ;;
    esac
}

_wb_prereq_run() {
    local pm="$1"
    shift
    case "${pm}" in
        apt)
            _wb_prereq_elevated apt-get update -qq || return 1
            _wb_prereq_elevated apt-get install -y "$@"
            ;;
        dnf)    _wb_prereq_elevated dnf install -y "$@" ;;
        yum)    _wb_prereq_elevated yum install -y "$@" ;;
        zypper) _wb_prereq_elevated zypper install -y "$@" ;;
        pacman) _wb_prereq_elevated pacman -Sy --noconfirm "$@" ;;
        brew)   brew install "$@" ;;
        *)      return 1 ;;
    esac
}

# _wb_prereq_ask — 0 when the person at /dev/tty answers yes. Its own
# function so tests can answer it.
_wb_prereq_ask() {
    local answer=""
    printf 'Install them now? [y/N]: ' >/dev/tty
    if ! IFS= read -r answer </dev/tty; then
        echo >/dev/tty
        return 1
    fi
    case "${answer}" in
        y|Y|yes|YES) return 0 ;;
    esac
    return 1
}

# workbench_ensure_shell_prereqs <label> <yes:true|false>
# Detect, report, ask, install, check again (docs/decisions-log.md D117).
# Nothing is installed without a yes: from the person at /dev/tty, or
# from --yes. Questions go through /dev/tty, so they work under
# `curl … | bash`.
#   0  every required prereq is present (already, or installed now)
#   1  can't install: no package manager, no root/sudo/run0, no terminal
#      and no --yes, the package manager failed, or a binary is still
#      missing afterwards
#   2  the user said no
workbench_ensure_shell_prereqs() {
    local label="$1" yes="$2"
    local -a missing=() pkgs=()
    local bin pkg elev="" seen=" " still

    while IFS= read -r bin; do
        [[ -n "${bin}" ]] && missing+=("${bin}")
    done < <(workbench_missing_shell_prereqs)
    [[ "${#missing[@]}" -eq 0 ]] && return 0

    if ! detect-package-manager; then
        log_error "${label}: required tools are missing: ${missing[*]} — install them with your system's package manager, then re-run. Nothing was changed."
        return 1
    fi

    {
        echo
        echo "${label}: these required tools are missing:"
        for bin in "${missing[@]}"; do
            pkg="$(_wb_prereq_package "${PACKAGE_MANAGER}" "${bin}")"
            printf '  %-12s from package %s\n' "${bin}" "${pkg}"
            case "${seen}" in
                *" ${pkg} "*) ;;
                *) pkgs+=("${pkg}"); seen="${seen}${pkg} " ;;
            esac
        done
        echo
    } >&2

    if ! elev="$(_wb_prereq_elevation "${PACKAGE_MANAGER}")"; then
        log_error "${label}: installing packages needs root, sudo or run0, and none is available. As root, run: $(_wb_prereq_describe "${PACKAGE_MANAGER}" "" "${pkgs[@]}") — then re-run. Nothing was changed."
        return 1
    fi
    echo "workbench can install them with:" >&2
    echo "  $(_wb_prereq_describe "${PACKAGE_MANAGER}" "${elev}" "${pkgs[@]}")" >&2
    echo >&2

    if [[ "${yes}" != "true" ]]; then
        if ! _wb_have_tty; then
            log_error "${label}: no terminal to ask before installing them — run the command above yourself, or re-run with --yes to let workbench run it. Nothing was changed."
            return 1
        fi
        if ! _wb_prereq_ask; then
            log_info "${label}: not installing them — install them yourself, then re-run the same command. Nothing was changed."
            return 2
        fi
    fi

    log_info "${label}: installing ${pkgs[*]} via ${PACKAGE_MANAGER}"
    if ! _wb_prereq_run "${PACKAGE_MANAGER}" "${pkgs[@]}"; then
        log_error "${label}: ${PACKAGE_MANAGER} could not install ${pkgs[*]} — install ${missing[*]} yourself, then re-run."
        return 1
    fi

    # Checked again, not assumed: a package can install cleanly and still
    # not provide the binary (a wrong row in _wb_prereq_package).
    hash -r
    still="$(workbench_missing_shell_prereqs | tr '\n' ' ')"
    if [[ -n "${still// /}" ]]; then
        log_error "${label}: still missing after installing ${pkgs[*]}: ${still}— install them yourself, then re-run."
        return 1
    fi
    # The package manager's output pushes the report off screen; say what
    # happened once it's done.
    log_info "${label}: installed ${pkgs[*]} (for ${missing[*]})"
    return 0
}
