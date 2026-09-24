#!/usr/bin/env bash
# tests/check-input-validation.sh — docs/decisions-log.md acceptance check
# for workbench_valid_module_name/workbench_valid_repo_url (security review
# L3): the module name becomes a directory name, an ssh_config Host alias,
# and an environment-variable suffix; REPO_URL is passed to `git ls-remote`
# and `git remote add`. Both are local inputs today, but catalog/bundle
# override files feed them.
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

# shellcheck source=lib/sync/engine.sh
source "${REPO_ROOT}/lib/sync/engine.sh"
# shellcheck source=lib/modules/add.sh
source "${REPO_ROOT}/lib/modules/add.sh"

# Isolate wb add's own validation from a real network/sync cycle.
workbench_sync_module() { return 0; }

# ── Names ────────────────────────────────────────────────────────────────────
declare -a GOOD_NAMES=("git" "workbench-foo" "a1")
_all_good=1
for _n in "${GOOD_NAMES[@]}"; do
    workbench_valid_module_name "${_n}" || { fail "workbench_valid_module_name wrongly rejected '${_n}'"; _all_good=0; }
done
[[ "${_all_good}" -eq 1 ]] && ok "workbench_valid_module_name accepts: ${GOOD_NAMES[*]}"

declare -a BAD_NAMES=("Git" "-x" "a b")
BAD_NAMES+=("a/b" "$(printf 'a\nProxyCommand x')" "../x")
BAD_NAMES+=("$(printf 'a%.0s' $(seq 1 65))")
_all_rejected=1
for _n in "${BAD_NAMES[@]}"; do
    if workbench_valid_module_name "${_n}"; then
        fail "workbench_valid_module_name wrongly accepted '${_n}'"
        _all_rejected=0
    fi
done
[[ "${_all_rejected}" -eq 1 ]] && ok "workbench_valid_module_name rejects: Git, -x, 'a b', a/b, embedded newline, ../x, a 65-char name"

# Under some UTF-8 locales (observed on macOS CI runners; not reproducible
# under every host's default locale, hence the guard), bash's [a-z] bracket
# range follows locale collation order rather than a strict ASCII range,
# which previously let 'Git' slip past *[!a-z0-9-]*. workbench_valid_module_name
# pins LC_ALL=C internally — this proves that pin actually holds regardless
# of the caller's ambient locale.
if locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
    if LC_ALL=en_US.UTF-8 workbench_valid_module_name "Git"; then
        fail "workbench_valid_module_name wrongly accepted 'Git' under LC_ALL=en_US.UTF-8"
    else
        ok "workbench_valid_module_name rejects 'Git' under LC_ALL=en_US.UTF-8 (locale-independent)"
    fi
else
    ok "workbench_valid_module_name locale-independence check skipped (en_US.UTF-8 not installed on this host)"
fi

# ── URLs ─────────────────────────────────────────────────────────────────────
declare -a GOOD_URLS=("https://github.com/o/r.git" "git@github.com:o/r.git" "ssh://git@host/o/r" "/tmp/bare.git" "file:///tmp/bare.git")
_all_good=1
for _u in "${GOOD_URLS[@]}"; do
    workbench_valid_repo_url "${_u}" || { fail "workbench_valid_repo_url wrongly rejected '${_u}'"; _all_good=0; }
done
[[ "${_all_good}" -eq 1 ]] && ok "workbench_valid_repo_url accepts: ${GOOD_URLS[*]}"

declare -a BAD_URLS=("--upload-pack=touch /tmp/x" "-x" "ext::sh -c x" "https://a b.example/x" "")
_all_rejected=1
for _u in "${BAD_URLS[@]}"; do
    if workbench_valid_repo_url "${_u}"; then
        fail "workbench_valid_repo_url wrongly accepted '${_u}'"
        _all_rejected=0
    fi
done
[[ "${_all_rejected}" -eq 1 ]] && ok "workbench_valid_repo_url rejects: --upload-pack=..., -x, ext::sh -c x, a url with an embedded space, empty"

# ── wb add with a bad name ──────────────────────────────────────────────────
workbench_cmd_add "Bad Name" "https://github.com/o/r.git" >/tmp/wb-input-validation-add.log 2>&1
rc=$?
if [[ "${rc}" -eq 2 ]]; then
    ok "wb add with a bad name exits 2"
else
    fail "wb add with a bad name exited ${rc}, expected 2 — see /tmp/wb-input-validation-add.log"
fi
if [[ ! -d "$(workbench_module_dir "Bad Name")" ]]; then
    ok "wb add with a bad name created no module directory"
else
    fail "wb add with a bad name created a module directory anyway"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
