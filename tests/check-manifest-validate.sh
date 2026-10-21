#!/usr/bin/env bash
# tests/check-manifest-validate.sh — Phase 3 acceptance check for
# lib/manifest/validate.sh. Requires mikefarah/yq v4 on PATH; skips (not
# fails) if it is unavailable, since it's a developer-time-only dependency.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALIDATE="${REPO_ROOT}/lib/manifest/validate.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

if ! command -v yq &>/dev/null || ! yq --version 2>&1 | grep -qE 'mikefarah|version v4'; then
    echo "SKIP: mikefarah/yq v4 not on PATH — lib/manifest/validate.sh is a developer-time tool only, skipping this check."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── Fixture 1: full manifest with a valid register: block — must PASS ──────
mkdir -p "${WORK}/good/shell" "${WORK}/good/bin" "${WORK}/good/hooks"
touch "${WORK}/good/shell/aws.sh" "${WORK}/good/shell/aws-lazy.sh" "${WORK}/good/shell/installers.sh"
echo '#!/bin/sh' > "${WORK}/good/bin/aws-helper"
echo '#!/bin/sh' > "${WORK}/good/hooks/post-deploy.sh"
cat > "${WORK}/good/.dotfiles-sync.yml" <<'EOF'
version: 1
branch: main
deploy:
  - src: shell/
    dest: ~/.config/awsconfd-test/
    mode: copy
core_api: ">=1.0 <2.0"
sync:
  enabled: true
register:
  shell:
    - src: shell/aws.sh
      tier: tools
    - src: shell/aws-lazy.sh
  installers:
    - src: shell/installers.sh
  getters:
    - name: aws
      function: get-aws-functions
      label: "AWS config helpers"
  unknown_future_block:
    - foo: bar
hooks:
  post_deploy:
    command: ["hooks/post-deploy.sh"]
    run_on: changed
    timeout: 60
EOF

if "${VALIDATE}" "${WORK}/good/.dotfiles-sync.yml" >/tmp/wb-validate-good.log 2>&1; then
    ok "a full manifest with a valid register: block (incl. an unknown sub-key) validates cleanly"
else
    fail "a valid manifest was rejected — see /tmp/wb-validate-good.log"
    cat /tmp/wb-validate-good.log
fi

# ── Fixture 2: legacy manifest (no register:/core_api at all) — must PASS ──
mkdir -p "${WORK}/legacy"
cat > "${WORK}/legacy/.dotfiles-sync.yml" <<'EOF'
version: 1
branch: main
deploy:
  - src: shell/
    dest: ~/.config/workbench-legacy-test/
EOF
mkdir -p "${WORK}/legacy/shell"
touch "${WORK}/legacy/shell/x.sh"
if "${VALIDATE}" "${WORK}/legacy/.dotfiles-sync.yml" >/dev/null 2>&1; then
    ok "a legacy (deploy-only, no register:) manifest still validates — additive compatibility holds"
else
    fail "a legacy manifest was rejected — additive compatibility broken"
fi

# ── Fixture 3: unsafe src/dest and mode — must FAIL ─────────────────────────
mkdir -p "${WORK}/bad"
cat > "${WORK}/bad/.dotfiles-sync.yml" <<'EOF'
version: 1
deploy:
  - src: ../escape.sh
    dest: /etc/passwd
    mode: bogus
EOF
if "${VALIDATE}" "${WORK}/bad/.dotfiles-sync.yml" >/tmp/wb-validate-bad.log 2>&1; then
    fail "an unsafe src/dest/mode manifest was accepted"
else
    ok "an unsafe src (../escape.sh), dest (/etc/passwd), and mode (bogus) are all rejected"
fi
# shellcheck disable=SC2015
grep -q "must be a path relative to the repo root" /tmp/wb-validate-bad.log && ok "rejects unsafe src with the expected message" || fail "unsafe src rejection message missing"
# shellcheck disable=SC2015
grep -q "must start with ~/" /tmp/wb-validate-bad.log && ok "rejects unsafe dest with the expected message" || fail "unsafe dest rejection message missing"

# ── Fixture 4: register.shell[] with a dest field — must FAIL ───────────────
mkdir -p "${WORK}/regdest/shell"
touch "${WORK}/regdest/shell/x.sh"
cat > "${WORK}/regdest/.dotfiles-sync.yml" <<'EOF'
version: 1
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/x.sh
      dest: ~/.somewhere/evil
