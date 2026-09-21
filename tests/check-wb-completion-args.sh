#!/usr/bin/env bash
# tests/check-wb-completion-args.sh — Phase 2 'wb completion' acceptance
# check (docs/decisions-log.md D54): sub-command completion for each
# command group, and argument-level completion against what's actually
# registered/cataloged/discovered on this host via the hidden
# 'wb __complete <kind>' dispatcher. Kept as a sibling of
# tests/check-wb-completion.sh rather than folded into it — that file's
# own header scopes it to Phase 1 (top-level command names only).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WB="${REPO_ROOT}/bin/wb"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
mkdir -p "${HOME}"

# shellcheck source=bin/wb
source "${WB}" >/tmp/wb-completion-args-source.log 2>&1
# modules/add.sh and modules/remove.sh are lazy-loaded now
# (docs/decisions-log.md D65) — this test calls workbench_cmd_add/
# workbench_cmd_remove directly, bypassing bin/wb's own dispatch (which
# requires them itself), so require them explicitly here.
_wb_require modules/add.sh modules/remove.sh

# ── 1-4. _wb_completion_subdispatch_commands against the four real
#    sub-dispatchers — exact word lists, in source order. Check #4 (sync)
#    is the one genuinely new regex behaviour: its 'enable|disable)' arm
#    is pipe-combined, unlike the other three's one-word-per-arm style. ──
check_subdispatch() {
    local fn="$1" expected="$2" actual
    actual="$(_wb_completion_subdispatch_commands "${fn}" | paste -sd' ' -)"
    if [[ "${actual}" == "${expected}" ]]; then
        ok "_wb_completion_subdispatch_commands ${fn} == '${expected}'"
    else
        fail "_wb_completion_subdispatch_commands ${fn}: expected '${expected}', got '${actual}'"
    fi
}
check_subdispatch _wb_cmd_tools "list install upgrade"
check_subdispatch _wb_cmd_module "info docs reset"
check_subdispatch _wb_cmd_scheduler "enable disable status"
check_subdispatch _wb_cmd_sync "enable disable run-if-due"

# ── 5. _wb_cmd_complete registered-modules reflects only currently-
#    registered fixture modules — add two, deregister one, confirm the
#    removed one is absent. ────────────────────────────────────────────
SRC_A="${WORK}/src-a"
BARE_A="${WORK}/a.git"
mkdir -p "${SRC_A}"
git init -q --bare "${BARE_A}"
git clone -q "${BARE_A}" "${SRC_A}" 2>/dev/null
(
    cd "${SRC_A}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    cat > .dotfiles-sync.yml <<'MANIFEST'
version: 1
branch: main
core_api: ">=1.0 <2.0"
MANIFEST
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)

SRC_B="${WORK}/src-b"
BARE_B="${WORK}/b.git"
mkdir -p "${SRC_B}"
git init -q --bare "${BARE_B}"
git clone -q "${BARE_B}" "${SRC_B}" 2>/dev/null
(
    cd "${SRC_B}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    cat > shell/installers.sh <<'EOF'
install-widget() { :; }
EOF
    cat > .dotfiles-sync.yml <<'MANIFEST'
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  installers:
    - src: shell/installers.sh
MANIFEST
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)

workbench_cmd_add comp-mod-a "${BARE_A}" --private >/tmp/wb-completion-args-add-a.log 2>&1
workbench_cmd_add comp-mod-b "${BARE_B}" --private >/tmp/wb-completion-args-add-b.log 2>&1

REG_BEFORE="$(_wb_cmd_complete registered-modules | sort)"
if echo "${REG_BEFORE}" | grep -qx "comp-mod-a" && echo "${REG_BEFORE}" | grep -qx "comp-mod-b"; then
    ok "'_wb_cmd_complete registered-modules' lists both registered fixture modules"
else
    fail "'_wb_cmd_complete registered-modules' did not list both fixture modules: ${REG_BEFORE}"
fi

workbench_cmd_remove comp-mod-a >/tmp/wb-completion-args-remove-a.log 2>&1

REG_AFTER="$(_wb_cmd_complete registered-modules | sort)"
if ! echo "${REG_AFTER}" | grep -qx "comp-mod-a" && echo "${REG_AFTER}" | grep -qx "comp-mod-b"; then
    ok "'_wb_cmd_complete registered-modules' drops a deregistered module and keeps the rest"
else
    fail "'_wb_cmd_complete registered-modules' still offers a deregistered module: ${REG_AFTER}"
    cat /tmp/wb-completion-args-remove-a.log
fi

# ── 6. _wb_cmd_complete catalog-modules/catalog-bundles reflect a host
#    override, not the shipped defaults. ───────────────────────────────
mkdir -p "${XDG_CONFIG_HOME}/workbench/catalog"
cat > "${XDG_CONFIG_HOME}/workbench/catalog/modules.list" <<'EOF'
# comment line, must be skipped
override-mod-one|https://example.invalid/one.git|false
override-mod-two|https://example.invalid/two.git|true
EOF
cat > "${XDG_CONFIG_HOME}/workbench/catalog/bundles.list" <<'EOF'
override-bundle-one|override-mod-one,override-mod-two
EOF

