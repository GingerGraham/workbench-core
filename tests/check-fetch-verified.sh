#!/usr/bin/env bash
# tests/check-fetch-verified.sh — acceptance check for the WP1 download
# hygiene and verified-fetch helpers in lib/core/installers-common.sh
# (security review M2/M3; docs/decisions-log.md D74).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/core/log.sh
source "${REPO_ROOT}/lib/core/log.sh"
# shellcheck source=lib/core/installers-common.sh
source "${REPO_ROOT}/lib/core/installers-common.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export _WB_TEST_FETCH_PROTO=file

sha256_of() { _wb_sha256 "$1"; }

# ── Check 1: literal hash match ─────────────────────────────────────────────
printf 'hello world\n' > "${WORK}/1-src"
h1="$(sha256_of "${WORK}/1-src")"
if _wb_fetch_verified "file://${WORK}/1-src" "${WORK}/1-dest" "${h1}" >/tmp/wb-fetch-1.log 2>&1 \
   && cmp -s "${WORK}/1-src" "${WORK}/1-dest"; then
    ok "literal hash match: dest created, byte-identical to the fixture"
else
    fail "literal hash match failed — see /tmp/wb-fetch-1.log"
fi

# ── Check 2: literal hash mismatch ──────────────────────────────────────────
if _wb_fetch_verified "file://${WORK}/1-src" "${WORK}/2-dest" \
    "0000000000000000000000000000000000000000000000000000000000000000" >/dev/null 2>&1; then
    fail "literal hash mismatch: unexpectedly succeeded"
else
    if [[ ! -e "${WORK}/2-dest" ]]; then
        ok "literal hash mismatch: non-zero, dest does not exist"
    else
        fail "literal hash mismatch: dest exists despite mismatch"
    fi
fi

# ── Check 3: sums: with "<hex>  <name>" ─────────────────────────────────────
printf 'sums-payload-a\n' > "${WORK}/3-src"
h3="$(sha256_of "${WORK}/3-src")"
printf '%s  3-src\n' "${h3}" > "${WORK}/3-sums"
if _wb_fetch_verified "file://${WORK}/3-src" "${WORK}/3-dest" "sums:file://${WORK}/3-sums" "3-src" >/tmp/wb-fetch-3.log 2>&1 \
   && cmp -s "${WORK}/3-src" "${WORK}/3-dest"; then
    ok "sums: with '<hex>  <name>' line succeeds"
else
    fail "sums: with '<hex>  <name>' line failed — see /tmp/wb-fetch-3.log"
fi

# ── Check 4: sums: with "<hex> *<name>" ─────────────────────────────────────
printf 'sums-payload-b\n' > "${WORK}/4-src"
h4="$(sha256_of "${WORK}/4-src")"
printf '%s *4-src\n' "${h4}" > "${WORK}/4-sums"
if _wb_fetch_verified "file://${WORK}/4-src" "${WORK}/4-dest" "sums:file://${WORK}/4-sums" "4-src" >/tmp/wb-fetch-4.log 2>&1 \
   && cmp -s "${WORK}/4-src" "${WORK}/4-dest"; then
    ok "sums: with '<hex> *<name>' line succeeds"
else
    fail "sums: with '<hex> *<name>' line failed — see /tmp/wb-fetch-4.log"
fi

# ── Check 5: sums: asset absent from the file ───────────────────────────────
printf 'sums-payload-c\n' > "${WORK}/5-src"
printf 'deadbeef  some-other-name\n' > "${WORK}/5-sums"
if _wb_fetch_verified "file://${WORK}/5-src" "${WORK}/5-dest" "sums:file://${WORK}/5-sums" "5-src" >/dev/null 2>&1; then
    fail "sums: asset absent from the file — unexpectedly succeeded"
else
    if [[ ! -e "${WORK}/5-dest" ]]; then
        ok "sums: asset absent from the file — non-zero, no dest"
    else
        fail "sums: asset absent from the file — dest exists"
    fi
fi

