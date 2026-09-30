#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $basearch / single-quoted bash -c body are intentional
# tests/check-vendor-key-trust.sh — acceptance check for the pinned vendor
# key helpers in lib/core/installers-common.sh (security review follow-up
# R1/R2; docs/decisions-log.md D79; Core API 1.5).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

if ! command -v gpg &>/dev/null; then
    ok "gpg not available — skipping all vendor-key-trust checks"
    exit 0
fi
if [[ "$(uname -s)" == "Darwin" ]]; then
    ok "macOS — skipping rpm/apt vendor-key-trust checks (Linux-only helpers)"
    exit 0
fi

# shellcheck source=lib/core/log.sh
source "${REPO_ROOT}/lib/core/log.sh"
# shellcheck source=lib/core/installers-common.sh
source "${REPO_ROOT}/lib/core/installers-common.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── Fixtures: three throwaway keys A, B, C ───────────────────────────────────
KEYS="${WORK}/keys"
mkdir -p "${KEYS}" "${WORK}/bin"
fpr_of() {
    GNUPGHOME="${WORK}/gh-$1" gpg --batch --with-colons --list-keys 2>/dev/null \
        | awk -F: 'previous == "pub" && $1 == "fpr" { print $10; exit } { previous = $1 }'
}
for k in a b c; do
    mkdir -p "${WORK}/gh-${k}"; chmod 700 "${WORK}/gh-${k}"
    GNUPGHOME="${WORK}/gh-${k}" gpg --batch --passphrase '' \
        --quick-gen-key "key-${k} <${k}@example.invalid>" default default never >"${WORK}/gen-${k}.log" 2>&1
done
FPR_A="$(fpr_of a)"; FPR_B="$(fpr_of b)"; FPR_C="$(fpr_of c)"
if [[ -z "${FPR_A}" || -z "${FPR_B}" || -z "${FPR_C}" ]]; then
    ok "gpg key generation unavailable in this environment — skipping (see ${WORK}/gen-a.log)"
    exit 0
fi
GNUPGHOME="${WORK}/gh-a" gpg --batch --armor --export "${FPR_A}" > "${KEYS}/a.asc"
GNUPGHOME="${WORK}/gh-c" gpg --batch --armor --export "${FPR_C}" > "${KEYS}/c.asc"
{ GNUPGHOME="${WORK}/gh-a" gpg --batch --armor --export "${FPR_A}"
  GNUPGHOME="${WORK}/gh-b" gpg --batch --armor --export "${FPR_B}"; } > "${KEYS}/ab.asc"
{ GNUPGHOME="${WORK}/gh-a" gpg --batch --export "${FPR_A}"
  GNUPGHOME="${WORK}/gh-b" gpg --batch --export "${FPR_B}"; } > "${KEYS}/ab.gpg"

# Primary-key fingerprints inside a key file (one per line).
fprs_in() { gpg --show-keys --with-colons "$1" 2>/dev/null \
    | awk -F: 'previous == "pub" && $1 == "fpr" { print $10 } { previous = $1 }'; }

# ── Stubs and shims ──────────────────────────────────────────────────────────
get-elevation-command() { printf '\n' | tr -d '\n'; }
export -f get-elevation-command 2>/dev/null || true
RPM_LOG="${WORK}/rpm.log"
printf '#!/usr/bin/env bash\necho "$@" >> "%s"\n' "${RPM_LOG}" > "${WORK}/bin/rpm"
# curl shim: copies KEYS/<last URL segment> to the --output path.
cat > "${WORK}/bin/curl" <<SHIM
#!/usr/bin/env bash
out=""; url=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --output) out="\$2"; shift 2 ;;
        --*) shift ;;
        *) url="\$1"; shift ;;
    esac
done
cp "${KEYS}/\${url##*/}" "\${out}"
SHIM
chmod +x "${WORK}/bin/rpm" "${WORK}/bin/curl"
export PATH="${WORK}/bin:${PATH}"
export _WB_TEST_SYSROOT="${WORK}/root"
export _WB_TEST_FETCH_PROTO="=file"

# ── 1. armor extract, A pinned from ab.asc ───────────────────────────────────
out1="${WORK}/out1.asc"
msg1="$(_wb_key_extract_pinned "${KEYS}/ab.asc" "${out1}" armor "${FPR_A}" 2>&1)"; rc=$?
if [[ ${rc} -eq 0 && "$(fprs_in "${out1}")" == "${FPR_A}" && "${msg1}" == *"${FPR_B}"* ]]; then
    ok "extract A from ab.asc: only A kept, warning names B"
else
    fail "extract A from ab.asc: rc=${rc} keys=[$(fprs_in "${out1}" | tr '\n' ' ')] msg=[${msg1}]"
fi

