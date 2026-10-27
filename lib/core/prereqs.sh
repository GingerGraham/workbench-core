#!/usr/bin/env bash
# lib/core/prereqs.sh — prerequisite detection and (optional) installation
# for `wb install`.
#
# Confirmed gap fixed here (docs/architecture.md §7 item 1, build brief §2/Phase
# 1): the donor codebase's install.sh never checked awk (a hard dependency
# of dedupe-path() and the host-vars reader), which is confirmed absent on
# minimal Fedora WSL images. This enumerates every external binary any
# Core API function or the distribution engine calls — the shell prereqs,
# needed for the Core API library and the hot sync path (register.shell/
# loader/wb add/wb track/timer). Since D92 there is no separate
# install-time list: wb install/apply need nothing beyond these.

_wb_prereqs_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib/core/functions.sh
[[ -f "${_wb_prereqs_lib_dir}/functions.sh" ]] && source "${_wb_prereqs_lib_dir}/functions.sh"
# shellcheck source=lib/core/semver.sh
[[ -f "${_wb_prereqs_lib_dir}/semver.sh" ]] && source "${_wb_prereqs_lib_dir}/semver.sh"

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/core/prereqs.sh" "0.1.2" || true

# Binary -> minimum-viable description, in check order. gpg is optional
# (only needed if GPG-related functionality is used later, e.g. by a future
# workbench-gpg module) — checked and reported, never blocks install.
# unzip/zip are optional for the same reason gpg is: nothing in
# workbench-core itself needs them, but Wave C modules distributing
# .zip-packaged tools will. Checked and reported now (same as gpg) so a
# module author knows before shipping whether they can rely on it being
# present — like every other optional prereq, wb install/wb apply only
# install missing REQUIRED prereqs (workbench_install_shell_prereqs
# below); optional ones are checked/reported only, never installed
# automatically. No install-mapping needed either way — the binary and
# package names match on every package manager checked
# (apt/dnf/yum/zypper/pacman/brew).
# ssh-keygen is required alongside ssh-keyscan (Phase 6's deploy-key
# generation, lib/ssh/bootstrap.sh) — not called out as a separate line item
# in the original gap list, but bundled in the same openssh-client(s)
# package on every distro checked, so no separate install-mapping is needed
# beyond what ssh-keyscan already requires (see
# workbench_install_shell_prereqs' package-name mapping below).
_WB_SHELL_PREREQS_REQUIRED=(awk sed tr grep column git curl ssh-keyscan ssh-keygen)
_WB_SHELL_PREREQS_OPTIONAL=(gpg unzip zip)

# workbench_check_shell_prereqs
# Prints one INFO/WARN line per binary and returns the count of missing
# required binaries via stdout (0 = all present). Never installs anything —
# see workbench_install_shell_prereqs for that.
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

# workbench_install_shell_prereqs
# Installs any missing required shell prereqs via the detected package
# manager. Requires elevation (sudo/run0) except on brew, which never runs
# as root. Idempotent — packages already satisfying a binary are skipped by
# the package manager itself.
workbench_install_shell_prereqs() {
    local -a missing=()
    while IFS= read -r bin; do
        [[ -n "${bin}" ]] && missing+=("${bin}")
    done < <(workbench_missing_shell_prereqs)

    if [[ "${#missing[@]}" -eq 0 ]]; then
        log_info "workbench: all required shell prerequisites already present"
        return 0
    fi

    detect-package-manager || return 1
    log_info "workbench: installing missing prerequisites (${missing[*]}) via ${PACKAGE_MANAGER}"

    local -a pkgs=()
    local bin
    for bin in "${missing[@]}"; do
        case "${PACKAGE_MANAGER}:${bin}" in
            # column moved out of util-linux into bsdextrautils on modern
            # Debian/Ubuntu (confirmed on Ubuntu 24.04 during this build —
            # `util-linux` alone does not provide it there); still bundled
            # in util-linux itself on RHEL/Fedora, SUSE, Arch, and Homebrew.
            apt:column)                                    pkgs+=(bsdextrautils) ;;
            dnf:column|yum:column|zypper:column)            pkgs+=(util-linux) ;;
            pacman:column)                                 pkgs+=(util-linux) ;;
            brew:column)                                   pkgs+=(util-linux) ;;
            apt:ssh-keyscan|apt:ssh-keygen|pacman:ssh-keyscan|pacman:ssh-keygen) pkgs+=(openssh-client) ;;
            *:ssh-keyscan|*:ssh-keygen)                     pkgs+=(openssh-clients) ;;
            *:*)                                           pkgs+=("${bin}") ;;
        esac
    done

    case "${PACKAGE_MANAGER}" in
        apt)
            elevate-cmd apt-get update -qq
            elevate-cmd apt-get install -y "${pkgs[@]}"
            ;;
        dnf)    elevate-cmd dnf install -y "${pkgs[@]}" ;;
        yum)    elevate-cmd yum install -y "${pkgs[@]}" ;;
        zypper) elevate-cmd zypper install -y "${pkgs[@]}" ;;
        pacman) elevate-cmd pacman -Sy --noconfirm "${pkgs[@]}" ;;
        brew)   brew install "${pkgs[@]}" ;;
        *)
            log_error "workbench: unknown package manager — install manually: ${missing[*]}"
            return 1
            ;;
    esac
}