# ── Check 6: hashfile: ──────────────────────────────────────────────────────
printf 'hashfile-payload\n' > "${WORK}/6-src"
h6="$(sha256_of "${WORK}/6-src")"
printf '%s  6-src\n' "${h6}" > "${WORK}/6-hash"
if _wb_fetch_verified "file://${WORK}/6-src" "${WORK}/6-dest" "hashfile:file://${WORK}/6-hash" >/tmp/wb-fetch-6.log 2>&1 \
   && cmp -s "${WORK}/6-src" "${WORK}/6-dest"; then
    ok "hashfile: succeeds"
else
    fail "hashfile: failed — see /tmp/wb-fetch-6.log"
fi

# ── Check 7: _download_file_robust never resumes onto an existing dest ─────
printf 'this-is-a-much-longer-existing-payload-than-the-new-one\n' > "${WORK}/7-dest"
printf 'new\n' > "${WORK}/7-src-new"
if _download_file_robust "file://${WORK}/7-src-new" "${WORK}/7-dest" >/tmp/wb-fetch-7a.log 2>&1 \
   && cmp -s "${WORK}/7-src-new" "${WORK}/7-dest"; then
    ok "_download_file_robust over an existing, longer dest replaces it exactly"
else
    fail "_download_file_robust over an existing, longer dest failed — see /tmp/wb-fetch-7a.log"
fi

printf 'x\n' > "${WORK}/7b-dest"
printf 'a-much-longer-new-payload-than-the-short-existing-one\n' > "${WORK}/7b-src-new"
if _download_file_robust "file://${WORK}/7b-src-new" "${WORK}/7b-dest" >/tmp/wb-fetch-7b.log 2>&1 \
   && cmp -s "${WORK}/7b-src-new" "${WORK}/7b-dest"; then
    ok "_download_file_robust over an existing, shorter dest replaces it exactly"
else
    fail "_download_file_robust over an existing, shorter dest failed — see /tmp/wb-fetch-7b.log"
fi

# ── Check 8: default protocol refuses file:// ───────────────────────────────
(
    unset _WB_TEST_FETCH_PROTO
    _download_file_robust "file://${WORK}/1-src" "${WORK}/8-dest"
)
if [[ ! -e "${WORK}/8-dest" ]]; then
    ok "default protocol (https-only) refuses a file:// URL"
else
    fail "default protocol unexpectedly accepted a file:// URL"
fi

# ── Check 9: missing source URL leaves dest untouched, no temp file left ───
printf 'pre-existing\n' > "${WORK}/9-dest"
_download_file_robust "file://${WORK}/does-not-exist" "${WORK}/9-dest" >/dev/null 2>&1
rc=$?
leftover="$(find "${WORK}" -maxdepth 1 -name '.wb-download.*' 2>/dev/null)"
if [[ ${rc} -ne 0 ]] && grep -q '^pre-existing$' "${WORK}/9-dest" && [[ -z "${leftover}" ]]; then
    ok "missing source URL: non-zero, pre-existing dest unchanged, no temp file left"
else
    fail "missing source URL: rc=${rc}, dest=$(cat "${WORK}/9-dest" 2>/dev/null), leftover='${leftover}'"
fi