# ── 2. binary in / binary out ────────────────────────────────────────────────
out2="${WORK}/out2.gpg"
_wb_key_extract_pinned "${KEYS}/ab.gpg" "${out2}" binary "${FPR_A}" >/dev/null 2>&1; rc=$?
if [[ ${rc} -eq 0 ]] && ! grep -q -- '-----BEGIN' "${out2}" && [[ "$(fprs_in "${out2}")" == "${FPR_A}" ]]; then
    ok "binary extract: output is binary and contains only A"
else
    fail "binary extract: rc=${rc} keys=[$(fprs_in "${out2}" | tr '\n' ' ')]"
fi

# ── 3. none pinned ───────────────────────────────────────────────────────────
out3="${WORK}/out3.asc"
if _wb_key_extract_pinned "${KEYS}/c.asc" "${out3}" armor "${FPR_A}" >/dev/null 2>&1; then
    fail "extract A from c.asc: unexpectedly succeeded"
elif [[ -e "${out3}" ]]; then
    fail "extract A from c.asc: failed but left an output file"
else
    ok "extract A from c.asc: fails, no output file"
fi

# ── 4. two pinned ────────────────────────────────────────────────────────────
out4="${WORK}/out4.asc"
msg4="$(_wb_key_extract_pinned "${KEYS}/ab.asc" "${out4}" armor "${FPR_A}" "${FPR_B}" 2>&1)"; rc=$?
if [[ ${rc} -eq 0 && "$(fprs_in "${out4}" | wc -l | tr -d ' ')" == "2" && "${msg4}" != *"ignoring"* ]]; then
    ok "extract A and B: both kept, no warning"
else
    fail "extract A and B: rc=${rc} msg=[${msg4}]"
fi

# ── 5. lowercase + spaces ────────────────────────────────────────────────────
out5="${WORK}/out5.asc"
spaced="$(printf '%s' "${FPR_A}" | tr '[:upper:]' '[:lower:]' | sed 's/\(....\)/\1 /g; s/ $//')"
if _wb_key_extract_pinned "${KEYS}/ab.asc" "${out5}" armor "${spaced}" >/dev/null 2>&1 \
   && [[ "$(fprs_in "${out5}")" == "${FPR_A}" ]]; then
    ok "lowercase, space-separated fingerprint still matches"
else
    fail "lowercase/spaced fingerprint did not match"
fi

# ── 6. rpm import ────────────────────────────────────────────────────────────
# The helper requires an https:// key URL; the curl shim serves the fixture.
: > "${RPM_LOG}"
printed="$(_wb_rpm_import_pinned_key https://example.invalid/ab.asc vendor-x "${FPR_A}" 2>/dev/null)"; rc=$?
inst="${_WB_TEST_SYSROOT}/etc/pki/rpm-gpg/RPM-GPG-KEY-workbench-vendor-x"
if [[ ${rc} -eq 0 && "${printed}" == "/etc/pki/rpm-gpg/RPM-GPG-KEY-workbench-vendor-x" \
      && "$(fprs_in "${inst}")" == "${FPR_A}" ]] \
   && grep -q -- "--import ${inst}" "${RPM_LOG}"; then
    ok "rpm import: prints path, installed file holds only A, rpm --import got that path"
else
    fail "rpm import: rc=${rc} printed=[${printed}] rpm=[$(cat "${RPM_LOG}")]"
fi

# ── 7. bad names ─────────────────────────────────────────────────────────────
_wb_rpm_import_pinned_key https://example.invalid/ab.asc '../x' "${FPR_A}" >/dev/null 2>&1; rc1=$?
_wb_rpm_import_pinned_key https://example.invalid/ab.asc 'X' "${FPR_A}" >/dev/null 2>&1; rc2=$?
if [[ ${rc1} -eq 2 && ${rc2} -eq 2 ]]; then
    ok "rpm import rejects names '../x' and 'X' with 2"
else
    fail "rpm import bad names: rc=${rc1}/${rc2}, want 2/2"
fi

# ── 8. dnf vendor repo ───────────────────────────────────────────────────────
_wb_dnf_vendor_repo --id vendor-x --name "Vendor X" --baseurl 'https://example.invalid/rpm/$basearch' \
    --key-url "file://${KEYS}/ab.asc" --fingerprint "${FPR_A}" --include pkg-a >/dev/null 2>&1; rc=$?
if [[ ${rc} -eq 2 ]]; then
    ok "dnf repo: file:// key URL rejected with 2"
else
    fail "dnf repo: file:// key URL returned ${rc}, want 2"
fi
_wb_dnf_vendor_repo --id vendor-x --name "Vendor X" --baseurl 'https://example.invalid/rpm/$basearch' \
    --key-url https://example.invalid/ab.asc --fingerprint "${FPR_A}" \
    --include pkg-a --include pkg-b >/dev/null 2>"${WORK}/dnf.err"; rc=$?
