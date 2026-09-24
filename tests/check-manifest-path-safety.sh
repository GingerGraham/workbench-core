#!/usr/bin/env bash
# tests/check-manifest-path-safety.sh — docs/decisions-log.md D75 acceptance
# check (security review H1): runtime enforcement of manifest path rules.
# Unit-level checks against _wb_dest_is_safe/_wb_path_is_safe_relative
# directly, plus integration checks that workbench_sync_module and
# workbench_deploy_module actually refuse unsafe manifests/targets rather
# than merely documenting the rule.
#
# Every "~/..." literal below is a deliberately-unexpanded test fixture
# string passed to _wb_dest_is_safe, never a path this script itself opens.
# shellcheck disable=SC2088
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
export HOME="${WORK}/home"
mkdir -p "${HOME}"

# shellcheck source=lib/sync/engine.sh
source "${REPO_ROOT}/lib/sync/engine.sh"

# ── 1. _wb_dest_is_safe accepts legitimate destinations ────────────────────
if _wb_dest_is_safe "~/.config/tmux/tmux.conf" ""; then
    ok "_wb_dest_is_safe accepts ~/.config/tmux/tmux.conf"
else
    fail "_wb_dest_is_safe wrongly rejected ~/.config/tmux/tmux.conf"
fi

if _wb_dest_is_safe "~/.local/share/workbench/modules/git/files/ignore" "git"; then
    ok "_wb_dest_is_safe accepts a module's own modules/<name>/files/ subtree (git)"
else
    fail "_wb_dest_is_safe wrongly rejected modules/git/files/ignore for module git"
fi

# ── 2. _wb_dest_is_safe rejects unsafe/denylisted destinations ─────────────
declare -a UNSAFE_DESTS=(
    "/etc/x"
    "~/../x"
    "~/.ssh/authorized_keys"
    "~/.SSH/x"
    "~/.local//bin/x"
    "~/./.bashrc"
    "~/.local/bin/sudo"
    "~/.local/share/workbench/modules/core/sync.conf"
    "~/.zshenv"
    "~/Library/LaunchAgents/x.plist"
)
_all_rejected=1
for _d in "${UNSAFE_DESTS[@]}"; do
    if _wb_dest_is_safe "${_d}" "git"; then
        fail "_wb_dest_is_safe wrongly accepted '${_d}'"
        _all_rejected=0
    fi
done
[[ "${_all_rejected}" -eq 1 ]] && ok "_wb_dest_is_safe rejects every entry in the unsafe-dest list (module git)"

if _wb_dest_is_safe "~/.local/share/workbench/modules/other/files/x" "git"; then
    fail "_wb_dest_is_safe wrongly accepted another module's files/ subtree (other, checked as git)"
else
    ok "_wb_dest_is_safe rejects another module's own files/ subtree"
fi

if _wb_dest_is_safe "~/.local/share/workbench/modules/git/sync.conf" "git"; then
    fail "_wb_dest_is_safe wrongly accepted a module's own sync.conf"
else
    ok "_wb_dest_is_safe rejects a module's own sync.conf (not under files/)"
fi

# ── 3. _wb_path_is_safe_relative ────────────────────────────────────────────
if _wb_path_is_safe_relative "../x" || _wb_path_is_safe_relative "a/../b" || _wb_path_is_safe_relative "/abs"; then
    fail "_wb_path_is_safe_relative wrongly accepted an unsafe path"
else
    ok "_wb_path_is_safe_relative rejects ../x, a/../b, and /abs"
fi

if _wb_path_is_safe_relative "a/b" && _wb_path_is_safe_relative "."; then
    ok "_wb_path_is_safe_relative accepts a/b and ."
else
    fail "_wb_path_is_safe_relative wrongly rejected a safe relative path"
fi

# ── Shared bare-repo fixture for the engine-gate checks (4, 5) ─────────────
# Same PRIVATE=true local-bare-repo pattern tests/check-sync-engine-
# isolation.sh uses.
setup_module() {
    local name="$1" repo_url="$2"
    mkdir -p "$(workbench_module_dir "${name}")"
    cat > "$(workbench_module_conf_path "${name}")" <<EOF
REPO_URL=${repo_url}
PRIVATE=true
TRACK_MODE=latest
REGISTERED=true
SYNC_ENABLED=true
ALLOW_HOOKS=true
EOF
}

# ── 4. Engine gate: manifest deploys to ~/.bashrc — refused before swap ────
BARE4="${WORK}/bare4.git"
SRC4="${WORK}/src4"
mkdir -p "${SRC4}"
git init -q --bare "${BARE4}"
git clone -q "${BARE4}" "${SRC4}"
(
    cd "${SRC4}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    echo 'x=1' > shell/x.sh
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
deploy:
  - src: shell/x.sh
    dest: ~/.bashrc
    mode: copy
core_api: ">=1.0 <2.0"
EOF
    git add -A && git commit -q -m "v1"
    git branch -M main
    git push -q origin main
)
setup_module bashrctest "${BARE4}"
workbench_sync_module bashrctest >/tmp/wb-path-safety-4.log 2>&1
rc4=$?
if [[ "${rc4}" -ne 0 ]]; then
    ok "engine gate: workbench_sync_module returned non-zero for a manifest deploying to ~/.bashrc"
