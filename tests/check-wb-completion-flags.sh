#!/usr/bin/env bash
# tests/check-wb-completion-flags.sh — Phase 3 'wb completion' acceptance
# check (docs/decisions-log.md D122): flag-name completion, introspected
# from the case arms each command parses, and the target argument of
# 'wb module reset <name>' / 'wb files use <name>', read fresh per module.
# Sibling of check-wb-completion.sh (Phase 1) and check-wb-completion-args.sh
# (Phase 2).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WB="${REPO_ROOT}/bin/wb"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
# A module snapshot is read-only (D120); unseal before deleting.
trap 'chmod -R u+w "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT

export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
mkdir -p "${HOME}" "${WORK}/bin"
ln -s "${WB}" "${WORK}/bin/wb"
export PATH="${WORK}/bin:${PATH}"

# shellcheck source=bin/wb
source "${WB}" >"${WORK}/source.log" 2>&1
_wb_require modules/add.sh modules/remove.sh

# flags_of <command> [<sub>] — one line, space-separated
flags_of() { _wb_completion_command_flags "$@" | paste -sd' ' -; }
has_flag() { printf '%s\n' "$1" | tr ' ' '\n' | grep -qxF -- "$2"; }

# ── 1. Flags are read from each command's own case arms ─────────────────────
check_flags() {
    local label="$1" got="$2"
    shift 2
    local want missing=""
    for want in "$@"; do
        has_flag "${got}" "${want}" || missing="${missing} ${want}"
    done
    if [[ -z "${missing}" ]]; then
        ok "${label}: offers $*"
    else
        fail "${label}: missing${missing} (got: ${got})"
    fi
}
check_flags "wb add"        "$(flags_of add)"          --private --allow-hooks --skip-layer --stage-only --latest --keep-version --yes
check_flags "wb track"      "$(flags_of track)"        --latest --branch --tag --commit
check_flags "wb install"    "$(flags_of install)"      --bundle --use-files --keep-files --follow --yes
check_flags "wb remove"     "$(flags_of remove)"       --restore --yes
check_flags "wb revert"     "$(flags_of revert)"       --list --yes
check_flags "wb uninstall"  "$(flags_of uninstall)"    --dry-run --yes
check_flags "wb files use"  "$(flags_of files use)"    --follow --yes
check_flags "wb files policy" "$(flags_of files policy)" --default --yes
check_flags "wb tools list" "$(flags_of tools list)"   --status

# 'wb module reset' is a forwarder to 'wb files use' (D81): it has no case
# arms of its own, and offers exactly what the function it forwards to parses.
if [[ "$(flags_of module reset)" == "$(flags_of files use)" && -n "$(flags_of module reset)" ]]; then
    ok "wb module reset offers the flags of the function it forwards to"
else
    fail "wb module reset flags '$(flags_of module reset)' differ from files use '$(flags_of files use)'"
fi

# ── 2. What must never be offered ───────────────────────────────────────────
# --skip-ansible is accepted and ignored (an arm with an empty body); --help
# is on every command; -y and -h are short forms.
all_flags="$(for c in $(_wb_completion_dispatch_commands); do flags_of "${c}"; done | tr ' ' '\n' | sort -u)"
if ! has_flag "$(flags_of install)" --skip-ansible; then
    ok "a retired flag (an arm with an empty body) is not offered: wb install --skip-ansible"
else
    fail "wb install offers the retired --skip-ansible"
fi
if ! printf '%s\n' "${all_flags}" | grep -qxE -- '--help|-h|-y|--\*|-\*'; then
    ok "--help, short flags and catch-all patterns are never offered"
else
    fail "an unwanted flag was offered: $(printf '%s\n' "${all_flags}" | grep -xE -- '--help|-h|-y|--\*|-\*' | tr '\n' ' ')"
fi