repo="${_WB_TEST_SYSROOT}/etc/yum.repos.d/vendor-x.repo"
if [[ ${rc} -eq 0 ]] \
   && grep -qxF 'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-workbench-vendor-x' "${repo}" \
   && grep -qxF 'includepkgs=pkg-a pkg-b' "${repo}" \
   && grep -qF 'baseurl=https://example.invalid/rpm/$basearch' "${repo}" \
   && grep -qxF 'gpgcheck=1' "${repo}"; then
    ok "dnf repo: local pinned gpgkey, includepkgs, literal \$basearch, gpgcheck=1"
else
    fail "dnf repo: rc=${rc}, err: $(cat "${WORK}/dnf.err")"
fi

# ── 9. dnf argument validation, never loops ──────────────────────────────────
common=(--id vendor-y --name "Y" --baseurl 'https://example.invalid/r' --key-url https://example.invalid/ab.asc)
bad_ok=1
run_bad() {
    timeout 10 bash -c '
        source "$1/lib/core/log.sh"; source "$1/lib/core/installers-common.sh"
        shift; _wb_dnf_vendor_repo "$@"' _ "${REPO_ROOT}" "$@" >/dev/null 2>&1
}
run_bad "${common[@]}" --fingerprint "${FPR_A}"; [[ $? -eq 2 ]] || bad_ok=0          # no --include
run_bad "${common[@]}" --include pkg;            [[ $? -eq 2 ]] || bad_ok=0          # no --fingerprint
run_bad "${common[@]}" --fingerprint "${FPR_A}" --include pkg --bogus x; [[ $? -eq 2 ]] || bad_ok=0
run_bad "${common[@]}" --fingerprint "${FPR_A}" --include pkg --include;  [[ $? -eq 2 ]] || bad_ok=0
if [[ ${bad_ok} -eq 1 ]]; then
    ok "dnf repo: missing --include/--fingerprint, unknown option, trailing valueless option all return 2 (no hang)"
else
    fail "dnf repo: an argument-validation case did not return 2 within 10s"
fi

# ── 10. apt keyring ──────────────────────────────────────────────────────────
_wb_apt_keyring_pinned https://example.invalid/ab.asc '/etc/apt/keyrings/../x.gpg' "${FPR_A}" >/dev/null 2>&1; rc1=$?
_wb_apt_keyring_pinned https://example.invalid/ab.asc '/tmp/x.gpg' "${FPR_A}" >/dev/null 2>&1; rc2=$?
_wb_apt_keyring_pinned https://example.invalid/ab.asc /etc/apt/keyrings/vendor.gpg "${FPR_A}" >/dev/null 2>&1; rc3=$?
kr="${_WB_TEST_SYSROOT}/etc/apt/keyrings/vendor.gpg"
if [[ ${rc1} -eq 2 && ${rc2} -eq 2 && ${rc3} -eq 0 ]] \
   && ! grep -q -- '-----BEGIN' "${kr}" && [[ "$(fprs_in "${kr}")" == "${FPR_A}" ]]; then
    ok "apt keyring: bad paths return 2; good path installs a binary keyring holding only A"
else
    fail "apt keyring: rc=${rc1}/${rc2}/${rc3} keys=[$(fprs_in "${kr}" 2>/dev/null | tr '\n' ' ')]"
fi

# ── 11. zsh: checks 1 and 8 again ────────────────────────────────────────────
if command -v zsh &>/dev/null; then
    export FPR_A KEYS WORK REPO_ROOT
    zsh_out="$(_WB_TEST_SYSROOT="${WORK}/zroot" \
        zsh -c '
        source "${REPO_ROOT}/lib/core/log.sh"
        source "${REPO_ROOT}/lib/core/installers-common.sh"
        get-elevation-command() { :; }
        _wb_key_extract_pinned "${KEYS}/ab.asc" "${WORK}/zsh-out.asc" armor "${FPR_A}" 2>/dev/null \
            && [[ "$(gpg --show-keys --with-colons "${WORK}/zsh-out.asc" 2>/dev/null | grep -c "^pub:")" == 1 ]] \
            && echo ZSH_1_OK
        _wb_dnf_vendor_repo --id vendor-z --name Z --baseurl "https://example.invalid/rpm/\$basearch" \
            --key-url https://example.invalid/ab.asc --fingerprint "${FPR_A}" --include pkg-a >/dev/null 2>&1 \
            && grep -qxF "includepkgs=pkg-a" "${_WB_TEST_SYSROOT}/etc/yum.repos.d/vendor-z.repo" \
            && echo ZSH_8_OK
    ' 2>"${WORK}/zsh.log")"
    if grep -q ZSH_1_OK <<<"${zsh_out}" && grep -q ZSH_8_OK <<<"${zsh_out}"; then
        ok "checks 1 and 8 also pass under zsh"
    else
        fail "zsh run failed: [${zsh_out}] $(cat "${WORK}/zsh.log")"
    fi
else
    ok "zsh not available — skipping zsh re-run of checks 1 and 8"
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