EOF
if "${VALIDATE}" "${WORK}/regdest/.dotfiles-sync.yml" >/tmp/wb-validate-regdest.log 2>&1; then
    fail "register.shell[].dest was accepted — destinations must always be engine-computed"
else
    ok "register.shell[].dest is rejected — engine-computed destinations enforced"
fi

# ── Fixture 5: invalid tier — must FAIL ─────────────────────────────────────
mkdir -p "${WORK}/badtier/shell"
touch "${WORK}/badtier/shell/x.sh"
cat > "${WORK}/badtier/.dotfiles-sync.yml" <<'EOF'
version: 1
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/x.sh
      tier: bogus-tier
EOF
if "${VALIDATE}" "${WORK}/badtier/.dotfiles-sync.yml" >/dev/null 2>&1; then
    fail "an invalid register.shell[].tier was accepted"
else
    ok "an invalid register.shell[].tier is rejected"
fi

# ── Fixture 6: unsupported version — must FAIL ──────────────────────────────
# version: 3 (not version: 2 — that's now a supported schema version, just
# the wrong one for this filename; see fixture 10 below for that case) so
# this still exercises the "no such schema version at all" gate on its own.
mkdir -p "${WORK}/badversion"
cat > "${WORK}/badversion/.dotfiles-sync.yml" <<'EOF'
version: 3
deploy:
  - src: shell/
    dest: ~/.config/workbench-badversion-test/
EOF
mkdir -p "${WORK}/badversion/shell"
touch "${WORK}/badversion/shell/x.sh"
if "${VALIDATE}" "${WORK}/badversion/.dotfiles-sync.yml" >/tmp/wb-validate-badversion.log 2>&1; then
    fail "a version: 3 manifest was accepted — schema version gate not enforced"
else
    ok "a version: 3 manifest is rejected — schema version gate enforced"
fi
# shellcheck disable=SC2015
grep -q "version must be one of" /tmp/wb-validate-badversion.log && ok "rejects unsupported version with the expected message" || fail "unsupported-version rejection message missing"

# ── Fixture 7: workbench.yml/version: 2 — must PASS, identical to fixture 1 ─

mkdir -p "${WORK}/newname/shell" "${WORK}/newname/bin" "${WORK}/newname/hooks"
touch "${WORK}/newname/shell/aws.sh" "${WORK}/newname/shell/aws-lazy.sh" "${WORK}/newname/shell/installers.sh"
echo '#!/bin/sh' > "${WORK}/newname/bin/aws-helper"
echo '#!/bin/sh' > "${WORK}/newname/hooks/post-deploy.sh"
cat > "${WORK}/newname/workbench.yml" <<'EOF'
version: 2
branch: main
deploy:
  - src: shell/
    dest: ~/.config/awsconfd-test/
    mode: copy
core_api: ">=1.0 <2.0"
sync:
  enabled: true
register:
  shell:
    - src: shell/aws.sh
      tier: tools
    - src: shell/aws-lazy.sh
  installers:
    - src: shell/installers.sh
  getters:
    - name: aws
      function: get-aws-functions
      label: "AWS config helpers"
hooks:
  post_deploy:
    command: ["hooks/post-deploy.sh"]
    run_on: changed
    timeout: 60
EOF

if "${VALIDATE}" "${WORK}/newname/workbench.yml" >/tmp/wb-validate-newname.log 2>&1; then
    ok "workbench.yml/version: 2 (otherwise identical to fixture 1) validates cleanly"
else
    fail "workbench.yml/version: 2 was rejected — see /tmp/wb-validate-newname.log"
    cat /tmp/wb-validate-newname.log
fi

# ── Fixture 8: wb.yml/version: 2 — must PASS, confirms the second name works ─

mkdir -p "${WORK}/wbname"
cat > "${WORK}/wbname/wb.yml" <<'EOF'
version: 2
branch: main
deploy:
  - src: shell/
    dest: ~/.config/workbench-wbname-test/
EOF
mkdir -p "${WORK}/wbname/shell"
touch "${WORK}/wbname/shell/x.sh"
if "${VALIDATE}" "${WORK}/wbname/wb.yml" >/tmp/wb-validate-wbname.log 2>&1; then
    ok "wb.yml/version: 2 validates cleanly (second candidate name works identically)"
else
    fail "wb.yml/version: 2 was rejected — see /tmp/wb-validate-wbname.log"
    cat /tmp/wb-validate-wbname.log
