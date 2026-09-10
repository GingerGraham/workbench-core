#!/usr/bin/env bash
# tests/check-module-info.sh — ARCHITECTURE.md §12 D45 acceptance check.
#
# Covers: usage errors for unregistered/missing names, `info` built from
# sync.conf facts even with no `info:` block, `info.description` read
# independently of the `core_api` gate that governs `register:`, `docs`
# falling back HELP.md -> README.md -> a friendly not-published pointer,
# `wb module` usage/dispatch errors, and the `wb help module`/`wb module
# --help` equivalence.
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
source "${WB}" >/tmp/wb-module-info-source.log 2>&1

# ── 1. wb module info/docs on an unregistered name. ─────────────────────────
if _wb_cmd_module_info nonexistent >/tmp/wb-module-info-unreg.log 2>&1; then
    fail "'wb module info nonexistent' unexpectedly succeeded"
else
    ok "'wb module info' on an unregistered name is a usage-level error (non-zero exit)"
fi
if grep -q "'nonexistent' is not registered" /tmp/wb-module-info-unreg.log; then
    ok "'wb module info' on an unregistered name matches the standard 'is not registered' wording"
else
    fail "'wb module info' unregistered-name error message did not match expected wording"
    cat /tmp/wb-module-info-unreg.log
fi

if _wb_cmd_module_docs nonexistent >/tmp/wb-module-docs-unreg.log 2>&1; then
    fail "'wb module docs nonexistent' unexpectedly succeeded"
else
    ok "'wb module docs' on an unregistered name is a usage-level error (non-zero exit)"
fi

