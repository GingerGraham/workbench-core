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
    dest: ~/.local/share/workbench/modules/awsconfd/src/
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
mkdir -p "${WORK}/badversion"
cat > "${WORK}/badversion/.dotfiles-sync.yml" <<'EOF'
version: 2
deploy:
  - src: shell/
    dest: ~/.config/workbench-badversion-test/
EOF
mkdir -p "${WORK}/badversion/shell"
touch "${WORK}/badversion/shell/x.sh"
if "${VALIDATE}" "${WORK}/badversion/.dotfiles-sync.yml" >/tmp/wb-validate-badversion.log 2>&1; then
    fail "a version: 2 manifest was accepted — schema version gate not enforced"
else
    ok "a version: 2 manifest is rejected — schema version gate enforced"
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
    dest: ~/.local/share/workbench/modules/awsconfd/src/
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

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
