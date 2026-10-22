#!/usr/bin/env bash
# tests/check-function-availability-gating.sh — regression guard for the
# "_<name>-available" predicate convention (docs/module-authoring.md
# "Declaring function availability") and for how listings present the
# names it gates (docs/decisions-log.md D86).
#
# A function whose predicate reports unavailable is left out of the main
# list and shown in an "available once tooling is installed" block,
# grouped by what it needs, with an install command only when `wb tools`
# has an installer of that name. --all/WORKBENCH_FUNCTIONS_SHOW_ALL
# bypasses gating. Availability is recomputed on every call.
#
# The pre-D86 version of this suite asserted one summary line ("N more
# hidden (missing: ...)"). Its intent is kept: [8] there (a reason shared
# by two functions is reported once, even when it is not the first
# reason) is check [4] here (one header per needs text); "the reason is
# reported only when it can be recovered mechanically" is now [6] and [7]
# (a predicate with no declared reason is shown under "module gave no
# reason", not dropped and not guessed at).
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
mkdir -p "${HOME}"
# A fixed width, so `column` wraps the same way everywhere.
export COLUMNS=200

WB="${REPO_ROOT}/bin/wb"
MODULES_DIR="${XDG_DATA_HOME}/workbench/modules"
INJECTION_SENTINEL="${WORK}/injected"

# make_module <name> <manifest-register-yaml> — creates a git-backed module
# from the files already written under ${WORK}/stage-<name>, adds it to wb.
make_module() {
    local name="$1" register_yaml="$2" src bare
    src="${WORK}/src-${name}"
    bare="${WORK}/${name}.git"
    git init -q --bare "${bare}"
    git clone -q "${bare}" "${src}" 2>/dev/null
    cp -R "${WORK}/stage-${name}/." "${src}/"
    (
        cd "${src}" || exit 1
        git config user.email t@t.com
        git config user.name Test
        cat > .dotfiles-sync.yml <<EOF
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
${register_yaml}
EOF
        git add -A && git commit -q -m v1
        git branch -M main
        git push -q origin main
        git tag v1.0.0 && git push -q origin v1.0.0
    ) >/dev/null 2>&1
    bash "${WB}" add "${name}" "${bare}" --private >"${WORK}/add-${name}.log" 2>&1
}

# ── Fixture 1: sprocket — every way a name can be gated. ──────────────────
mkdir -p "${WORK}/stage-sprocket-module/shell"
cat > "${WORK}/stage-sprocket-module/shell/sprocket.sh" <<SH
get-sprocket-functions() {
    _get_functions_in "Sprocket functions" "" "\${BASH_SOURCE[0]}"
    _get_aliases_in "Sprocket aliases" "" "\${BASH_SOURCE[0]}"
}

_always_false() { return 1; }

sprocket-plain-thing() { :; }
sprocket-gated-on() { :; }
_wb_declare_availability bash sprocket-gated-on

# Two names sharing one needs text (command -v), a third elsewhere (gadget).
sprocket-a-declared-one() { :; }
sprocket-a-declared-two() { :; }
_wb_declare_availability tool-absent-aaa sprocket-a-declared-one sprocket-a-declared-two

# Variant check with --needs/--install; the installer IS registered
# (fixture 2), so this group gets an install hint.
sprocket-b-registered-one() { :; }
sprocket-b-registered-two() { :; }
_wb_alias_availability --needs "widget v2 (acme/widget)" --install mytool-xyz \\
    _always_false sprocket-b-registered-one sprocket-b-registered-two

# Same shape, but nothing registers an installer of that name.
sprocket-b-unregistered() { :; }
_wb_alias_availability --needs "gizmo v9" --install nosuchinstaller-xyz \\
    _always_false sprocket-b-unregistered

# The old, flagless form of _wb_alias_availability.
sprocket-c-old-form() { :; }
_wb_alias_availability _always_false sprocket-c-old-form

# Hand-written predicate + declared reason.
sprocket-d-hand-declared() { :; }
_sprocket-d-hand-declared-available() { return 1; }
_wb_availability_needs "a hand-declared reason" sprocket-d-hand-declared

# Hand-written predicate, no reason declared.
sprocket-e-hand-silent() { :; }
_sprocket-e-hand-silent-available() { return 1; }