# ── Fixture: "plain-mod" — no info:, no HELP.md, no README.md. ─────────────
SRC_PLAIN="${WORK}/src-plain"
BARE_PLAIN="${WORK}/plain.git"
mkdir -p "${SRC_PLAIN}"
git init -q --bare "${BARE_PLAIN}"
git clone -q "${BARE_PLAIN}" "${SRC_PLAIN}" 2>/dev/null
(
    cd "${SRC_PLAIN}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)
workbench_cmd_add plain-mod "${BARE_PLAIN}" --private >/tmp/wb-module-info-add-plain.log 2>&1

# ── 2. info on a module with no info: block still prints core-tracked facts,
#    and shows "not published yet" for description. ─────────────────────────
INFO_PLAIN="$(_wb_cmd_module_info plain-mod 2>&1)"
if echo "${INFO_PLAIN}" | grep -q "Repository:" \
    && echo "${INFO_PLAIN}" | grep -q "Tracking:" \
    && echo "${INFO_PLAIN}" | grep -q "Registered:"; then
    ok "'wb module info' on a module with no info: block still prints repository/tracking/registration facts"
else
    fail "'wb module info' did not print expected core-tracked facts"
    echo "${INFO_PLAIN}"
fi
if echo "${INFO_PLAIN}" | grep -qi "not published yet"; then
    ok "'wb module info' shows a 'not published yet' line for description, not blank or an error"
else
    fail "'wb module info' did not show the 'not published yet' description line"
    echo "${INFO_PLAIN}"
fi

# ── Fixture: "info-mod" — info.description declared, no core_api at all. ───
SRC_INFO="${WORK}/src-info"
BARE_INFO="${WORK}/info.git"
mkdir -p "${SRC_INFO}"
git init -q --bare "${BARE_INFO}"
git clone -q "${BARE_INFO}" "${SRC_INFO}" 2>/dev/null
(
    cd "${SRC_INFO}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main

info:
  description: "AWS config helpers and credential rotation"
EOF
    cat > HELP.md <<'EOF'
# info-mod help

Full documentation for info-mod.
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)
workbench_cmd_add info-mod "${BARE_INFO}" --private >/tmp/wb-module-info-add-info.log 2>&1

# ── 3. info.description is shown even with no core_api declared at all —
#    info: is read independently of the register: core_api gate. ───────────
INFO_MOD="$(_wb_cmd_module_info info-mod 2>&1)"
if echo "${INFO_MOD}" | grep -q "AWS config helpers and credential rotation"; then
    ok "'wb module info' shows info.description even with no core_api declared (independent of the register: gate)"
else
    fail "'wb module info' did not show the published description"
    echo "${INFO_MOD}"
fi

# ── 4. docs on a module with a HELP.md prints it verbatim, naming the source.
DOCS_INFO="$(_wb_cmd_module_docs info-mod 2>&1)"
if echo "${DOCS_INFO}" | grep -q "HELP.md" \
    && echo "${DOCS_INFO}" | grep -q "Full documentation for info-mod."; then
    ok "'wb module docs' on a module with HELP.md prints it verbatim, naming HELP.md as the source"
else
    fail "'wb module docs' did not print HELP.md content as expected"
    echo "${DOCS_INFO}"
fi

# ── Fixture: "readme-mod" — no HELP.md, only README.md. ────────────────────
SRC_README="${WORK}/src-readme"
BARE_README="${WORK}/readme.git"
mkdir -p "${SRC_README}"
git init -q --bare "${BARE_README}"
git clone -q "${BARE_README}" "${SRC_README}" 2>/dev/null
(
    cd "${SRC_README}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
EOF
    cat > README.md <<'EOF'
# readme-mod

This is the readme fallback content.
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)
workbench_cmd_add readme-mod "${BARE_README}" --private >/tmp/wb-module-info-add-readme.log 2>&1

# ── 5. docs on a module with no HELP.md but a README.md falls back to it. ──
DOCS_README="$(_wb_cmd_module_docs readme-mod 2>&1)"
if echo "${DOCS_README}" | grep -q "README.md" \
    && echo "${DOCS_README}" | grep -q "This is the readme fallback content."; then
    ok "'wb module docs' falls back to README.md when no HELP.md is present"
else
    fail "'wb module docs' did not fall back to README.md as expected"
    echo "${DOCS_README}"
fi

# ── 6. docs on a module with neither file prints the friendly not-published
#    message, including REPO_URL, and exits 0. ─────────────────────────────
DOCS_PLAIN_RC=0
DOCS_PLAIN="$(_wb_cmd_module_docs plain-mod 2>&1)" || DOCS_PLAIN_RC=$?
if [[ "${DOCS_PLAIN_RC}" -eq 0 ]]; then
    ok "'wb module docs' on a module with neither HELP.md nor README.md exits 0 (not an error condition)"
else
    fail "'wb module docs' on a module with no docs exited non-zero (${DOCS_PLAIN_RC})"
fi
if echo "${DOCS_PLAIN}" | grep -qi "hasn't published additional documentation" \
    && echo "${DOCS_PLAIN}" | grep -q "${BARE_PLAIN}"; then
    ok "'wb module docs' with no docs published prints the friendly pointer including the module's REPO_URL"
else
    fail "'wb module docs' with no docs did not print the expected friendly pointer"
    echo "${DOCS_PLAIN}"
fi

# ── 7. wb module with no subcommand, and with an unrecognised subcommand,
#    both print usage and exit non-zero. ────────────────────────────────────
if _wb_cmd_module >/tmp/wb-module-bare.log 2>&1; then
    fail "'wb module' with no subcommand unexpectedly succeeded"
else
    ok "'wb module' with no subcommand exits non-zero"
fi
# shellcheck disable=SC2015
grep -qi "usage" /tmp/wb-module-bare.log && ok "'wb module' with no subcommand prints usage" \
    || fail "'wb module' with no subcommand did not print usage"

if _wb_cmd_module bogus >/tmp/wb-module-bogus.log 2>&1; then
    fail "'wb module bogus' unexpectedly succeeded"
else
    ok "'wb module' with an unrecognised subcommand exits non-zero"
fi
# shellcheck disable=SC2015
grep -qi "usage" /tmp/wb-module-bogus.log && ok "'wb module' with an unrecognised subcommand prints usage" \
    || fail "'wb module' with an unrecognised subcommand did not print usage"

# ── 8. wb module info/docs with no <name> exits 2 (usage error). ───────────
_wb_cmd_module_info >/dev/null 2>&1
rc_info=$?
# shellcheck disable=SC2015
[[ "${rc_info}" -eq 2 ]] && ok "'wb module info' with no <name> exits 2 (usage error)" \
    || fail "'wb module info' with no <name> exited ${rc_info}, expected 2"

_wb_cmd_module_docs >/dev/null 2>&1
rc_docs=$?
# shellcheck disable=SC2015
[[ "${rc_docs}" -eq 2 ]] && ok "'wb module docs' with no <name> exits 2 (usage error)" \
    || fail "'wb module docs' with no <name> exited ${rc_docs}, expected 2"

# ── 9. wb help module / wb module --help produce identical, non-empty
#    output (existing central -h/--help interception pattern). ─────────────
via_help="$(bash "${WB}" help module 2>&1)"
via_flag_long="$(bash "${WB}" module --help 2>&1)"
via_flag_short="$(bash "${WB}" module -h 2>&1)"

if [[ -n "${via_help}" ]]; then
    ok "'wb help module' produces non-empty detail"
else
    fail "'wb help module' produced no output"
fi
if [[ "${via_help}" == "${via_flag_long}" && "${via_help}" == "${via_flag_short}" ]]; then
    ok "'wb help module' and 'wb module --help'/'-h' agree"
else
    fail "'wb help module' and 'wb module --help'/'-h' differ"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
