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

# shellcheck disable=SC2015
[[ "$(workbench_manifest_scalar version "${MANIFEST}")" == "1" ]] \
    && ok "version scalar extracted" || fail "version scalar extraction failed"

# shellcheck disable=SC2015
[[ "$(workbench_manifest_scalar branch "${MANIFEST}")" == "main" ]] \
    && ok "branch scalar extracted" || fail "branch scalar extraction failed"

# shellcheck disable=SC2015
[[ "$(workbench_manifest_scalar core_api "${MANIFEST}")" == ">=1.0 <2.0" ]] \
    && ok "core_api scalar extracted with embedded spaces intact" || fail "core_api scalar extraction failed"

# shellcheck disable=SC2015
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
# shellcheck disable=SC2015
[[ "$(sed -n '1p' <<< "${shell_out}")" == "shell/aws.sh|tools" ]] \
    && ok "register.shell[0] parsed with explicit tier" || fail "register.shell[0] mismatch: $(sed -n '1p' <<< "${shell_out}")"
# shellcheck disable=SC2015
[[ "$(sed -n '2p' <<< "${shell_out}")" == "shell/aws-lazy.sh|tools" ]] \
    && ok "register.shell[1] parsed with default tier (tools)" || fail "register.shell[1] mismatch: $(sed -n '2p' <<< "${shell_out}")"

# shellcheck disable=SC2015
[[ "$(workbench_manifest_register_installer_entries "${MANIFEST}")" == "shell/installers.sh" ]] \
    && ok "register.installers[0] parsed" || fail "register.installers[0] mismatch"

getters_out="$(workbench_manifest_register_getter_entries "${MANIFEST}")"
# shellcheck disable=SC2015
[[ "${getters_out}" == "aws|get-aws-functions|AWS config helpers" ]] \
    && ok "register.getters[0] parsed (name|function|label)" || fail "register.getters[0] mismatch: ${getters_out}"

hook_out="$(workbench_manifest_hook_post_deploy "${MANIFEST}")"
# shellcheck disable=SC2015
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

# shellcheck disable=SC2015
[[ -z "$(workbench_manifest_scalar core_api "${LEGACY}")" ]] \
    && ok "legacy manifest: core_api empty, not an error" || fail "legacy manifest: core_api should be empty"
# shellcheck disable=SC2015
[[ "$(workbench_manifest_sync_enabled "${LEGACY}")" == "true" ]] \
    && ok "legacy manifest: sync.enabled defaults to true" || fail "legacy manifest: sync.enabled default wrong"
# shellcheck disable=SC2015
[[ -z "$(workbench_manifest_register_shell_entries "${LEGACY}")" ]] \
    && ok "legacy manifest: no register.shell entries, not an error" || fail "legacy manifest: unexpected register.shell entries"
# shellcheck disable=SC2015
[[ -z "$(workbench_manifest_hook_post_deploy "${LEGACY}")" ]] \
    && ok "legacy manifest: no hook, not an error" || fail "legacy manifest: unexpected hook output"

# ── Manifest filename resolution & version pairing (ARCHITECTURE.md §12 D46) ─

# shellcheck disable=SC2015
[[ "$(workbench_manifest_expected_version .dotfiles-sync.yml)" == "1" ]] \
    && ok "expected version for .dotfiles-sync.yml is 1" || fail "expected version for .dotfiles-sync.yml wrong"
# shellcheck disable=SC2015
[[ "$(workbench_manifest_expected_version workbench.yml)" == "2" ]] \
    && ok "expected version for workbench.yml is 2" || fail "expected version for workbench.yml wrong"
# shellcheck disable=SC2015
[[ "$(workbench_manifest_expected_version wb.yaml)" == "2" ]] \
    && ok "expected version for wb.yaml is 2" || fail "expected version for wb.yaml wrong"

RESOLVEDIR="${WORK}/resolve"
mkdir -p "${RESOLVEDIR}"

# No manifest at all — resolves to nothing.
if workbench_resolve_manifest_path "${RESOLVEDIR}" >/tmp/wb-parse-resolve-none.log 2>&1; then
    fail "workbench_resolve_manifest_path resolved something in an empty directory"
else
    ok "workbench_resolve_manifest_path finds nothing in a manifest-less directory"
fi

# Only .dotfiles-sync.yml present — resolves to it.
echo "version: 1" > "${RESOLVEDIR}/.dotfiles-sync.yml"
# shellcheck disable=SC2015
[[ "$(workbench_resolve_manifest_path "${RESOLVEDIR}")" == "${RESOLVEDIR}/.dotfiles-sync.yml" ]] \
    && ok "resolves .dotfiles-sync.yml when it's the only candidate present" || fail "did not resolve .dotfiles-sync.yml"

# workbench.yml with a version: key takes precedence over .dotfiles-sync.yml.
echo "version: 2" > "${RESOLVEDIR}/workbench.yml"
# shellcheck disable=SC2015
[[ "$(workbench_resolve_manifest_path "${RESOLVEDIR}")" == "${RESOLVEDIR}/workbench.yml" ]] \
    && ok "workbench.yml takes precedence over .dotfiles-sync.yml when both are present" || fail "precedence order wrong"
rm -f "${RESOLVEDIR}/workbench.yml"

# A wb.yml with no version: key is skipped (not ours) — falls through to
# .dotfiles-sync.yml, never erroring on the stranger's file.
cat > "${RESOLVEDIR}/wb.yml" <<'EOF'
some_other_tools_config: true
EOF
# shellcheck disable=SC2015
[[ "$(workbench_resolve_manifest_path "${RESOLVEDIR}")" == "${RESOLVEDIR}/.dotfiles-sync.yml" ]] \
    && ok "a wb.yml with no version: key is skipped as not-ours, falls through to .dotfiles-sync.yml" || fail "unrelated wb.yml was not skipped"
rm -f "${RESOLVEDIR}/wb.yml" "${RESOLVEDIR}/.dotfiles-sync.yml"

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