fi

# ── Fixture 9: workbench.yml/version: 1 — must FAIL, filename/version mismatch

mkdir -p "${WORK}/mismatch1"
cat > "${WORK}/mismatch1/workbench.yml" <<'EOF'
version: 1
deploy:
  - src: shell/
    dest: ~/.config/workbench-mismatch1-test/
EOF
mkdir -p "${WORK}/mismatch1/shell"
touch "${WORK}/mismatch1/shell/x.sh"
if "${VALIDATE}" "${WORK}/mismatch1/workbench.yml" >/tmp/wb-validate-mismatch1.log 2>&1; then
    fail "workbench.yml/version: 1 was accepted — filename/version pairing not enforced"
else
    ok "workbench.yml/version: 1 is rejected — filename/version pairing enforced"
fi
# shellcheck disable=SC2015
grep -q "must declare version: 2" /tmp/wb-validate-mismatch1.log && ok "rejects the mismatch with the expected message" || fail "filename/version mismatch message missing"

# ── Fixture 10: .dotfiles-sync.yml/version: 2 — must FAIL, mirrors the ───────
#    engine-level test in tests/check-sync-engine-isolation.sh at the
#    validator level.

mkdir -p "${WORK}/mismatch2"
cat > "${WORK}/mismatch2/.dotfiles-sync.yml" <<'EOF'
version: 2
deploy:
  - src: shell/
    dest: ~/.config/workbench-mismatch2-test/
EOF
mkdir -p "${WORK}/mismatch2/shell"
touch "${WORK}/mismatch2/shell/x.sh"
if "${VALIDATE}" "${WORK}/mismatch2/.dotfiles-sync.yml" >/tmp/wb-validate-mismatch2.log 2>&1; then
    fail ".dotfiles-sync.yml/version: 2 was accepted — filename/version pairing not enforced"
else
    ok ".dotfiles-sync.yml/version: 2 is rejected — filename/version pairing enforced"
fi
# shellcheck disable=SC2015
grep -q "must declare version: 1" /tmp/wb-validate-mismatch2.log && ok "rejects the mismatch with the expected message" || fail "filename/version mismatch message missing"

# ── Fixture 11: an unrelated wb.yml with no version: alongside a valid ──────
#    .dotfiles-sync.yml — no-arg discovery must validate the latter, not
#    error about the unrelated wb.yml.

mkdir -p "${WORK}/discovery/shell"
touch "${WORK}/discovery/shell/x.sh"
cat > "${WORK}/discovery/wb.yml" <<'EOF'
some_other_tools_config: true
unrelated: yes
EOF
cat > "${WORK}/discovery/.dotfiles-sync.yml" <<'EOF'
version: 1
deploy:
  - src: shell/
    dest: ~/.config/workbench-discovery-test/
EOF
if ( cd "${WORK}/discovery" && "${VALIDATE}" >/tmp/wb-validate-discovery.log 2>&1 ); then
    ok "no-arg discovery skips an unrelated wb.yml (no version:) and validates .dotfiles-sync.yml instead"
else
    fail "no-arg discovery did not validate the valid .dotfiles-sync.yml alongside an unrelated wb.yml — see /tmp/wb-validate-discovery.log"
    cat /tmp/wb-validate-discovery.log
fi

# ── Fixture 12: an explicit path argument to a filename outside the five ────
#    recognised names bypasses discovery (per usage()) and must validate on
#    its version: value alone — the filename/version pairing check must not
#    fire for a filename workbench_manifest_expected_version doesn't
#    recognise (caught in review: was producing a blank-version "must
#    declare version: " error for any such file).

mkdir -p "${WORK}/customname/shell"
touch "${WORK}/customname/shell/x.sh"
cat > "${WORK}/customname/custom.yml" <<'EOF'
version: 1
deploy:
  - src: shell/
    dest: ~/.config/workbench-customname-test/
EOF
if "${VALIDATE}" "${WORK}/customname/custom.yml" >/tmp/wb-validate-customname.log 2>&1; then
    ok "an explicit path to an unrecognised filename (custom.yml) validates on version: alone, no filename/version pairing error"
else
    fail "an explicit path to an unrecognised filename was incorrectly rejected by the filename/version pairing check — see /tmp/wb-validate-customname.log"
    cat /tmp/wb-validate-customname.log
fi

