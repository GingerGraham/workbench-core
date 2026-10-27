#!/usr/bin/env bash
# tests/check-github-token.sh — docs/decisions-log.md D99 acceptance check
# for WORKBENCH_GITHUB_TOKEN in lib/distribution/resolve.sh's _wb_gh_curl
# and bootstrap.sh's _gh_curl.
#
# The token goes only to https://api.github.com/, reaches curl on stdin
# (a config line), never on its argument list, and is never written to a
# file. A fake curl first on PATH records its arguments and stdin. Offline.
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

TOKEN="ghs_TestToken0123456789abcdefABCDEF"
GOOD_SHA="0123456789abcdef0123456789abcdef01234567"

# The fake curl appends one record per call to ${FAKE_CURL_LOG}:
#   ARGS: <every argument>
#   STDIN: <stdin, when --config - was passed>
# and answers the tags and commits endpoints with a fixed body.
FAKE_BIN="${WORK}/fakebin"
mkdir -p "${FAKE_BIN}"
cat > "${FAKE_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*" >> "${FAKE_CURL_LOG}"
for a in "$@"; do
    if [[ "${a}" == "-" ]]; then
        printf 'STDIN: %s\n' "$(cat)" >> "${FAKE_CURL_LOG}"
    fi
done
for a in "$@"; do
    case "${a}" in
        *codeload*) exit 1 ;;
        https://api.github.com/*/tags*) printf '[{"name": "v9.9.9", "commit": {"sha": "%s", "url": "x"}}]' "${FAKE_SHA}"; exit 0 ;;
        https://api.github.com/*/commits/*) printf '{"sha": "%s"}' "${FAKE_SHA}"; exit 0 ;;
    esac
done
exit 0
FAKE
chmod +x "${FAKE_BIN}/curl"
export FAKE_SHA="${GOOD_SHA}"
export PATH="${FAKE_BIN}:${PATH}"

# shellcheck source=lib/core/log.sh
source "${REPO_ROOT}/lib/core/log.sh"
# shellcheck source=lib/core/semver.sh
source "${REPO_ROOT}/lib/core/semver.sh"
# shellcheck source=lib/distribution/resolve.sh
source "${REPO_ROOT}/lib/distribution/resolve.sh"

# run_gh_curl <log-name> <url> — one _wb_gh_curl call, logged to its own file.
run_gh_curl() {
    FAKE_CURL_LOG="${WORK}/$1.log" _wb_gh_curl "$2" >/dev/null 2>"${WORK}/$1.err"
}

# ── 1-2. Token set, api.github.com: on stdin, not in the arguments. ────────
WORKBENCH_GITHUB_TOKEN="${TOKEN}" run_gh_curl api "https://api.github.com/repos/o/r/tags?per_page=100"
if grep -q "^STDIN: header = \"Authorization: Bearer ${TOKEN}\"$" "${WORK}/api.log"; then
    ok "_wb_gh_curl sends the token to api.github.com as a config line on stdin"
else
    fail "_wb_gh_curl did not send the token on stdin to api.github.com"
    cat "${WORK}/api.log"
fi
if grep '^ARGS:' "${WORK}/api.log" | grep -qF "${TOKEN}"; then
    fail "_wb_gh_curl put the token on curl's argument list"
else
    ok "the token never appears in curl's arguments"
fi

# ── 3. Token set, any other host or scheme: never sent. ────────────────────
leaked=""
for url in "https://codeload.github.com/o/r/tar.gz/${GOOD_SHA}" \
           "https://github.com/o/r" \
           "http://api.github.com/repos/o/r/tags" \
           "https://api.github.com.evil.example/repos/o/r" \
           "https://evil.example/https://api.github.com/"; do
    WORKBENCH_GITHUB_TOKEN="${TOKEN}" run_gh_curl other "${url}"
    grep -qF "${TOKEN}" "${WORK}/other.log" && leaked="${leaked} ${url}"
    rm -f "${WORK}/other.log"
done
if [[ -z "${leaked}" ]]; then
    ok "the token is never sent anywhere but https://api.github.com/"
else
    fail "the token was sent to:${leaked}"
fi