# ── 3. Drift: a flag added to a command shows up with no other change ───────
ROOT2="${WORK}/root2"
mkdir -p "${ROOT2}/bin" "${ROOT2}/lib"
cp "${WB}" "${ROOT2}/bin/wb"
cp -R "${REPO_ROOT}/lib/modules" "${ROOT2}/lib/modules"
add_fixture_flag_arms() {
    # Adds one real arm and one empty-body arm after remove's --restore arm.
    awk '
        { print }
        /^[[:space:]]*--restore\) restore="true" ;;/ {
            print "        --zzz-new) zzz_new=\"true\" ;;"
            print "        --zzz-noop) ;;"
        }
    ' "${ROOT2}/lib/modules/remove.sh" > "${ROOT2}/remove.new" && mv "${ROOT2}/remove.new" "${ROOT2}/lib/modules/remove.sh"
}
add_fixture_flag_arms
drifted="$(WB_ROOT="${ROOT2}" _wb_completion_command_flags remove | paste -sd' ' -)"
if has_flag "${drifted}" --zzz-new && ! has_flag "${drifted}" --zzz-noop; then
    ok "a flag added to a command is offered with no list to update; an empty-body arm is not"
else
    fail "drift check: got '${drifted}'"
fi

# ── 4. The generated bash script, driven the way readline drives it ─────────
bash "${WB}" completion bash > "${WORK}/wb-completion.bash" 2>"${WORK}/gen.err"
if bash -n "${WORK}/wb-completion.bash"; then
    ok "'wb completion bash' output passes 'bash -n' with the flag block in it"
else
    fail "generated bash completion failed 'bash -n'"
fi

# complete_bash <cword> <words...> — runs _wb_completions, prints COMPREPLY
complete_bash() {
    local cword="$1"
    shift
    bash --norc --noprofile -c '
        source "$1"; shift
        cword="$1"; shift
        COMP_WORDS=("$@"); COMP_CWORD="${cword}"
        _wb_completions
        printf "%s\n" "${COMPREPLY[@]}"
    ' _ "${WORK}/wb-completion.bash" "${cword}" "$@" 2>/dev/null
}
expect_reply() {
    local label="$1" want="$2" got="$3"
    if printf '%s\n' "${got}" | grep -qxF -- "${want}"; then
        ok "${label}: offers ${want}"
    else
        fail "${label}: expected ${want}, got '$(printf '%s' "${got}" | paste -sd' ' -)'"
    fi
}
expect_reply "wb add --pri<TAB>"             "--private"  "$(complete_bash 2 wb add --pri)"
expect_reply "wb track --<TAB>"              "--branch"   "$(complete_bash 2 wb track --)"
expect_reply "wb remove --<TAB>"             "--restore"  "$(complete_bash 2 wb remove --)"
expect_reply "wb tools list --<TAB>"         "--status"   "$(complete_bash 3 wb tools list --)"
expect_reply "wb files use <mod> --f<TAB>"   "--follow"   "$(complete_bash 4 wb files use some-mod --f)"
expect_reply "wb module reset <mod> --y<TAB>" "--yes"     "$(complete_bash 4 wb module reset some-mod --y)"
if [[ -z "$(complete_bash 2 wb install --skip)" ]]; then
    ok "wb install --skip<TAB>: offers nothing (the only match is a retired flag)"
else
    fail "wb install --skip<TAB> offered: $(complete_bash 2 wb install --skip)"
fi
# A word that doesn't start with a dash still completes as before.
expect_reply "wb <TAB> is unchanged" "status" "$(complete_bash 1 wb "")"

# ── 5. Reset targets, read per module from its own manifest ─────────────────
SRC_D="${WORK}/src-d"
BARE_D="${WORK}/d.git"
mkdir -p "${SRC_D}"
git init -q --bare "${BARE_D}"
git clone -q "${BARE_D}" "${SRC_D}" 2>/dev/null
(
    cd "${SRC_D}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p files
    echo a > files/a.conf
    echo b > files/b.conf
    cat > .dotfiles-sync.yml <<'MANIFEST'
version: 1
branch: main
core_api: ">=1.0 <2.0"
deploy:
  - src: files/a.conf
    dest: ~/.config/compd/a.conf
  - src: files/b.conf
    dest: ~/.config/compd/b.conf
MANIFEST
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)
workbench_cmd_add comp-mod-d "${BARE_D}" --private >"${WORK}/add-d.log" 2>&1

TARGETS="$(_wb_cmd_complete reset-targets comp-mod-d 2>"${WORK}/targets.err")"
# shellcheck disable=SC2088  # dests are the literal ~/-form text, expanded only when used
if printf '%s\n' "${TARGETS}" | grep -qxF '~/.config/compd/a.conf' && printf '%s\n' "${TARGETS}" | grep -qxF '~/.config/compd/b.conf'; then
    ok "reset-targets lists each deploy entry's dest for a registered module"
