#!/usr/bin/env bash
# tests/check-manifest-parse.sh — Phase 3 acceptance check for the hot-path
# manifest reader, lib/manifest/parse.sh. Pure bash/awk, no yq/python3 —
# this test runs unconditionally (no dependency to skip on).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/manifest/parse.sh
source "${REPO_ROOT}/lib/manifest/parse.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

MANIFEST="${WORK}/.dotfiles-sync.yml"
cat > "${MANIFEST}" <<'EOF'
version: 1
branch: main

deploy:
  - src: shell/
    dest: ~/.local/share/workbench/modules/awsconfd/src/
    mode: copy
  - src: bin/aws-helper
    dest: ~/.local/bin/aws-helper
    dest_macos: ~/Library/aws-helper
    mode: link
    force: true
    platforms: [linux, macos]

core_api: ">=1.0 <2.0"
sync:
  enabled: false

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
    command: ["hooks/post-deploy.sh", "arg1"]
    run_on: changed
    timeout: 60
EOF

[[ "$(workbench_manifest_scalar version "${MANIFEST}")" == "1" ]] \
    && ok "version scalar extracted" || fail "version scalar extraction failed"

[[ "$(workbench_manifest_scalar branch "${MANIFEST}")" == "main" ]] \
    && ok "branch scalar extracted" || fail "branch scalar extraction failed"

[[ "$(workbench_manifest_scalar core_api "${MANIFEST}")" == ">=1.0 <2.0" ]] \
    && ok "core_api scalar extracted with embedded spaces intact" || fail "core_api scalar extraction failed"

[[ "$(workbench_manifest_sync_enabled "${MANIFEST}")" == "false" ]] \
    && ok "sync.enabled: false read correctly" || fail "sync.enabled extraction failed"

deploy_out="$(workbench_manifest_deploy_entries "${MANIFEST}")"
expected_deploy_0="shell/|~/.local/share/workbench/modules/awsconfd/src/||copy|false|"
expected_deploy_1="bin/aws-helper|~/.local/bin/aws-helper|~/Library/aws-helper|link|true|linux,macos"
if [[ "$(sed -n '1p' <<< "${deploy_out}")" == "${expected_deploy_0}" ]]; then
    ok "deploy[0] parsed correctly (mode/force defaults applied)"
else
    fail "deploy[0] mismatch: $(sed -n '1p' <<< "${deploy_out}")"
fi
if [[ "$(sed -n '2p' <<< "${deploy_out}")" == "${expected_deploy_1}" ]]; then
    ok "deploy[1] parsed correctly (dest_macos, force, platforms)"
else
    fail "deploy[1] mismatch: $(sed -n '2p' <<< "${deploy_out}")"
fi

shell_out="$(workbench_manifest_register_shell_entries "${MANIFEST}")"
[[ "$(sed -n '1p' <<< "${shell_out}")" == "shell/aws.sh|tools" ]] \
    && ok "register.shell[0] parsed with explicit tier" || fail "register.shell[0] mismatch: $(sed -n '1p' <<< "${shell_out}")"
[[ "$(sed -n '2p' <<< "${shell_out}")" == "shell/aws-lazy.sh|tools" ]] \
    && ok "register.shell[1] parsed with default tier (tools)" || fail "register.shell[1] mismatch: $(sed -n '2p' <<< "${shell_out}")"

[[ "$(workbench_manifest_register_installer_entries "${MANIFEST}")" == "shell/installers.sh" ]] \
    && ok "register.installers[0] parsed" || fail "register.installers[0] mismatch"

getters_out="$(workbench_manifest_register_getter_entries "${MANIFEST}")"
[[ "${getters_out}" == "aws|get-aws-functions|AWS config helpers" ]] \
    && ok "register.getters[0] parsed (name|function|label)" || fail "register.getters[0] mismatch: ${getters_out}"

hook_out="$(workbench_manifest_hook_post_deploy "${MANIFEST}")"
[[ "${hook_out}" == "changed|60|hooks/post-deploy.sh|arg1" ]] \
    && ok "hooks.post_deploy parsed (run_on|timeout|argv...)" || fail "hooks.post_deploy mismatch: ${hook_out}"

# ── Legacy manifest (no register:/core_api/hooks) degrades gracefully ──────
LEGACY="${WORK}/legacy.yml"
cat > "${LEGACY}" <<'EOF'
version: 1
branch: main
deploy:
  - src: shell/
    dest: ~/.config/shell/
EOF

[[ -z "$(workbench_manifest_scalar core_api "${LEGACY}")" ]] \
    && ok "legacy manifest: core_api empty, not an error" || fail "legacy manifest: core_api should be empty"
[[ "$(workbench_manifest_sync_enabled "${LEGACY}")" == "true" ]] \
    && ok "legacy manifest: sync.enabled defaults to true" || fail "legacy manifest: sync.enabled default wrong"
[[ -z "$(workbench_manifest_register_shell_entries "${LEGACY}")" ]] \
    && ok "legacy manifest: no register.shell entries, not an error" || fail "legacy manifest: unexpected register.shell entries"
[[ -z "$(workbench_manifest_hook_post_deploy "${LEGACY}")" ]] \
    && ok "legacy manifest: no hook, not an error" || fail "legacy manifest: unexpected hook output"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
