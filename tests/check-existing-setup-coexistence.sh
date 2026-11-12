#!/usr/bin/env bash
# tests/check-existing-setup-coexistence.sh — docs/decisions-log.md D110
# acceptance check.
#
# Proves workbench changes only state it created on a host that already has
# a shell profile. Two fixtures, both built by hand (nothing vendored from
# any distribution):
#
#   plain host   — empty rc file, no aliases, no hooks, default PATH. The
#                  shell state after the loader pass must match a golden
#                  file captured from `main` before D110 work began. Any
#                  difference means a change was not additive.
#   distro-style — a profile that sets EDITOR, aliases, a cd wrapper, an
#                  array PROMPT_COMMAND shaped like a real host, and a PATH
#                  with a duplicate. The loader must leave all of it alone.
#
# Regenerate the golden file only on purpose, from a commit whose loader
# behaviour you mean to bless:  WB_UPDATE_GOLDEN=1 bash <this file>
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
WB="${REPO_ROOT}/bin/wb"
GOLDEN="${SCRIPT_DIR}/fixtures/plain-host-state.golden"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── The snapshot command (from the D110 brief), minus the parts that vary
#    by bash version (bash version, shopt, key bindings), so a golden file
#    stays valid across the bash builds CI and developers use. ─────────────
cat > "${WORK}/snapshot.sh" <<'SNAPSHOT_EOF'
snapshot_shell_state() {
    # usage: snapshot_shell_state <output-file>
    {
        echo "## login_shell=$(shopt -q login_shell && echo yes || echo no)"
        echo "## aliases";            alias
        echo "## function names";    declare -F | sed 's/^declare -f //' | grep -v '^snapshot_shell_state$' | sort
        echo "## cd/zd/z bodies";     declare -f cd zd z 2>/dev/null
        echo "## exported env";       env | grep -v '^_=' | sort
        echo "## shell-local vars"
        declare -p HISTSIZE HISTFILESIZE HISTCONTROL HISTIGNORE PS1 PS0 2>/dev/null
        echo "## PROMPT_COMMAND";     declare -p PROMPT_COMMAND 2>/dev/null
        echo "## traps";              trap -p
    } > "$1"
}
SNAPSHOT_EOF

# Normalise paths so a snapshot taken under one temp dir compares equal to
# one taken under another.
#
# Also drops what the machine running the test contributes on its own and
# that has nothing to do with workbench: variables a system profile exports
# (Nix, XDG_DATA_DIRS), the platform facts the loader reads from the host
# (WORKBENCH_OS, WORKBENCH_DISTRO, WORKBENCH_ARCH), where the test ran (PWD,
# which macOS reports as /private/var/… rather than /var/…), bash's own
# default PS1, and what a distro-default system bashrc
# sets (its PS1, a command_not_found_handle function), which bash reads even
# when --rcfile is given.
normalise() {
    sed -e "s#${WORK}#@WORK@#g" -e "s#${REPO_ROOT}#@REPO@#g" \
        -e '/^NIX_/d' \
        -e '/^__ETC_PROFILE_NIX_SOURCED=/d' \
        -e '/^XDG_DATA_DIRS=/d' \
        -e '/^WORKBENCH_DISTRO=/d' \
        -e '/^WORKBENCH_ARCH=/d' \
        -e '/^declare -- PS1=.*debian_chroot/d' \
        -e '/^command_not_found_handle$/d' \
        -e '/^PWD=/d' \
        -e '/^WORKBENCH_OS=/d' \
        -e '/^PATH=/s#[^:=]*nix[^:]*:##g' \
        | grep -vFx 'declare -- PS1="\\s-\\v\\\$ "'
}

# new_host <name> — fresh HOME / XDG dirs under ${WORK}/<name>, with the
# core module's `current` link pointing at this checkout, which is where
# the rc stub looks for the loader.
new_host() {
    local name="$1"
    HOST_DIR="${WORK}/${name}"
    HOST_HOME="${HOST_DIR}/home"
    HOST_DATA="${HOST_DIR}/data"
    HOST_CONFIG="${HOST_DIR}/config"
    HOST_CACHE="${HOST_DIR}/cache"
    mkdir -p "${HOST_HOME}" "${HOST_DATA}/workbench/modules/core" "${HOST_CONFIG}" "${HOST_CACHE}"
    ln -s "${REPO_ROOT}" "${HOST_DATA}/workbench/modules/core/current"
}

