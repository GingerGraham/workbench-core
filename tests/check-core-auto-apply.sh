#!/usr/bin/env bash
# tests/check-core-auto-apply.sh — Action 1 acceptance check (follow-up
# brief: "workbench-core follow-up: core auto-reconvergence + wb help",
# ARCHITECTURE.md §12 D20).
#
# `wb update`/`wb sync run-if-due`/`wb track` targeting `core` must trigger
# a `wb apply` convergence pass exactly when core's resolved commit actually
# changed — never on a no-op cycle, never for a non-core module, always
# without --skip-ansible when attended and always with it when triggered
# from the unattended timer path, and never as something that can fail the
# triggering command's own exit status.
#
# _wb_cmd_apply is stubbed for most of this file (recorded calls in
# APPLY_CALLS[], forced exit code in APPLY_EXIT) so the trigger logic can be
# tested in isolation from the real, heavier convergence machinery (prereq
# installs, SSH bootstrap, Ansible) already covered by
# tests/check-wb-add-convergence.sh, tests/check-ssh-bootstrap-gating.sh and
# tests/check-wb-on-path.sh. The one thing that stub can't prove — that
# --skip-ansible actually skips the Ansible block — is checked separately in
# §4 below against the real, unstubbed _wb_cmd_install.
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

# ── Source bin/wb with positional args cleared, so its own top-level
#    dispatch just prints the usage block (harmless) instead of trying to
#    run a real command — same pattern as tests/check-wb-on-path.sh's
#    run_link(). Every function bin/wb defines (including the new
#    _wb_maybe_reconverge_core) is now available directly in this shell. ───
set --
# shellcheck source=bin/wb
source "${WB}" >/tmp/wb-core-auto-apply-source.log 2>&1

# ── Stub _wb_cmd_apply: records every invocation's args, returns
#    APPLY_EXIT. Redefining it after sourcing is safe — bash functions are
#    just the last definition standing. ─────────────────────────────────────
declare -a APPLY_CALLS=()
APPLY_EXIT=0
_wb_cmd_apply() {
    APPLY_CALLS+=("$*")
    return "${APPLY_EXIT}"
}
reset_apply_calls() { APPLY_CALLS=(); APPLY_EXIT=0; }

# ── Fixture: two local bare repos (no network) — "core" and an unrelated
#    "widgetco" module, each with a manifest and an initial tag. Mirrors the
#    setup already proven out in tests/check-sync-engine-isolation.sh. ─────
make_src_repo() {
    local src="$1" bare="$2" content="$3"
    mkdir -p "${src}"
    git init -q --bare "${bare}"
    git clone -q "${bare}" "${src}"
    (
        cd "${src}" || exit 1
        git config user.email t@t.com
        git config user.name Test
        echo "${content}" > file.sh
        cat > .dotfiles-sync.yml <<EOF
version: 1
branch: main
deploy:
  - src: file.sh
    dest: ~/.local/share/wb-core-auto-apply-test/$(basename "${src}").sh
    mode: link
core_api: ">=1.0 <2.0"
EOF
        git add -A && git commit -q -m v1
        git branch -M main
        git push -q origin main
        git tag v1.0.0 && git push -q origin v1.0.0
    )
}
push_new_tag() {
    local src="$1" tag="$2" content="$3"
    (
        cd "${src}" || exit 1
        echo "${content}" >> file.sh
        git add -A && git commit -q -m "${tag}"
        git tag "${tag}" && git push -q origin main "${tag}"
    )
}

CORE_SRC="${WORK}/core-src"; CORE_BARE="${WORK}/core-bare.git"
make_src_repo "${CORE_SRC}" "${CORE_BARE}" "core v1"

WIDGET_SRC="${WORK}/widget-src"; WIDGET_BARE="${WORK}/widget-bare.git"
make_src_repo "${WIDGET_SRC}" "${WIDGET_BARE}" "widget v1"

setup_module() {
    local name="$1" bare="$2" mode="$3"
    mkdir -p "$(workbench_module_dir "${name}")"
    cat > "$(workbench_module_conf_path "${name}")" <<EOF
REPO_URL=${bare}
PRIVATE=true
TRACK_MODE=${mode}
REGISTERED=true
SYNC_ENABLED=true
ALLOW_HOOKS=false
EOF
}
setup_module core "${CORE_BARE}" latest
setup_module widgetco "${WIDGET_BARE}" latest

# Prime both modules with a real first sync so RESOLVED_SHA and `current`
# exist — without a real `current` dir, the engine's "up to date" fast path
# can never be taken (workbench_sync_module requires -d module_dir/current
# too), which would make every "no change" check below spuriously look like
# a change. This is direct engine usage, not through `wb`, so it doesn't
# touch _wb_maybe_reconverge_core at all yet.
workbench_sync_module core "setup" >/tmp/wb-core-auto-apply-setup1.log 2>&1
workbench_sync_module widgetco "setup" >/tmp/wb-core-auto-apply-setup2.log 2>&1