# Predicate that hangs past WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS.
sprocket-f-slow() { :; }
_sprocket-f-slow-available() { sleep 5; }

# A needs text that must never be evaluated.
sprocket-g-hostile() { :; }
_wb_alias_availability --needs 'x"; touch ${INJECTION_SENTINEL}; echo "\$(touch ${INJECTION_SENTINEL})' \\
    _always_false sprocket-g-hostile

alias sprocket-alias-ok='true'
alias sprocket-alias-gated='true'
_wb_declare_availability tool-absent-aaa sprocket-alias-gated
SH
make_module sprocket-module "  shell:
    - src: shell/sprocket.sh
      tier: tools
  getters:
    - name: sprocket
      function: get-sprocket-functions
      label: \"Sprocket helpers\""

# ── Fixture 2: toolbox — registers the installer sprocket points at. ──────
mkdir -p "${WORK}/stage-toolbox-module/shell"
cat > "${WORK}/stage-toolbox-module/shell/installers.sh" <<'SH'
install-mytool-xyz() { :; }
SH
make_module toolbox-module "  installers:
    - src: shell/installers.sh"

# ── Fixture 3: gadget — a second module sharing sprocket's needs text, so
#    the top-level listing can be seen grouping across modules. ───────────
mkdir -p "${WORK}/stage-gadget-module/shell"
cat > "${WORK}/stage-gadget-module/shell/gadget.sh" <<'SH'
gadget-thing() { :; }
_wb_declare_availability tool-absent-aaa gadget-thing
SH
make_module gadget-module "  shell:
    - src: shell/gadget.sh
      tier: tools"

# run_getter <extra-env...> — runs sprocket's getter in a fresh bash that has
# loaded only what an interactive shell has (functions.sh, state.sh), the
# same way a module getter runs outside `wb functions`.
run_getter() {
    # shellcheck disable=SC2016  # $1/$2 are bash -c's own positional args
    env "$@" WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS=1 bash -c '
        source "$1/lib/core/functions.sh"
        source "$1/lib/sync/state.sh"
        source "$2/sprocket-module/current/shell/sprocket.sh"
        get-sprocket-functions
    ' _ "${REPO_ROOT}" "${MODULES_DIR}" 2>&1
}

getter_out="$(run_getter FOO=bar)"

# Lines of the getter output from one header up to the next blank line.
section() { awk -v header="$1" 'index($0, header) == 1 { on = 1; next } on && /^$/ { exit } on { print }' <<< "${getter_out}"; }
line_of() { grep -n -F -- "$1" <<< "${getter_out}" | head -n 1 | cut -d: -f1; }

main_fns="$(section "[INFO] Sprocket functions:")"
block_fns="$(section "[INFO] Sprocket functions — available once tooling is installed:")"
main_aliases="$(section "[INFO] Sprocket aliases:")"
block_aliases="$(section "[INFO] Sprocket aliases — available once tooling is installed:")"

# ── 1. Available names list normally; hidden names are in the block only. ──
if grep -q "sprocket-plain-thing" <<< "${main_fns}" && grep -q "sprocket-gated-on" <<< "${main_fns}" \
    && ! grep -q "sprocket-a-declared-one" <<< "${main_fns}" && grep -q "sprocket-a-declared-one" <<< "${block_fns}"; then
    ok "available names are in the main list; a gated name is in the block, not the main list"
else
    fail "main list / block split is wrong"
    echo "${getter_out}"
fi

# Reading order: usable functions, what's missing, then aliases.
l_main="$(line_of "[INFO] Sprocket functions:")"
l_block="$(line_of "[INFO] Sprocket functions — available once tooling is installed:")"
l_alias="$(line_of "[INFO] Sprocket aliases:")"
l_alias_block="$(line_of "[INFO] Sprocket aliases — available once tooling is installed:")"
if [[ -n "${l_main}" && -n "${l_block}" && -n "${l_alias}" && -n "${l_alias_block}" ]] \
    && [[ "${l_main}" -lt "${l_block}" && "${l_block}" -lt "${l_alias}" && "${l_alias}" -lt "${l_alias_block}" ]]; then
    ok "reading order is functions, missing functions, aliases, missing aliases"
else
    fail "sections are out of order (lines: ${l_main}/${l_block}/${l_alias}/${l_alias_block})"
    echo "${getter_out}"
fi