else
    fail "reset-targets for comp-mod-d: '${TARGETS}' (add log: $(tr '\n' ' ' < "${WORK}/add-d.log" | cut -c1-200))"
fi
if [[ ! -s "${WORK}/targets.err" ]]; then
    ok "reset-targets writes nothing to stderr"
else
    fail "reset-targets wrote to stderr: $(cat "${WORK}/targets.err")"
fi

# compgen -W expands a leading ~ in every word, so the shell offers the
# absolute path; the target resolver accepts a dest in either form.
expect_reply "wb module reset <mod> <TAB>" "${HOME}/.config/compd/a.conf" "$(complete_bash 4 wb module reset comp-mod-d "")"
expect_reply "wb module reset <mod> <TAB>" "all"                          "$(complete_bash 4 wb module reset comp-mod-d "")"
expect_reply "wb files use <mod> <TAB>"    "${HOME}/.config/compd/b.conf" "$(complete_bash 4 wb files use comp-mod-d "")"

# Nothing is offered for a name that would fail: unknown, malformed, empty.
for bad in no-such-module "../x" ""; do
    out="$(_wb_cmd_complete reset-targets "${bad}" 2>&1)"; rc=$?
    if [[ -z "${out}" && "${rc}" -eq 0 ]]; then
        ok "reset-targets '${bad}': nothing offered, exit 0, no stderr"
    else
        fail "reset-targets '${bad}': out='${out}' rc=${rc}"
    fi
done

workbench_cmd_remove comp-mod-d >"${WORK}/remove-d.log" 2>&1
if [[ -z "$(_wb_cmd_complete reset-targets comp-mod-d 2>&1)" ]]; then
    ok "reset-targets: a deregistered module offers nothing"
else
    fail "reset-targets still offers targets for a deregistered module"
fi

# ── 6. The zsh branch, when zsh is installed ────────────────────────────────
# Not an interactive completion run (that needs compinit and a terminal):
# the generated function is sourced with compadd and _describe stubbed to
# print what they are handed, so the logic that picks flags and targets runs
# for real. zsh's own matching of the typed prefix is not exercised.
if command -v zsh &>/dev/null; then
    bash "${WB}" completion zsh > "${WORK}/wb-completion.zsh" 2>/dev/null
    if zsh -n "${WORK}/wb-completion.zsh" 2>"${WORK}/zsh-syntax.log"; then
        ok "'wb completion zsh' output passes 'zsh -n' with the flag block in it"
    else
        fail "generated zsh completion failed 'zsh -n': $(cat "${WORK}/zsh-syntax.log")"
    fi

    # complete_zsh <CURRENT> <words...> — CURRENT is 1-based, words[1] is "wb"
    complete_zsh() {
        local current="$1"
        shift
        zsh -f -c '
            source "$1"; shift
            CURRENT="$1"; shift
            words=("$@")
            compadd() { shift; print -l -- "$@"; }
            _describe() { print -l -- "${(@P)2}"; }
            _wb_completions
        ' _ "${WORK}/wb-completion.zsh" "${current}" "$@" 2>/dev/null
    }
    expect_reply "zsh: wb add --pri<TAB>"               "--private" "$(complete_zsh 3 wb add --pri)"
    expect_reply "zsh: wb files use <mod> --f<TAB>"      "--follow"  "$(complete_zsh 5 wb files use some-mod --f)"
    expect_reply "zsh: wb module reset <mod> --y<TAB>"   "--yes"     "$(complete_zsh 5 wb module reset some-mod --y)"
    # The module was deregistered in section 5; register it again for zsh.
    workbench_cmd_add comp-mod-d "${BARE_D}" --private >"${WORK}/add-d2.log" 2>&1
    expect_reply "zsh: wb module reset <mod> <TAB>"      "all"       "$(complete_zsh 5 wb module reset comp-mod-d "")"
    # shellcheck disable=SC2088  # dests are the literal ~/-form text; zsh offers it unexpanded
    expect_reply "zsh: wb files use <mod> <TAB>"         "~/.config/compd/a.conf" "$(complete_zsh 5 wb files use comp-mod-d "")"
else
    ok "zsh not on PATH — skipping the zsh checks"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
