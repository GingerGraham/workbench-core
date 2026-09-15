#!/usr/bin/env bash
# tests/check-functions-lazy-tier.sh — regression guard for workbench-gpg#7.
#
# `wb functions`'s "Loaded functions" listing must include tier: lazy
# register.shell[] content, since lib/loader.sh's _WB_LOADER_TIERS loop
# sources every tier unconditionally except platform/distro (host-matched
# via _wb_loader_should_source_by_name). Verifies two ways: (1) a synthetic
# module's lazy-tier function shows up in `wb functions` output, and (2) a
# companion platform-tier file whose basename can't match this host is
# still correctly excluded — confirming the fix didn't also loosen the
# platform/distro filter it shares code with.
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

WB="${REPO_ROOT}/bin/wb"

# ── Synthetic module: a tools-tier file, a lazy-tier file, and a
#    platform-tier file whose basename never matches a real host. ────────
SRC="${WORK}/src"
BARE="${WORK}/bare.git"
mkdir -p "${SRC}"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}"
(
    cd "${SRC}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    mkdir -p shell
    cat > shell/gizmo.sh <<'SH'
gizmo-do-a-thing() { :; }
SH
    cat > shell/gizmo-advanced.sh <<'SH'
gizmo-advanced-thing() { :; }
SH
    cat > shell/gizmo-solaris.sh <<'SH'
gizmo-solaris-only-thing() { :; }
SH
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
core_api: ">=1.0 <2.0"
register:
  shell:
    - src: shell/gizmo.sh
      tier: tools
    - src: shell/gizmo-advanced.sh
      tier: lazy
    - src: shell/gizmo-solaris.sh
      tier: platform
EOF
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)

bash "${WB}" add gizmo-module "${BARE}" --private >/tmp/wb-functions-lazy-tier-add.log 2>&1
functions_out="$(bash "${WB}" functions 2>&1)"

if echo "${functions_out}" | grep -q "gizmo-advanced-thing"; then
    ok "wb functions lists a function from a tier: lazy registered file"
else
    fail "wb functions did not list gizmo-advanced-thing (tier: lazy) — lazy-tier files must be sourced eagerly by lib/loader.sh, same as any other non-platform/distro tier"
    cat /tmp/wb-functions-lazy-tier-add.log
    echo "${functions_out}"
fi

if echo "${functions_out}" | grep -q "gizmo-do-a-thing"; then
    ok "wb functions still lists a function from a tier: tools registered file"
else
    fail "wb functions did not list gizmo-do-a-thing (tier: tools)"
fi

if echo "${functions_out}" | grep -q "gizmo-solaris-only-thing"; then
    fail "wb functions listed gizmo-solaris-only-thing — a tier: platform file whose basename ('gizmo-solaris') can't match this host should still be excluded"
else
    ok "wb functions still excludes a tier: platform file that doesn't match this host"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