if grep -q "sprocket-alias-ok" <<< "${main_aliases}" && ! grep -q "sprocket-alias-gated" <<< "${main_aliases}" \
    && grep -q "sprocket-alias-gated" <<< "${block_aliases}"; then
    ok "aliases get the same available / needs split under their own block"
else
    fail "alias block is wrong"
    echo "${getter_out}"
fi

if ! grep -qE '^  _?sprocket-.*-available' <<< "${getter_out}" && ! grep -q "_always_false" <<< "${getter_out}"; then
    ok "predicate and helper functions themselves are never listed"
else
    fail "a predicate or helper function was listed"
fi

# ── 2. One header per needs text; shared text appears once, in order. ──────
a_headers="$(grep -c '^  tool-absent-aaa' <<< "${block_fns}")"
distinct_headers="$(grep -c '^  [^ ]' <<< "${block_fns}")"
if [[ "${a_headers}" -eq 1 ]] \
    && grep -A1 '^  tool-absent-aaa' <<< "${block_fns}" | grep -q 'sprocket-a-declared-one.*sprocket-a-declared-two'; then
    ok "two names sharing a needs text sit under one header, once"
else
    fail "shared needs text was not grouped under a single header (${a_headers} headers)"
    echo "${block_fns}"
fi
if [[ "${distinct_headers}" -ge 5 ]]; then
    ok "different needs texts get separate headers (${distinct_headers} groups)"
else
    fail "expected at least 5 distinct groups, got ${distinct_headers}"
    echo "${block_fns}"
fi

# Names are indented four spaces under a header indented two.
if grep -qE '^    sprocket-a-declared-one' <<< "${block_fns}"; then
    ok "names are indented four spaces beneath their header"
else
    fail "names are not indented four spaces"
    echo "${block_fns}"
fi

# ── 3. _wb_declare_availability shows <cmd> as the needs text. ─────────────
if grep -q '^  tool-absent-aaa$' <<< "${block_fns}"; then
    ok "_wb_declare_availability <cmd> shows <cmd> as the needs text (no hint: no installer of that name)"
else
    fail "needs text for _wb_declare_availability is not the command (or grew an install hint)"
    echo "${block_fns}"
fi

# ── 4. --needs/--install shows the needs text; the old flagless form still
#    works and lands under "module gave no reason". ────────────────────────
if grep -q 'widget v2 (acme/widget)' <<< "${block_fns}"; then
    ok "_wb_alias_availability --needs shows the declared needs text"
else
    fail "--needs text missing from the block"
    echo "${block_fns}"
fi
if grep -A1 '^  module gave no reason (predicate reports unavailable)' <<< "${block_fns}" | grep -q 'sprocket-c-old-form'; then
    ok "old flagless _wb_alias_availability still hides the name, listed under 'module gave no reason'"
else
    fail "flagless _wb_alias_availability name is not under 'module gave no reason'"
    echo "${block_fns}"
fi

# ── 5. Hand-written predicate + _wb_availability_needs shows the reason. ───
if grep -A1 '^  a hand-declared reason' <<< "${block_fns}" | grep -q 'sprocket-d-hand-declared'; then
    ok "hand-written predicate with _wb_availability_needs shows the declared reason"
else
    fail "declared reason for a hand-written predicate is missing"
    echo "${block_fns}"
fi

# ── 6. Hand-written predicate with no reason is shown, not dropped. ────────
if grep -A1 '^  module gave no reason (predicate reports unavailable)' <<< "${block_fns}" | grep -q 'sprocket-e-hand-silent'; then
    ok "hand-written predicate with no declared reason appears under 'module gave no reason'"
else
    fail "reasonless hand-written predicate is missing from the block"
    echo "${block_fns}"
fi

# ── 7. Install hint only when an installer of that name is registered. ────
if grep -qF '  widget v2 (acme/widget) — install: wb tools install mytool-xyz' <<< "${block_fns}"; then
    ok "install hint is printed when an installer of that friendly name is registered"
else
    fail "install hint missing for a registered installer"
    echo "${block_fns}"
fi
if grep -q '^  gizmo v9$' <<< "${block_fns}" && ! grep -q 'nosuchinstaller-xyz' <<< "${getter_out}"; then
    ok "no install hint (and no install command) when no installer of that name exists"