# ── Check 10: _wb_gh_asset_digest ───────────────────────────────────────────
cat > "${WORK}/10-releases.json" <<'EOF'
{
  "assets": [
    {
      "name": "tool_linux_amd64",
      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "browser_download_url": "https://example.invalid/tool_linux_amd64"
    },
    {
      "name": "tool_darwin_amd64",
      "digest": null,
      "browser_download_url": "https://example.invalid/tool_darwin_amd64"
    }
  ]
}
EOF
json10="$(cat "${WORK}/10-releases.json")"
d1="$(_wb_gh_asset_digest "${json10}" "https://example.invalid/tool_linux_amd64")"
d2="$(_wb_gh_asset_digest "${json10}" "https://example.invalid/tool_darwin_amd64")"
if [[ "${d1}" == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" && -z "${d2}" ]]; then
    ok "_wb_gh_asset_digest: correct hex for a digest-bearing asset, empty for a null digest"
else
    fail "_wb_gh_asset_digest: got '${d1}' / '${d2}'"
fi

# ── Check 11: _wb_key_has_fingerprint ───────────────────────────────────────
if ! command -v gpg &>/dev/null; then
    ok "gpg not on PATH — skipping _wb_key_has_fingerprint checks"
else
    GNUPGHOME_TEST="$(mktemp -d)"
    export GNUPGHOME="${GNUPGHOME_TEST}"
    chmod 700 "${GNUPGHOME_TEST}"
    if gpg --batch --passphrase '' --quick-gen-key test@example.invalid default default never >/tmp/wb-fetch-gpg-gen.log 2>&1; then
        fpr="$(gpg --with-colons --list-keys test@example.invalid 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')"
        gpg --batch --armor --export test@example.invalid > "${WORK}/11-key.asc" 2>/dev/null
        unset GNUPGHOME
        rm -rf "${GNUPGHOME_TEST}"

        if _wb_key_has_fingerprint "${WORK}/11-key.asc" "${fpr}"; then
            ok "_wb_key_has_fingerprint: true for the correct fingerprint"
        else
            fail "_wb_key_has_fingerprint: expected true for the correct fingerprint"
        fi

        spaced="$(printf '%s' "${fpr}" | sed -E 's/(..)/\1 /g')"
        lowered="$(printf '%s' "${fpr}" | tr '[:upper:]' '[:lower:]')"
        if _wb_key_has_fingerprint "${WORK}/11-key.asc" "${spaced}" && _wb_key_has_fingerprint "${WORK}/11-key.asc" "${lowered}"; then
            ok "_wb_key_has_fingerprint: true with spaces and with lowercase"
        else
            fail "_wb_key_has_fingerprint: spaced/lowercase form not accepted"
        fi

        if _wb_key_has_fingerprint "${WORK}/11-key.asc" "0000000000000000000000000000000000000000"; then
            fail "_wb_key_has_fingerprint: unexpectedly true for a different fingerprint"
        else
            ok "_wb_key_has_fingerprint: false for a different fingerprint"
        fi
    else
        unset GNUPGHOME
        rm -rf "${GNUPGHOME_TEST}"
        ok "gpg key generation unavailable in this environment — skipping _wb_key_has_fingerprint checks (see /tmp/wb-fetch-gpg-gen.log)"
    fi
fi

# ── zsh: re-run checks 1 and 10 under zsh if available ──────────────────────
if command -v zsh &>/dev/null; then
    # shellcheck disable=SC2097,SC2098
    zsh_out="$(REPO_ROOT="${REPO_ROOT}" WORK="${WORK}" H1="${h1}" JSON10_FILE="${WORK}/10-releases.json" \
        zsh -c '
        source "${REPO_ROOT}/lib/core/log.sh"
        source "${REPO_ROOT}/lib/core/installers-common.sh"
        export _WB_TEST_FETCH_PROTO=file
        _wb_fetch_verified "file://${WORK}/1-src" "${WORK}/zsh-1-dest" "${H1}" \
            && cmp -s "${WORK}/1-src" "${WORK}/zsh-1-dest" \
            && echo ZSH_CHECK1_OK
        json="$(cat "${JSON10_FILE}")"
        d="$(_wb_gh_asset_digest "${json}" "https://example.invalid/tool_linux_amd64")"
        [[ "${d}" == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]] && echo ZSH_CHECK10_OK
    ' 2>/tmp/wb-fetch-zsh.log)"
    if grep -q ZSH_CHECK1_OK <<<"${zsh_out}"; then
        ok "check 1 (literal hash match) also passes under zsh"
    else
        fail "check 1 failed under zsh — see /tmp/wb-fetch-zsh.log"
    fi
    if grep -q ZSH_CHECK10_OK <<<"${zsh_out}"; then
        ok "check 10 (_wb_gh_asset_digest) also passes under zsh"
    else
        fail "check 10 failed under zsh — see /tmp/wb-fetch-zsh.log"
    fi
else
    ok "zsh not on PATH — skipping the zsh re-run of checks 1 and 10"
fi

echo
echo "==============================="
echo "Checks run: ${check_no}"
echo "Failed:     ${FAILED}"
echo "==============================="

[[ ${FAILED} -eq 0 ]]