# ── 4. No token: no --config, no Authorization. ────────────────────────────
WORKBENCH_GITHUB_TOKEN="" run_gh_curl none "https://api.github.com/repos/o/r/tags"
if ! grep -q -- '--config' "${WORK}/none.log" && ! grep -q 'Authorization' "${WORK}/none.log"; then
    ok "with WORKBENCH_GITHUB_TOKEN empty, requests are unauthenticated"
else
    fail "an empty token still produced an authenticated request"
    cat "${WORK}/none.log"
fi

# ── 5. A token that could break out of the config line is not sent. ────────
WORKBENCH_GITHUB_TOKEN='abc" -o /tmp/x "' run_gh_curl bad "https://api.github.com/repos/o/r/tags"
if ! grep -q 'Authorization' "${WORK}/bad.log" && grep -q 'not sending it' "${WORK}/bad.err"; then
    ok "a token with quotes or spaces is refused with a warning, never sent"
else
    fail "a malformed token was sent, or no warning was printed"
    cat "${WORK}/bad.log" "${WORK}/bad.err"
fi

# ── 6. The resolvers still work through the authenticated path. ────────────
if [[ "$(FAKE_CURL_LOG="${WORK}/resolve.log" WORKBENCH_GITHUB_TOKEN="${TOKEN}" \
        workbench_resolve_latest_tag_public o r 2>/dev/null)" == "v9.9.9|${GOOD_SHA}" ]]; then
    ok "workbench_resolve_latest_tag_public resolves with the token set"
else
    fail "workbench_resolve_latest_tag_public failed with the token set"
fi

# ── 7-9. bootstrap.sh: token to the API on stdin, never to codeload. ───────
# The fake codeload fetch fails, so bootstrap stops after resolving; that's
# all this needs.
BOOT_HOME="${WORK}/boot-home"
mkdir -p "${BOOT_HOME}"
FAKE_CURL_LOG="${WORK}/boot-curl.log" WORKBENCH_GITHUB_TOKEN="${TOKEN}" \
    HOME="${BOOT_HOME}" XDG_DATA_HOME="${BOOT_HOME}/.local/share" \
    bash "${REPO_ROOT}/bootstrap.sh" </dev/null >"${WORK}/boot.out" 2>&1
if grep -q "^STDIN: header = \"Authorization: Bearer ${TOKEN}\"$" "${WORK}/boot-curl.log"; then
    ok "bootstrap.sh sends the token to the API on stdin"
else
    fail "bootstrap.sh did not send the token to the API"
    cat "${WORK}/boot-curl.log" "${WORK}/boot.out"
fi
if grep '^ARGS:' "${WORK}/boot-curl.log" | grep -qF "${TOKEN}"; then
    fail "bootstrap.sh put the token on curl's argument list"
else
    ok "bootstrap.sh never puts the token in curl's arguments"
fi
codeload_lines="$(grep -n 'codeload' "${WORK}/boot-curl.log" | cut -d: -f1)"
codeload_leak=""
for n in ${codeload_lines}; do
    # The record after a codeload ARGS line would be its STDIN, if any.
    next="$(sed -n "$((n + 1))p" "${WORK}/boot-curl.log")"
    case "${next}" in STDIN:*) codeload_leak="yes" ;; esac
done
if [[ -n "${codeload_lines}" && -z "${codeload_leak}" ]] \
    && ! grep 'codeload' "${WORK}/boot-curl.log" | grep -qF -- '--config'; then
    ok "bootstrap.sh's codeload download carries no token"
else
    fail "bootstrap.sh's codeload download carried the token, or never ran"
    cat "${WORK}/boot-curl.log"
fi

# ── 10. Nothing under HOME or XDG_* holds the token. ───────────────────────
if grep -rqF "${TOKEN}" "${HOME}" "${XDG_DATA_HOME}" "${XDG_CONFIG_HOME}" "${BOOT_HOME}" 2>/dev/null; then
    fail "the token was written to a file: $(grep -rlF "${TOKEN}" "${HOME}" "${XDG_DATA_HOME}" "${XDG_CONFIG_HOME}" "${BOOT_HOME}" 2>/dev/null)"
else
    ok "the token is not written to any file under HOME or XDG_*"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