else
    fail "an install hint was printed for an unregistered installer"
    echo "${block_fns}"
fi

# Sync paused on the module that owns the installer: `wb tools` no longer
# discovers it, so the hint must go too.
bash "${WB}" sync disable toolbox-module >/dev/null 2>&1
paused_out="$(run_getter FOO=bar)"
if ! grep -q 'wb tools install mytool-xyz' <<< "${paused_out}" && grep -q 'widget v2 (acme/widget)' <<< "${paused_out}"; then
    ok "install hint disappears once the installer's module is sync-disabled; the needs text stays"
else
    fail "install hint survived the owning module being sync-disabled"
    grep -A3 'widget v2' <<< "${paused_out}"
fi
bash "${WB}" sync enable toolbox-module >/dev/null 2>&1

# ── 8. A predicate killed by the timeout is grouped under the timeout line,
#    and `wb functions` still prints its warning. ───────────────────────────
if grep -A1 '^  availability check timed out (> 1s)' <<< "${block_fns}" | grep -q 'sprocket-f-slow'; then
    ok "a predicate killed by the timeout appears under 'availability check timed out (> 1s)'"
else
    fail "timed-out predicate is not under the timeout group"
    echo "${block_fns}"
fi

# ── 9. SHOW_ALL lists everything in the main list, with no block. ──────────
all_out="$(run_getter WORKBENCH_FUNCTIONS_SHOW_ALL=true)"
if grep -q "sprocket-a-declared-one" <<< "${all_out}" && grep -q "sprocket-f-slow" <<< "${all_out}" \
    && ! grep -q "available once tooling is installed" <<< "${all_out}"; then
    ok "WORKBENCH_FUNCTIONS_SHOW_ALL=true lists every name and prints no block"
else
    fail "SHOW_ALL did not bypass gating cleanly"
    echo "${all_out}"
fi

# ── 10. Top level: `wb functions` is one block across modules; --compact is
#    one line and no block; a getter called directly is never compact. ─────
top_out="$(WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS=1 bash "${WB}" functions --no-pager 2>&1)"
top_header_count="$(grep -c '^\[INFO\] Loaded functions — available once tooling is installed:' <<< "${top_out}")"
top_block="$(awk -v header="[INFO] Loaded functions — available once tooling is installed:" 'index($0, header) == 1 { on = 1; next } on && /^$/ { exit } on { print }' <<< "${top_out}")"
top_a_header_count="$(grep -c '^  tool-absent-aaa$' <<< "${top_block}")"
if [[ "${top_header_count}" -eq 1 ]] && [[ "${top_a_header_count}" -eq 1 ]] \
    && grep -A1 '^  tool-absent-aaa$' <<< "${top_block}" | grep -q 'gadget-thing.*sprocket-a-declared-one'; then
    ok "'wb functions' prints one block, grouping a needs text across modules"
else
    fail "'wb functions' block is wrong (${top_header_count} blocks, ${top_a_header_count} tool-absent-aaa headers)"
    echo "${top_out}"
fi
if grep -q "predicate(s) for \[sprocket-f-slow\] exceeded 1s" <<< "${top_out}"; then
    ok "'wb functions' still prints the timeout warning"
else
    fail "'wb functions' lost its timeout warning"
    echo "${top_out}"
fi

compact_out="$(WORKBENCH_AVAILABILITY_TIMEOUT_SECONDS=1 bash "${WB}" functions --no-pager --no-aliases --compact 2>&1)"
if grep -qE "^  [0-9]+ functions need tooling you don't have: .*tool-absent-aaa \(3\).*mytool-xyz \(2\).* — run 'wb functions' for details$" <<< "${compact_out}" \
    && ! grep -q "available once tooling is installed" <<< "${compact_out}"; then
    ok "'wb functions --compact' prints the one-line form (count per tool, biggest first) and no block"
else
    fail "compact output is wrong"
    echo "${compact_out}"
fi
if grep -q 'sprocket-plain-thing' <<< "${compact_out}"; then
    ok "'wb functions --compact' still lists the available functions"
else
    fail "compact output lost the available functions"
fi
if grep -q "available once tooling is installed" <<< "${getter_out}" && ! grep -q "need tooling you don't have" <<< "${getter_out}"; then
    ok "a getter called directly is never compact"
else
    fail "a getter printed compact output"
fi