# ── Fixture 13: valid overrides_src pointing at an existing file — must ─────
#    PASS, with the informational overrides_src: ... line in the output.

mkdir -p "${WORK}/overrides/shell"
touch "${WORK}/overrides/shell/aws.sh"
cat > "${WORK}/overrides/shell/overrides.sh" <<'EOF'
# export AWS_DEFAULT_REGION="eu-west-1"
EOF
cat > "${WORK}/overrides/.dotfiles-sync.yml" <<'EOF'
version: 1
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/aws.sh
overrides_src: shell/overrides.sh
EOF
if "${VALIDATE}" "${WORK}/overrides/.dotfiles-sync.yml" >/tmp/wb-validate-overrides.log 2>&1; then
    ok "a valid overrides_src pointing at an existing file validates cleanly"
else
    fail "a valid overrides_src was rejected — see /tmp/wb-validate-overrides.log"
    cat /tmp/wb-validate-overrides.log
fi
# shellcheck disable=SC2015
grep -q "overrides_src: shell/overrides.sh" /tmp/wb-validate-overrides.log && ok "the informational overrides_src line appears in output" || fail "overrides_src informational line missing"

# ── Fixture 14: overrides_src pointing at a path that doesn't exist in the ──
#    repo — must WARN, not error, mirroring deploy[].src's own behaviour.

mkdir -p "${WORK}/overrides-missing"
cat > "${WORK}/overrides-missing/.dotfiles-sync.yml" <<'EOF'
version: 1
overrides_src: shell/does-not-exist.sh
EOF
if "${VALIDATE}" "${WORK}/overrides-missing/.dotfiles-sync.yml" >/tmp/wb-validate-overrides-missing.log 2>&1; then
    ok "overrides_src pointing at a missing file still validates (warning, not error)"
else
    fail "overrides_src pointing at a missing file was rejected as an error, expected a warning — see /tmp/wb-validate-overrides-missing.log"
    cat /tmp/wb-validate-overrides-missing.log
fi
# shellcheck disable=SC2015
grep -q "\[WARN\].*overrides_src 'shell/does-not-exist.sh' does not exist" /tmp/wb-validate-overrides-missing.log && ok "the missing-overrides_src warning message is present" || fail "missing-overrides_src warning message missing"

# ── Fixture 15: overrides_src with a '..' escape — must FAIL, mirroring ─────
#    deploy[].src's own path-safety check.

mkdir -p "${WORK}/overrides-escape"
cat > "${WORK}/overrides-escape/.dotfiles-sync.yml" <<'EOF'
version: 1
overrides_src: ../escape.sh
EOF
if "${VALIDATE}" "${WORK}/overrides-escape/.dotfiles-sync.yml" >/tmp/wb-validate-overrides-escape.log 2>&1; then
    fail "overrides_src: ../escape.sh was accepted — path-safety check not enforced"
else
    ok "overrides_src: ../escape.sh is rejected — path-safety check enforced"
fi
# shellcheck disable=SC2015
grep -q "overrides_src '../escape.sh' must be a path relative to the repo root" /tmp/wb-validate-overrides-escape.log && ok "rejects the unsafe overrides_src with the expected message" || fail "unsafe overrides_src rejection message missing"

# ── Fixture 16: a manifest declaring only overrides_src (no deploy[], no ────
#    register.shell[], no hooks) — must validate cleanly with NO "clone-only,
#    confirm deliberate" warning (the §2c fix).

mkdir -p "${WORK}/overrides-only/shell"
cat > "${WORK}/overrides-only/shell/overrides.sh" <<'EOF'
# export SOME_OPINION="default"
EOF
cat > "${WORK}/overrides-only/.dotfiles-sync.yml" <<'EOF'
version: 1
overrides_src: shell/overrides.sh
EOF
if "${VALIDATE}" "${WORK}/overrides-only/.dotfiles-sync.yml" >/tmp/wb-validate-overrides-only.log 2>&1; then
    ok "a manifest declaring only overrides_src (no deploy/register.shell/hooks) validates cleanly"
else
    fail "an overrides_src-only manifest was rejected — see /tmp/wb-validate-overrides-only.log"
    cat /tmp/wb-validate-overrides-only.log
fi
if grep -q "clone-only" /tmp/wb-validate-overrides-only.log; then
    fail "an overrides_src-only manifest incorrectly triggered the clone-only warning"
else
    ok "an overrides_src-only manifest does not trigger the clone-only warning"