# ── 1. No SHA change → convergence NOT triggered, from all three call
#    sites. ──────────────────────────────────────────────────────────────────
reset_apply_calls
_wb_cmd_update core >/tmp/wb-caa-1a.log 2>&1
# shellcheck disable=SC2015
[[ "${#APPLY_CALLS[@]}" -eq 0 ]] && ok "'wb update core' with no SHA change does not trigger convergence" \
    || fail "'wb update core' with no SHA change triggered convergence anyway: ${APPLY_CALLS[*]}"

reset_apply_calls
_wb_cmd_update "" >/tmp/wb-caa-1b.log 2>&1
# shellcheck disable=SC2015
[[ "${#APPLY_CALLS[@]}" -eq 0 ]] && ok "bare 'wb update' with no SHA change does not trigger convergence" \
    || fail "bare 'wb update' with no SHA change triggered convergence anyway: ${APPLY_CALLS[*]}"

reset_apply_calls
_wb_cmd_sync run-if-due >/tmp/wb-caa-1c.log 2>&1
# shellcheck disable=SC2015
[[ "${#APPLY_CALLS[@]}" -eq 0 ]] && ok "'wb sync run-if-due' with no SHA change does not trigger convergence" \
    || fail "'wb sync run-if-due' with no SHA change triggered convergence anyway: ${APPLY_CALLS[*]}"

reset_apply_calls
core_sha="$(workbench_module_conf_get core RESOLVED_SHA "")"
workbench_cmd_track core --commit "${core_sha}" >/tmp/wb-caa-1d.log 2>&1
# shellcheck disable=SC2015
[[ "${#APPLY_CALLS[@]}" -eq 0 ]] && ok "'wb track core --commit <already-resolved-sha>' does not trigger convergence" \
    || fail "'wb track core' with an unchanged resolved SHA triggered convergence anyway: ${APPLY_CALLS[*]}"
# Restore core to latest for the remaining checks.
workbench_module_conf_set core TRACK_MODE latest

# ── 2. SHA change via 'wb update core' (and bare 'wb update') → full
#    convergence, without --skip-ansible. ───────────────────────────────────
push_new_tag "${CORE_SRC}" v1.1.0 "core v1.1"
reset_apply_calls
_wb_cmd_update core >/tmp/wb-caa-2a.log 2>&1
if [[ "${#APPLY_CALLS[@]}" -eq 1 && "${APPLY_CALLS[0]}" != *"--skip-ansible"* ]]; then
    ok "'wb update core' with a real SHA change triggers convergence exactly once, without --skip-ansible"
else
    fail "'wb update core' convergence trigger unexpected: calls=${#APPLY_CALLS[@]} args='${APPLY_CALLS[*]-}'"
fi

push_new_tag "${CORE_SRC}" v1.2.0 "core v1.2"
reset_apply_calls
_wb_cmd_update "" >/tmp/wb-caa-2b.log 2>&1
if [[ "${#APPLY_CALLS[@]}" -eq 1 && "${APPLY_CALLS[0]}" != *"--skip-ansible"* ]]; then
    ok "bare 'wb update' with core changed triggers convergence exactly once, without --skip-ansible"
else
    fail "bare 'wb update' convergence trigger unexpected: calls=${#APPLY_CALLS[@]} args='${APPLY_CALLS[*]-}'"
fi

# ── 3. SHA change via 'wb sync run-if-due' → convergence WITH
#    --skip-ansible (the unattended path). ──────────────────────────────────
push_new_tag "${CORE_SRC}" v1.3.0 "core v1.3"
reset_apply_calls
# Force the cadence timer to be "due" again — check 1c's run-if-due call
# already marked it as just-run, and the default interval is a week.
rm -f "$(_wb_cadence_state_file)"
_wb_cmd_sync run-if-due >/tmp/wb-caa-3.log 2>&1
if [[ "${#APPLY_CALLS[@]}" -eq 1 && "${APPLY_CALLS[0]}" == *"--skip-ansible"* ]]; then
    ok "'wb sync run-if-due' with core changed triggers convergence exactly once, WITH --skip-ansible"
else
    fail "'wb sync run-if-due' convergence trigger unexpected: calls=${#APPLY_CALLS[@]} args='${APPLY_CALLS[*]-}'"
fi

# ── 4. --skip-ansible actually skips Ansible, driven by the flag and not by
#    ansible-playbook's absence — tested against the real, unstubbed
#    _wb_cmd_install/_wb_cmd_apply, with a stub ansible-playbook that would
#    prove it ran (by writing a marker file) if invoked. ────────────────────
unset -f _wb_cmd_apply
_wb_cmd_apply() { _wb_cmd_install "$@"; }

