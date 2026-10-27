#!/usr/bin/env bash
# tests/check-input-validation.sh — docs/decisions-log.md acceptance check
# for workbench_valid_module_name/workbench_valid_repo_url (security review
# L3): the module name becomes a directory name, an ssh_config Host alias,
# and an environment-variable suffix; REPO_URL is passed to `git ls-remote`
# and `git remote add`. Both are local inputs today, but catalog/bundle
# override files feed them.
#
# Also security status N14: every redirect-following curl in the
# distribution path is https-only, and a commit sha from the GitHub API is
# refused unless it is 40 lowercase hex, in lib/distribution/resolve.sh and
# bootstrap.sh.
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

# ── N14: https-only curl ─────────────────────────────────────────────────────
# Every curl that follows redirects (-L, or -fsSL style flag groups, or
# --location) carries both --proto and --proto-redir. Backslash-continued
# lines are joined first, and comment lines are skipped.
_curl_missing=""
for _f in lib/distribution/resolve.sh lib/distribution/fetch-tarball.sh \
          bootstrap.sh lib/core/installers-common.sh; do
    while IFS= read -r _line; do
        case "${_line}" in
            *--proto\ *--proto-redir*) ;;
            *) _curl_missing="${_curl_missing}
    ${_f}: ${_line}" ;;
        esac
    done < <(awk '
        /^[[:space:]]*#/ { next }
        { line = (cont ? line " " : "") $0 }
        /\\$/ { cont = 1; sub(/\\$/, "", line); next }
        { cont = 0; print line; line = "" }
    ' "${REPO_ROOT}/${_f}" \
        | grep -E '(^|[^a-zA-Z_-])curl[[:space:]]' \
        | grep -E '[[:space:]]-[a-zA-Z]*L|--location')
done
if [[ -z "${_curl_missing}" ]]; then
    ok "every redirect-following curl in the distribution path has --proto and --proto-redir"
else
    fail "curl without --proto/--proto-redir:${_curl_missing}"
fi

# ── N14: a non-hex sha from the API is refused ───────────────────────────────
# shellcheck source=lib/distribution/resolve.sh
source "${REPO_ROOT}/lib/distribution/resolve.sh"
GOOD_SHA="0123456789abcdef0123456789abcdef01234567"
_stub_sha=""
# shellcheck disable=SC2317,SC2329  # invoked indirectly, by the resolvers (SC2317 on shellcheck < 0.11)
_wb_gh_curl() {
    case "$1" in
        */tags*)    printf '[{"name": "v1.2.3", "commit": {"sha": "%s", "url": "x"}}]' "${_stub_sha}" ;;
        */commits/*) printf '{"sha": "%s", "node_id": "x"}' "${_stub_sha}" ;;
    esac
}

_stub_sha="${GOOD_SHA}"
if [[ "$(workbench_resolve_latest_tag_public o r 2>/dev/null)" == "v1.2.3|${GOOD_SHA}" ]] \
    && [[ "$(workbench_resolve_tag_public o r v1.2.3 2>/dev/null)" == "${GOOD_SHA}" ]] \
    && [[ "$(workbench_resolve_branch_public o r main 2>/dev/null)" == "${GOOD_SHA}" ]]; then
    ok "a 40-hex sha from the API resolves (latest, tag, branch)"
else
    fail "a good sha was not resolved"
fi

_bad_accepted=""
for _stub_sha in "../../etc" "0123456789ABCDEF0123456789ABCDEF01234567" \
                 "0123456789abcdef" "${GOOD_SHA}x" "x${GOOD_SHA}"; do
    workbench_resolve_latest_tag_public o r >/dev/null 2>&1 && _bad_accepted="${_bad_accepted} latest:${_stub_sha}"
    workbench_resolve_tag_public o r v1.2.3 >/dev/null 2>&1 && _bad_accepted="${_bad_accepted} tag:${_stub_sha}"
    workbench_resolve_branch_public o r main >/dev/null 2>&1 && _bad_accepted="${_bad_accepted} branch:${_stub_sha}"
done
for _pin in "../x" "0123456789ABCDEF" "abc"; do
    if workbench_resolve_commit_public o r "${_pin}" >/dev/null 2>&1; then
        _bad_accepted="${_bad_accepted} commit:${_pin}"
    fi
done
if [[ -z "${_bad_accepted}" ]]; then
    ok "a non-hex, short, uppercase or padded sha is refused (latest, tag, branch, commit pin)"
else
    fail "non-hex sha accepted:${_bad_accepted}"
fi

# A commit: pin may be abbreviated, as `wb track --commit` allows (7-40 hex).
_stub_sha="${GOOD_SHA}"
if [[ "$(workbench_resolve_commit_public o r "${GOOD_SHA:0:7}" 2>/dev/null)" == "${GOOD_SHA:0:7}" ]] \
    && [[ "$(workbench_resolve_commit_public o r "${GOOD_SHA}" 2>/dev/null)" == "${GOOD_SHA}" ]]; then
    ok "an abbreviated (7-hex) and a full commit: pin both resolve"
else
    fail "a valid commit: pin (abbreviated or full) was refused"
fi
_pin_err="$(workbench_resolve_commit_public o r "../x" 2>&1 >/dev/null)"
if [[ "${_pin_err}" == *"refusing it"* ]]; then
    ok "a refused commit: pin is logged, not silent"
else
    fail "a refused commit: pin produced no error"
fi

# bootstrap.sh: a fake curl first on PATH serves a tag whose sha is not
# hex. bootstrap must stop before fetching anything or creating a snapshot.
FAKE_BIN="${WORK}/fakebin"
mkdir -p "${FAKE_BIN}"
cat > "${FAKE_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do
    case "${a}" in
        *codeload*) echo "fetched" >> "${FAKE_CURL_LOG}"; exit 1 ;;
        *api.github.com*/tags*) printf '[{"name": "v9.9.9", "commit": {"sha": "../../../tmp/evil", "url": "x"}}]'; exit 0 ;;
    esac
done
exit 1
FAKE
chmod +x "${FAKE_BIN}/curl"
BOOT_HOME="${WORK}/boot-home"
mkdir -p "${BOOT_HOME}"
FAKE_CURL_LOG="${WORK}/fake-curl.log" HOME="${BOOT_HOME}" XDG_DATA_HOME="${BOOT_HOME}/.local/share" \
    PATH="${FAKE_BIN}:${PATH}" bash "${REPO_ROOT}/bootstrap.sh" </dev/null >"${WORK}/boot.log" 2>&1
boot_rc=$?
if [[ "${boot_rc}" -ne 0 ]] && grep -q "not a commit sha" "${WORK}/boot.log" \
    && [[ ! -e "${WORK}/fake-curl.log" ]] \
    && [[ ! -d "${BOOT_HOME}/.local/share/workbench/modules/core/snapshots" ]]; then
    ok "bootstrap.sh refuses a non-hex sha before fetching or creating a snapshot"
else
    fail "bootstrap.sh with a non-hex sha: rc ${boot_rc}, fetched: $(cat "${WORK}/fake-curl.log" 2>/dev/null)"
    cat "${WORK}/boot.log"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