fi

# ── Fixtures 17+: deploy[].lifecycle / yield_to (docs/decisions-log.md D81) ──
# _d81_case <name> <expect: pass|fail> <message-grep-or-empty> <description>
# The deploy entry comes from stdin, indented under 'deploy:'.
_d81_case() {
    local expect="$2" pattern="$3" desc="$4" dir="${WORK}/d81-$1" log rc=0
    mkdir -p "${dir}/files"
    touch "${dir}/files/tmux.conf"
    {
        printf 'version: 1\ndeploy:\n'
        cat
    } > "${dir}/.dotfiles-sync.yml"
    log="${dir}/validate.log"
    "${VALIDATE}" "${dir}/.dotfiles-sync.yml" > "${log}" 2>&1 || rc=$?
    if [[ "${expect}" == "pass" && "${rc}" -ne 0 ]]; then
        fail "${desc} — rejected, expected valid:"; cat "${log}"; return
    fi
    if [[ "${expect}" == "fail" && "${rc}" -eq 0 ]]; then
        fail "${desc} — accepted, expected an error"; return
    fi
    if [[ -n "${pattern}" ]] && ! grep -qF -- "${pattern}" "${log}"; then
        fail "${desc} — expected message '${pattern}' missing:"; cat "${log}"; return
    fi
    ok "${desc}"
}

_d81_case lifecycle-ok pass "" "lifecycle: seed/managed/generated and a flow-form yield_to validate cleanly" <<'EOF'
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    lifecycle: managed
    yield_to: [~/.tmux.conf]
  - src: files/tmux.conf
    dest: ~/.config/d81/seed.conf
    lifecycle: seed
  - src: files/tmux.conf
    dest: ~/.config/d81/gen.conf
    lifecycle: generated
    force: true
EOF

_d81_case lifecycle-bad fail "lifecycle must be 'seed', 'managed', or 'generated'" "an unknown lifecycle value is rejected" <<'EOF'
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    lifecycle: sometimes
EOF

_d81_case force-contradicts fail "force: true is the legacy spelling of lifecycle: generated — drop one" "force: true with lifecycle: managed is rejected" <<'EOF'
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    lifecycle: managed
    force: true
EOF

_d81_case lifecycle-on-link fail "lifecycle applies to copy-mode entries" "lifecycle on a mode: link entry is rejected" <<'EOF'
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    mode: link
    lifecycle: managed
EOF

_d81_case yield-link-ok pass "" "yield_to on a mode: link entry is allowed" <<'EOF'
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    mode: link
    yield_to: [~/.tmux.conf]
EOF

_d81_case yield-block fail "yield_to must use flow form" "block-form yield_to is rejected with a pointer to flow form" <<'EOF'
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    yield_to:
      - ~/.tmux.conf
EOF

_d81_case yield-scalar fail "yield_to must be a list" "a scalar yield_to is rejected" <<'EOF'
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    yield_to: ~/.tmux.conf
EOF

_d81_case yield-denied fail "yield_to[0] '~/.bashrc'" "a denylisted yield_to path is rejected (full dest validation)" <<'EOF'
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    yield_to: [~/.bashrc]
EOF

_d81_case yield-escape fail "yield_to[1] '~/../etc/passwd'" "a yield_to path with '..' is rejected" <<'EOF'
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    yield_to: [~/.tmux.conf, ~/../etc/passwd]
EOF

_d81_case yield-not-string fail "yield_to[0] must be a string" "a non-string yield_to item is rejected" <<'EOF'
  - src: files/tmux.conf
    dest: ~/.config/tmux/tmux.conf
    yield_to: [{a: b}]
EOF

_d81_case dest-pipe fail "must not contain '|' or ','" "a '|' in dest is rejected" <<'EOF'
  - src: files/tmux.conf
    dest: "~/.config/a|b.conf"
EOF

_d81_case dest-macos-comma fail "dest_macos '~/Library/a,b.conf' must not contain" "a ',' in dest_macos is rejected" <<'EOF'
  - src: files/tmux.conf
    dest: ~/.config/a.conf
    dest_macos: "~/Library/a,b.conf"
EOF

_d81_case yield-pipe fail "yield_to[0] '~/.a|b' must not contain" "a '|' in a yield_to item is rejected" <<'EOF'
  - src: files/tmux.conf
    dest: ~/.config/a.conf
    yield_to: ["~/.a|b"]
EOF

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