FAKE_BIN="${WORK}/fakebin"
mkdir -p "${FAKE_BIN}"
ANSIBLE_MARKER="${WORK}/ansible-was-invoked"
cat > "${FAKE_BIN}/ansible-playbook" <<EOF
#!/usr/bin/env bash
touch "${ANSIBLE_MARKER}"
exit 0
EOF
chmod +x "${FAKE_BIN}/ansible-playbook"
export PATH="${FAKE_BIN}:${PATH}"

rm -f "${ANSIBLE_MARKER}"
out_skip="$(_wb_cmd_apply --skip-ansible 2>&1)"
if [[ ! -f "${ANSIBLE_MARKER}" ]]; then
    ok "'wb apply --skip-ansible' does not invoke ansible-playbook even though it's present on PATH"
else
    fail "'wb apply --skip-ansible' invoked ansible-playbook despite the flag"
fi
if echo "${out_skip}" | grep -qi -- "--skip-ansible given"; then
    ok "'wb apply --skip-ansible' logs that the skip was flag-driven, not absence-of-binary"
else
    fail "'wb apply --skip-ansible' did not log the correct reason for skipping: ${out_skip}"
fi

rm -f "${ANSIBLE_MARKER}"
out_noskip="$(_wb_cmd_apply 2>&1)"
if [[ -f "${ANSIBLE_MARKER}" ]]; then
    ok "'wb apply' (no flag) with ansible-playbook present on PATH does invoke it — proves §4's skip above was flag-driven"
else
    fail "'wb apply' without --skip-ansible unexpectedly did not invoke ansible-playbook: ${out_noskip}"
fi

export PATH="${PATH#"${FAKE_BIN}:"}"

# Re-install the recording stub for the remaining checks.
# shellcheck disable=SC2317
_wb_cmd_apply() {
    APPLY_CALLS+=("$*")
    return "${APPLY_EXIT}"
}

# ── 5. SHA change via 'wb track core --branch <b>' → full convergence,
#    attended (no --skip-ansible). ──────────────────────────────────────────
(
    cd "${CORE_SRC}" || exit 1
    git checkout -q -b my-feature
    echo "core feature wip" >> file.sh
    git add -A && git commit -q -m "feature wip"
    git push -q origin my-feature
)
reset_apply_calls
workbench_cmd_track core --branch my-feature >/tmp/wb-caa-5.log 2>&1
if [[ "${#APPLY_CALLS[@]}" -eq 1 && "${APPLY_CALLS[0]}" != *"--skip-ansible"* ]]; then
    ok "'wb track core --branch my-feature' triggers convergence exactly once, without --skip-ansible"
else
    fail "'wb track core --branch' convergence trigger unexpected: calls=${#APPLY_CALLS[@]} args='${APPLY_CALLS[*]-}'"
fi
# Restore core to latest for the remaining checks.
workbench_module_conf_set core TRACK_MODE latest
workbench_sync_module core "restore" >/tmp/wb-caa-5-restore.log 2>&1

# ── 6. A module other than core changing → no convergence triggered
#    anywhere. ────────────────────────────────────────────────────────────────
push_new_tag "${WIDGET_SRC}" v1.1.0 "widget v1.1"
reset_apply_calls
_wb_cmd_update widgetco >/tmp/wb-caa-6a.log 2>&1
# shellcheck disable=SC2015
[[ "${#APPLY_CALLS[@]}" -eq 0 ]] && ok "'wb update widgetco' (non-core) never triggers core convergence" \
    || fail "'wb update widgetco' unexpectedly triggered convergence: ${APPLY_CALLS[*]}"

push_new_tag "${WIDGET_SRC}" v1.2.0 "widget v1.2"
reset_apply_calls
_wb_cmd_update "" >/tmp/wb-caa-6b.log 2>&1
# shellcheck disable=SC2015
[[ "${#APPLY_CALLS[@]}" -eq 0 ]] && ok "bare 'wb update' with only a non-core module changing does not trigger convergence" \
    || fail "bare 'wb update' with only widgetco changing unexpectedly triggered convergence: ${APPLY_CALLS[*]}"

# ── 7. Convergence failure is non-fatal: the triggering command still
#    exits 0 and reports its own sync as successful; a warning is logged. ──
push_new_tag "${CORE_SRC}" v1.4.0 "core v1.4"
reset_apply_calls
APPLY_EXIT=1
out_fail="$(_wb_cmd_update core 2>&1)"
rc_fail=$?
if [[ "${rc_fail}" -eq 0 ]]; then
    ok "'wb update core' still exits 0 when the triggered convergence pass fails"
else
    fail "'wb update core' propagated the convergence failure as its own exit status (rc=${rc_fail})"
fi
if echo "${out_fail}" | grep -qiE "warn.*(convergence|apply)"; then
    ok "a convergence failure is logged as a warning"
else
    fail "no warning was logged for the convergence failure: ${out_fail}"
fi
APPLY_EXIT=0

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