# ── 11. Fix and re-run, in one shell: install the tool, ask again. ─────────
STUB_DIR="${WORK}/stubbin"
mkdir -p "${STUB_DIR}"
rerun_out="$(
    HOME="${HOME}" XDG_DATA_HOME="${XDG_DATA_HOME}" STUB_DIR="${STUB_DIR}" bash -c '
        source "$1/lib/core/functions.sh"
        source "$1/lib/sync/state.sh"
        rerun-widget() { :; }
        _wb_declare_availability tool-late-xyz rerun-widget
        src="$(mktemp)"
        printf "%s\n" "rerun-widget() { :; }" > "${src}"
        echo "--- before"
        _get_functions_in "Rerun functions" "" "${src}"
        printf "#!/bin/sh\nexit 0\n" > "${STUB_DIR}/tool-late-xyz"
        chmod +x "${STUB_DIR}/tool-late-xyz"
        PATH="${STUB_DIR}:${PATH}"
        echo "--- after"
        _get_functions_in "Rerun functions" "" "${src}"
        rm -f "${src}"
    ' _ "${REPO_ROOT}" 2>&1
)"
before_part="${rerun_out%%--- after*}"
after_part="${rerun_out##*--- after}"
if grep -q "available once tooling is installed" <<< "${before_part}" && grep -q "tool-late-xyz" <<< "${before_part}" \
    && ! grep -q "available once tooling is installed" <<< "${after_part}" && grep -q "rerun-widget" <<< "${after_part}" \
    && ! grep -q "(none)" <<< "${after_part}"; then
    ok "install the tool, run the getter again in the same shell: hidden before, listed after, no block"
else
    fail "fix-and-rerun did not pick up the newly installed tool"
    echo "${rerun_out}"
fi

# If every name is available there is no block and no extra blank line; if
# none are available the list stays (none) and the block follows.
none_out="$(
    bash -c '
        source "$1/lib/core/functions.sh"
        only-gated() { :; }
        _wb_declare_availability tool-absent-aaa only-gated
        src="$(mktemp)"; printf "%s\n" "only-gated() { :; }" > "${src}"
        _get_functions_in "Only functions" "" "${src}"
        rm -f "${src}"
    ' _ "${REPO_ROOT}" 2>&1
)"
if grep -A1 '^\[INFO\] Only functions:$' <<< "${none_out}" | grep -q '(none)' \
    && grep -q '^\[INFO\] Only functions — available once tooling is installed:$' <<< "${none_out}"; then
    ok "with nothing available the list reads (none) and the block follows"
else
    fail "all-hidden listing is wrong"
    echo "${none_out}"
fi

clean_out="$(
    bash -c '
        source "$1/lib/core/functions.sh"
        src="$(mktemp)"; printf "%s\n" "free-thing() { :; }" > "${src}"
        _get_functions_in "Clean functions" "" "${src}"
        rm -f "${src}"
    ' _ "${REPO_ROOT}" 2>&1
)"
if [[ "${clean_out}" == $'\n[INFO] Clean functions:\nfree-thing\n' || "${clean_out}" == $'\n[INFO] Clean functions:\nfree-thing' ]]; then
    ok "with every name available there is no block and no extra blank line"
else
    fail "an all-available listing grew extra output"
    printf '%s\n' "${clean_out}" | cat -A
fi

# ── 12. A hostile needs text is data, never code. ──────────────────────────
if [[ ! -e "${INJECTION_SENTINEL}" ]]; then
    ok "a needs text containing quotes and \$(...) is never evaluated"
else
    fail "a needs text was evaluated as code"
fi

# ── 13. Flag errors. ───────────────────────────────────────────────────────
flag_out="$(bash -c '
    source "$1/lib/core/functions.sh"
    _wb_alias_availability --bogus true some-name
    echo "rc=$?"
    declare -F _some-name-available >/dev/null && echo "declared" || echo "not-declared"
' _ "${REPO_ROOT}" 2>&1)"
if grep -q "unknown option '--bogus'" <<< "${flag_out}" && grep -q 'rc=2' <<< "${flag_out}" && grep -q 'not-declared' <<< "${flag_out}"; then
    ok "_wb_alias_availability rejects an unknown --flag with status 2 and declares nothing"
else
    fail "unknown flag was not rejected as expected"
    echo "${flag_out}"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