CATALOG_MODS="$(_wb_cmd_complete catalog-modules | sort)"
if [[ "${CATALOG_MODS}" == "$(printf 'override-mod-one\noverride-mod-two')" ]]; then
    ok "'_wb_cmd_complete catalog-modules' reflects the host override modules.list, not the shipped default"
else
    fail "'_wb_cmd_complete catalog-modules' did not reflect the override: ${CATALOG_MODS}"
fi

CATALOG_BUNDLES="$(_wb_cmd_complete catalog-bundles)"
if [[ "${CATALOG_BUNDLES}" == "override-bundle-one" ]]; then
    ok "'_wb_cmd_complete catalog-bundles' reflects the host override bundles.list, not the shipped default"
else
    fail "'_wb_cmd_complete catalog-bundles' did not reflect the override: ${CATALOG_BUNDLES}"
fi

# ── 7. _wb_cmd_complete tools reflects discovered installer friendly
#    names, and never includes a reserved word even if a fixture tries
#    to declare one. ────────────────────────────────────────────────────
TOOLS_OUT="$(_wb_cmd_complete tools 2>/dev/null | sort)"
if echo "${TOOLS_OUT}" | grep -qx "widget"; then
    ok "'_wb_cmd_complete tools' reflects a discovered installer friendly name from a fixture module"
else
    fail "'_wb_cmd_complete tools' did not reflect the fixture's discovered tool: ${TOOLS_OUT}"
fi

SRC_C="${WORK}/src-c"
BARE_C="${WORK}/c.git"
mkdir -p "${SRC_C}"
git init -q --bare "${BARE_C}"
git clone -q "${BARE_C}" "${SRC_C}" 2>/dev/null
(
    cd "${SRC_C}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    cat > shell/installers.sh <<'EOF'
install-all() { :; }
install-status() { :; }
install-widget() { :; }
EOF
    cat > .dotfiles-sync.yml <<'MANIFEST'
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  installers:
    - src: shell/installers.sh
MANIFEST
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)
workbench_cmd_add comp-mod-c "${BARE_C}" --private >/tmp/wb-completion-args-add-c.log 2>&1

TOOLS_OUT2="$(_wb_cmd_complete tools 2>/dev/null | sort -u)"
if ! printf '%s\n' "${TOOLS_OUT2}" | grep -qxE 'all|list|install|upgrade|status'; then
    ok "'_wb_cmd_complete tools' never includes a reserved word, even from a fixture that declares one"
else
    fail "'_wb_cmd_complete tools' leaked a reserved word: ${TOOLS_OUT2}"
fi

# ── 8. An unrecognised kind prints nothing, exits non-zero, and writes
#    nothing to stderr. ─────────────────────────────────────────────────
NONSENSE_OUT="$(_wb_cmd_complete nonsense-kind 2>/tmp/wb-completion-args-nonsense.stderr)"; rc=$?
NONSENSE_ERR="$(cat /tmp/wb-completion-args-nonsense.stderr)"
if [[ -z "${NONSENSE_OUT}" && "${rc}" -ne 0 && -z "${NONSENSE_ERR}" ]]; then
    ok "'_wb_cmd_complete nonsense-kind' prints nothing, exits non-zero, and writes nothing to stderr"
else
    fail "'_wb_cmd_complete nonsense-kind' misbehaved: out='${NONSENSE_OUT}' rc=${rc} err='${NONSENSE_ERR}'"
fi

# ── 9. 'wb completion bash' output still passes 'bash -n' after Phase 2's
#    larger output. ──────────────────────────────────────────────────────
BASH_OUT="$(bash "${WB}" completion bash 2>&1)"
if echo "${BASH_OUT}" | bash -n /dev/stdin 2>/tmp/wb-completion-args-syntax.log; then
    ok "'wb completion bash' Phase 2 output passes 'bash -n'"
else
    fail "'wb completion bash' Phase 2 output failed syntax check"
    cat /tmp/wb-completion-args-syntax.log
fi

# ── 10. '__complete' never appears as a top-level completable word — the
#    hidden dispatcher is excluded, not just assumed to be. Scoped to the
#    first (top-level) 'compgen -W' only. ──────────────────────────────
TOP_LEVEL_WORDS="$(echo "${BASH_OUT}" | grep -oE 'compgen -W "[^"]*"' | head -n 1)"
if ! echo "${TOP_LEVEL_WORDS}" | grep -qw "__complete"; then
    ok "'__complete' is excluded from the top-level completion word list"
else
    fail "'__complete' leaked into the top-level completion word list: ${TOP_LEVEL_WORDS}"
fi

# ── 11. 'wb help completion', 'wb completion --help', 'wb completion -h'
#    still agree with each other. ──────────────────────────────────────
via_help="$(bash "${WB}" help completion 2>&1)"
via_flag_long="$(bash "${WB}" completion --help 2>&1)"
via_flag_short="$(bash "${WB}" completion -h 2>&1)"
if [[ "${via_help}" == "${via_flag_long}" && "${via_help}" == "${via_flag_short}" ]]; then
    ok "'wb help completion', 'wb completion --help', and 'wb completion -h' all agree"
else
    fail "'wb help completion'/'wb completion --help'/'wb completion -h' disagree"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