# run_shell <rc-file> <command> — an interactive bash with a clean
# environment that reads only <rc-file>. --rcfile also skips the system
# bashrc, so the result does not depend on the machine running the test.
# Extra KEY=VALUE pairs for the inner shell go in RUN_SHELL_ENV.
run_shell() {
    local rc_file="$1" command_text="$2"
    # RUN_SHELL_ENV is deliberately unquoted: it is a list of KEY=VALUE words.
    # shellcheck disable=SC2086
    ( cd -- "${HOST_HOME}" && env -i \
        HOME="${HOST_HOME}" \
        XDG_DATA_HOME="${HOST_DATA}" \
        XDG_CONFIG_HOME="${HOST_CONFIG}" \
        XDG_CACHE_HOME="${HOST_CACHE}" \
        PATH="${RUN_SHELL_PATH:-/usr/local/bin:/usr/bin:/bin}" \
        TERM=dumb \
        ${RUN_SHELL_ENV:-} \
        bash --noprofile --rcfile "${rc_file}" -i -c "${command_text}" 2>&1 )
}

# stub_rc <rc-file> — write the real loader stub with the real function.
stub_rc() {
    local target="$1"
    ( export HOME="${HOST_HOME}" XDG_DATA_HOME="${HOST_DATA}" XDG_CONFIG_HOME="${HOST_CONFIG}" XDG_CACHE_HOME="${HOST_CACHE}"
      # bin/wb reads "$@" when sourced, so clear it first.
      set --
      # shellcheck source=bin/wb
      source "${WB}" >/dev/null 2>&1
      _wb_write_rc_stub "${target}" ) >"${WORK}/stub-write.log" 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
# Plain-host twin
# ═══════════════════════════════════════════════════════════════════════════
new_host plain
: > "${HOST_HOME}/.bashrc"
cp "${HOST_HOME}/.bashrc" "${HOST_HOME}/.bashrc.prestub"

run_shell "${HOST_HOME}/.bashrc.prestub" ". '${WORK}/snapshot.sh'; snapshot_shell_state '${WORK}/plain-before.txt'" >/dev/null
stub_rc "${HOST_HOME}/.bashrc"
run_shell "${HOST_HOME}/.bashrc" ". '${WORK}/snapshot.sh'; snapshot_shell_state '${WORK}/plain-after.txt'" >/dev/null

{
    echo "# plain-host state: before the loader stub, then after it."
    echo "# Generated from main before D110 work began. See the header of"
    echo "# tests/check-existing-setup-coexistence.sh before regenerating."
    echo "######## BEFORE"
    normalise < "${WORK}/plain-before.txt"
    echo "######## AFTER"
    normalise < "${WORK}/plain-after.txt"
} > "${WORK}/plain-golden-candidate.txt"

if [[ -n "${WB_UPDATE_GOLDEN:-}" ]]; then
    mkdir -p "$(dirname -- "${GOLDEN}")"
    cp "${WORK}/plain-golden-candidate.txt" "${GOLDEN}"
    echo "Wrote ${GOLDEN}"
    exit 0
fi

if [[ ! -f "${GOLDEN}" ]]; then
    fail "golden file missing: ${GOLDEN}"
elif diff -u "${GOLDEN}" "${WORK}/plain-golden-candidate.txt" >"${WORK}/plain.diff"; then
    ok "plain host: shell state after the loader pass is identical to the golden state captured from main"
else
    fail "plain host: shell state differs from the golden file — a change was not additive:"
    cat "${WORK}/plain.diff"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Distro-style profile
# ═══════════════════════════════════════════════════════════════════════════
# What a host with its own complete bash profile looks like, written by hand:
# a ~/.bashrc that sources a profile file, which sets EDITOR (with an
# argument), LANG, aliases (one of them `ls`), a `cd` wrapper in both
# function and alias form, an array PROMPT_COMMAND shaped like a measured
# real host (including its duplicate), and a PATH that has one repeated entry
# and ~/.local/bin late.
new_host distro
cat > "${HOST_HOME}/.distro-profile" <<'PROFILE_EOF'
export EDITOR='fake-editor --inline'
export LANG=en_US.UTF-8
alias lsa='ls -a'
alias ls='printf "ALIAS-LS-RAN\n"; command ls'
cd() { printf 'WRAPPER-CALLED\n' >&2; return 1; }
alias cd='printf "ALIAS-CD-RAN\n" >&2; false; :'
PROMPT_COMMAND=(starship_precmd 'printf "\033]0;title\007"' __zoxide_hook __zoxide_hook)
PATH="/usr/local/bin:/usr/bin:/bin:/usr/bin:${HOME}/.local/bin"
PROFILE_EOF
cat > "${HOST_HOME}/.bashrc" <<'BASHRC_EOF'
# distro-style profile
[ -f "$HOME/.distro-profile" ] && . "$HOME/.distro-profile"
BASHRC_EOF
cp "${HOST_HOME}/.bashrc" "${HOST_HOME}/.bashrc.prestub"

# A profile that sets PROMPT_COMMAND as an array needs a shell new enough
# to treat it as one (bash 5.1+); the other checks do not.
run_shell "${HOST_HOME}/.bashrc.prestub" ". '${WORK}/snapshot.sh'; snapshot_shell_state '${WORK}/distro-before.txt'" >/dev/null
stub_rc "${HOST_HOME}/.bashrc"

# 1. The stub sits after the line that sources the profile.
profile_line="$(grep -n 'distro-profile' "${HOST_HOME}/.bashrc" | head -1 | cut -d: -f1)"
stub_line="$(grep -n 'workbench-core loader' "${HOST_HOME}/.bashrc" | head -1 | cut -d: -f1)"
if [[ -n "${profile_line}" && -n "${stub_line}" && "${stub_line}" -gt "${profile_line}" ]]; then
    ok "distro-style: the loader stub is appended after the line that sources the host profile"
else
    fail "distro-style: stub line (${stub_line:-none}) is not after the profile line (${profile_line:-none})"
fi

# 2. Start a shell through the stub; the migration warning (the rc file had
#    content, so a backup was made) is expected until it is acknowledged.
STARTUP_OUT="$(run_shell "${HOST_HOME}/.bashrc" ". '${WORK}/snapshot.sh'; snapshot_shell_state '${WORK}/distro-after.txt'; wb reload >/dev/null 2>&1; snapshot_shell_state '${WORK}/distro-reload.txt'")"
if printf '%s\n' "${STARTUP_OUT}" | grep -q "Shell rc migration pending"; then
    ok "distro-style: an unacknowledged rc-stub backup still warns"
else
    fail "distro-style: expected the migration warning before acknowledging the backup"
fi

# 3. The host's wrappers never ran inside workbench code, and the loader
#    still found its own directory.
if printf '%s\n' "${STARTUP_OUT}" | grep -Eq 'ALIAS-LS-RAN|ALIAS-CD-RAN|WRAPPER-CALLED'; then
    fail "distro-style: a host alias or wrapper ran inside workbench code:"
    printf '%s\n' "${STARTUP_OUT}" | grep -E 'ALIAS-LS-RAN|ALIAS-CD-RAN|WRAPPER-CALLED' | sort | uniq -c
else
    ok "distro-style: no host alias or cd wrapper ran inside workbench code"
fi
if grep -q "^WORKBENCH_LOADER_PATH=${HOST_DATA}/workbench/modules/core/current/lib/loader.sh$" "${WORK}/distro-after.txt"; then
    ok "distro-style: the loader resolved its own path despite the cd wrapper"
else
    fail "distro-style: WORKBENCH_LOADER_PATH is wrong or missing: $(grep '^WORKBENCH_LOADER_PATH=' "${WORK}/distro-after.txt")"
fi

# 4. Nothing the host had is changed or removed. A line only in "before"
#    (diff's "<") would mean workbench altered existing state.
diff "${WORK}/distro-before.txt" "${WORK}/distro-after.txt" > "${WORK}/distro.diff"
removed="$(grep '^<' "${WORK}/distro.diff" || true)"
if [[ -z "${removed}" ]]; then
    ok "distro-style: nothing in the host's shell state was changed or removed by the loader pass"
else
    fail "distro-style: the loader pass changed or removed existing state:"
    printf '%s\n' "${removed}"
fi
if grep '^>' "${WORK}/distro.diff" | grep -q '^> alias '; then
    fail "distro-style: core added an alias"
else
    ok "distro-style: core adds no alias of its own"
fi
for var in EDITOR LANG; do
    if [[ "$(grep "^${var}=" "${WORK}/distro-before.txt")" == "$(grep "^${var}=" "${WORK}/distro-after.txt")" ]]; then
        ok "distro-style: ${var} is unchanged"
    else
        fail "distro-style: ${var} changed"
    fi
done
if grep -q '^LC_ALL=' "${WORK}/distro-after.txt"; then
    fail "distro-style: LC_ALL was set"
else
    ok "distro-style: LC_ALL is not set"
fi

# 5. PROMPT_COMMAND: the host's four entries, the duplicate included, are
#    exactly as they were, after the load and after a wb reload.
BEFORE_PC="$(sed -n '/^## PROMPT_COMMAND$/,/^## traps$/p' "${WORK}/distro-before.txt")"
if [[ "${BASH_VERSINFO[0]}" -gt 5 ]] || { [[ "${BASH_VERSINFO[0]}" -eq 5 ]] && [[ "${BASH_VERSINFO[1]}" -ge 1 ]]; }; then
    if [[ "${BEFORE_PC}" == *'[2]="__zoxide_hook" [3]="__zoxide_hook"'* ]]; then
        ok "distro-style: the fixture really has the duplicate __zoxide_hook (so the next two checks mean something)"
    else
        fail "distro-style: fixture PROMPT_COMMAND is not the expected shape: ${BEFORE_PC}"
    fi
    for stage in after reload; do
        if [[ "$(sed -n '/^## PROMPT_COMMAND$/,/^## traps$/p' "${WORK}/distro-${stage}.txt")" == "${BEFORE_PC}" ]]; then
            ok "distro-style: PROMPT_COMMAND is identical ${stage} (both __zoxide_hook entries, same positions)"
        else
            fail "distro-style: PROMPT_COMMAND changed ${stage}:"
            sed -n '/^## PROMPT_COMMAND$/,/^## traps$/p' "${WORK}/distro-${stage}.txt"
        fi
    done
else
    echo "SKIP: PROMPT_COMMAND array checks need bash 5.1 or later (this is ${BASH_VERSION})"
fi

# 6. PATH: nothing reordered, ~/.local/bin stays where the host put it and
#    is not added a second time. (The loader's documented dedupe-path call
#    drops repeats once core's shell functions are registered, so compare
#    first occurrences.)
first_occurrences() { tr ':' '\n' | awk '!seen[$0]++' | paste -sd: -; }
BEFORE_PATH="$(grep '^PATH=' "${WORK}/distro-before.txt" | head -1 | sed 's/^PATH=//' | first_occurrences)"
AFTER_PATH="$(grep '^PATH=' "${WORK}/distro-after.txt" | head -1 | sed 's/^PATH=//' | first_occurrences)"
if [[ "${BEFORE_PATH}" == "${AFTER_PATH}" ]]; then
    ok "distro-style: PATH order is unchanged, ~/.local/bin stays where the host put it"
else
    fail "distro-style: PATH was reordered or extended:"
    printf '  before: %s\n  after:  %s\n' "${BEFORE_PATH}" "${AFTER_PATH}"
fi
if [[ "$(grep '^PATH=' "${WORK}/distro-after.txt" | head -1 | tr ':' '\n' | grep -c '/\.local/bin$')" -eq 1 ]]; then
    ok "distro-style: ~/.local/bin is on PATH exactly once"
else
    fail "distro-style: ~/.local/bin is on PATH more than once or not at all"
fi

# 7. Once the backup is acknowledged the warning stops, and the backup stays.
BACKUPS="$(find "${HOST_DATA}/workbench/backups" -type f -name 'rc-stub-*' ! -name '*.acknowledged' 2>/dev/null)"
if [[ -n "${BACKUPS}" ]]; then
    printf '%s\n' "${BACKUPS}" | while IFS= read -r backup; do touch "${backup}.acknowledged"; done
    QUIET_OUT="$(run_shell "${HOST_HOME}/.bashrc" "true")"
    if printf '%s\n' "${QUIET_OUT}" | grep -q "Shell rc migration pending"; then
        fail "distro-style: the migration warning still fires after acknowledging"
    else
        ok "distro-style: no migration warning once the backup is acknowledged"
    fi
    if printf '%s\n' "${BACKUPS}" | while IFS= read -r backup; do [[ -f "${backup}" ]] || exit 1; done; then
        ok "distro-style: the acknowledged backup is still on disk"
    else
        fail "distro-style: an acknowledged backup was removed"
    fi
else
    fail "distro-style: writing the stub made no rc-stub backup of the non-empty rc file"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