else
    fail "engine gate: workbench_sync_module unexpectedly succeeded for a manifest deploying to ~/.bashrc"
fi
if [[ ! -e "$(workbench_module_current_dir bashrctest)" ]]; then
    ok "engine gate: current snapshot was not created for the unsafe manifest"
else
    fail "engine gate: current snapshot exists despite the unsafe manifest"
fi
if [[ ! -e "${HOME}/.bashrc" ]]; then
    ok "engine gate: ~/.bashrc was never written"
else
    fail "engine gate: ~/.bashrc was written despite the unsafe manifest"
fi

# ── 5. Hook gate: command: ["../../x.sh"] refused at the gate ──────────────
BARE5="${WORK}/bare5.git"
SRC5="${WORK}/src5"
mkdir -p "${SRC5}"
git init -q --bare "${BARE5}"
git clone -q "${BARE5}" "${SRC5}"
(
    cd "${SRC5}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    echo 'x=1' > shell/x.sh
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
deploy:
  - src: shell/x.sh
    dest: ~/.config/hooktest/x.sh
    mode: copy
core_api: ">=1.0 <2.0"
hooks:
  post_deploy:
    command: ["../../x.sh"]
    run_on: always
    timeout: 60
EOF
    git add -A && git commit -q -m "v1"
    git branch -M main
    git push -q origin main
)
setup_module hooktest "${BARE5}"
workbench_sync_module hooktest >/tmp/wb-path-safety-5.log 2>&1
rc5=$?
if [[ "${rc5}" -ne 0 ]]; then
    ok "hook gate: workbench_sync_module returned non-zero for command: [\"../../x.sh\"]"
else
    fail "hook gate: workbench_sync_module unexpectedly succeeded for an unsafe hook command"
fi
if [[ ! -e "$(workbench_module_current_dir hooktest)" ]]; then
    ok "hook gate: current snapshot was not created for the unsafe hook manifest"
else
    fail "hook gate: current snapshot exists despite the unsafe hook manifest"
fi

# ── 6. Symlink parent: ~/.config/evil -> ~/.ssh, deploy target resolves
#    through it into the denylist ──────────────────────────────────────────
mkdir -p "${HOME}/.ssh"
mkdir -p "${HOME}/.config"
ln -s "${HOME}/.ssh" "${HOME}/.config/evil"

CURRENT6="$(workbench_module_current_dir symlinkparent)"
mkdir -p "${CURRENT6}/files"
echo "not-a-real-key" > "${CURRENT6}/files/key"
cat > "${CURRENT6}/.dotfiles-sync.yml" <<'EOF'
version: 1
branch: main
deploy:
  - src: files/key
    dest: ~/.config/evil/authorized_keys
    mode: copy
core_api: ">=1.0 <2.0"
EOF
workbench_deploy_module symlinkparent >/tmp/wb-path-safety-6.log 2>&1
if [[ ! -e "${HOME}/.ssh/authorized_keys" ]]; then
    ok "symlink parent: ~/.config/evil -> ~/.ssh does not let a deploy write ~/.ssh/authorized_keys"
else
    fail "symlink parent: ~/.ssh/authorized_keys was written through the symlinked parent"
fi
if grep -q "resolves through a symlink to a denied location" /tmp/wb-path-safety-6.log; then
    ok "symlink parent: refusal is logged"
else
    fail "symlink parent: no refusal was logged — see /tmp/wb-path-safety-6.log"
    cat /tmp/wb-path-safety-6.log
fi

# ── 7. Symlink src: repo contains evil2 -> $HOME/.ssh, deployed in link mode ─
CURRENT7="$(workbench_module_current_dir symlinksrc)"
mkdir -p "${CURRENT7}"
ln -s "${HOME}/.ssh" "${CURRENT7}/evil2"
cat > "${CURRENT7}/.dotfiles-sync.yml" <<'EOF'
version: 1
branch: main
deploy:
  - src: evil2
    dest: ~/.config/evil2
    mode: link
core_api: ">=1.0 <2.0"
EOF
workbench_deploy_module symlinksrc >/tmp/wb-path-safety-7.log 2>&1
if [[ ! -e "${HOME}/.config/evil2" ]]; then
    ok "symlink src: a symlinked deploy src is refused, ~/.config/evil2 not created"
else
    fail "symlink src: ~/.config/evil2 was created despite the symlinked src"
fi
if grep -q "it is a symlink" /tmp/wb-path-safety-7.log; then
    ok "symlink src: refusal is logged"
else
    fail "symlink src: no refusal was logged — see /tmp/wb-path-safety-7.log"
    cat /tmp/wb-path-safety-7.log
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
