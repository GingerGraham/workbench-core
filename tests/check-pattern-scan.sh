#!/usr/bin/env bash
# tests/check-pattern-scan.sh — acceptance check for
# .github/actions/scan-patterns/pattern-scan.sh and its rules file
# (security review M3; WP9 extends dangerous-patterns.txt with 8 new
# patterns). Runs the real script against a throwaway git repo built with
# one positive and one negative case per new pattern, plus a
# pattern-scan:ignore suppression case and a regression case for the
# --allow-unsigned-rpm-style patterns (git grep mis-parses any pattern
# starting with '-' unless passed via -e; that bug meant those three
# patterns never matched anything, ever, until fixed here).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCAN_SCRIPT="${REPO_ROOT}/.github/actions/scan-patterns/pattern-scan.sh"
RULES_FILE="${REPO_ROOT}/.github/actions/scan-patterns/dangerous-patterns.txt"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

cd "${WORK}" || exit 1
git init -q
git config user.email t@t.com
git config user.name Test

mkdir -p shell

# ── Positive cases: one per new pattern ─────────────────────────────────────
cat > shell/pos-process-sub.sh <<'EOF'
#!/usr/bin/env bash
bash <(curl -s https://example.invalid/install.sh)
EOF

cat > shell/pos-command-sub.sh <<'EOF'
#!/usr/bin/env bash
sh -c "$(curl -fsSL https://example.invalid/install.sh)"
EOF

cat > shell/pos-env-pipe.sh <<'EOF'
#!/usr/bin/env bash
curl -s https://example.invalid/install.sh | env FOO=bar sh
EOF

cat > shell/pos-unsigned-rpm.sh <<'EOF'
#!/usr/bin/env bash
zypper install --allow-unsigned-rpm somepkg.rpm
EOF

cat > shell/pos-nogpgcheck.sh <<'EOF'
#!/usr/bin/env bash
dnf install --nogpgcheck somepkg.rpm
EOF

cat > shell/pos-gpg-auto-import.sh <<'EOF'
#!/usr/bin/env bash
zypper --gpg-auto-import-keys refresh
EOF

cat > shell/pos-curl-insecure.sh <<'EOF'
#!/usr/bin/env bash
curl -k https://example.invalid/
curl --insecure https://example.invalid/
EOF

cat > shell/pos-stricthostkeychecking.sh <<'EOF'
#!/usr/bin/env bash
echo "StrictHostKeyChecking=no" >> "${HOME}/.ssh/config"
EOF

# ── Negative cases: same shape, no match ────────────────────────────────────
cat > shell/neg-process-sub.sh <<'EOF'
#!/usr/bin/env bash
bash <(echo hello)
EOF

cat > shell/neg-command-sub.sh <<'EOF'
#!/usr/bin/env bash
sh -c "echo hello"
EOF

cat > shell/neg-env-pipe.sh <<'EOF'
#!/usr/bin/env bash
curl -s https://example.invalid/data.json | jq .
EOF

cat > shell/neg-unsigned-rpm.sh <<'EOF'
#!/usr/bin/env bash
zypper install somepkg.rpm
EOF

cat > shell/neg-nogpgcheck.sh <<'EOF'
#!/usr/bin/env bash
dnf install somepkg.rpm
EOF

cat > shell/neg-gpg-auto-import.sh <<'EOF'
#!/usr/bin/env bash
zypper refresh
EOF

cat > shell/neg-curl-insecure.sh <<'EOF'
#!/usr/bin/env bash
curl -sSL https://example.invalid/
EOF

cat > shell/neg-stricthostkeychecking.sh <<'EOF'
#!/usr/bin/env bash
echo "StrictHostKeyChecking=accept-new" >> "${HOME}/.ssh/config"
EOF

# ── Suppression case: a positive match annotated pattern-scan:ignore ───────
cat > shell/suppressed.sh <<'EOF'
#!/usr/bin/env bash
zypper install --allow-unsigned-rpm somepkg.rpm  # pattern-scan:ignore -- test fixture, already verified another way
EOF

git add -A
git commit -q -m "fixtures"

OUT="$(bash "${SCAN_SCRIPT}" "${RULES_FILE}" 2>&1)"
RC=$?

if [[ "${RC}" -ne 0 ]]; then
    ok "pattern-scan.sh exits non-zero when positive cases are present"
else
    fail "pattern-scan.sh exited 0 despite unsuppressed positive cases"
fi

declare -a POSITIVE_FILES=(
    "pos-process-sub.sh"
    "pos-command-sub.sh"
    "pos-env-pipe.sh"
    "pos-unsigned-rpm.sh"
    "pos-nogpgcheck.sh"
    "pos-gpg-auto-import.sh"
    "pos-curl-insecure.sh"
    "pos-stricthostkeychecking.sh"
)
_all_flagged=1
for _f in "${POSITIVE_FILES[@]}"; do
    if ! grep -q "file=shell/${_f}," <<< "${OUT}"; then
        fail "positive case shell/${_f} was not flagged"
        _all_flagged=0
    fi
done
[[ "${_all_flagged}" -eq 1 ]] && ok "every positive case (one per new pattern) is flagged"

declare -a NEGATIVE_FILES=(
    "neg-process-sub.sh"
    "neg-command-sub.sh"
    "neg-env-pipe.sh"
    "neg-unsigned-rpm.sh"
    "neg-nogpgcheck.sh"
    "neg-gpg-auto-import.sh"
    "neg-curl-insecure.sh"
    "neg-stricthostkeychecking.sh"
)
_none_flagged=1
for _f in "${NEGATIVE_FILES[@]}"; do
    if grep -q "file=shell/${_f}," <<< "${OUT}"; then
        fail "negative case shell/${_f} was wrongly flagged"
        _none_flagged=0
    fi
done
[[ "${_none_flagged}" -eq 1 ]] && ok "no negative case (one per new pattern) is flagged"

if grep -q "file=shell/suppressed.sh," <<< "${OUT}"; then
    fail "a pattern-scan:ignore-annotated line was flagged anyway"
else
    ok "pattern-scan:ignore suppresses a genuine positive match"
fi

# Regression guard: the three new patterns beginning with '--' previously
# matched nothing at all, ever, because git grep parsed them as its own
# unrecognised options and the failure was silently swallowed. Re-run with
# just those three patterns and confirm each one now reports at least one
# error line (not just a nonzero exit, which a shell syntax error could also
# produce).
DASH_RULES="$(mktemp)"
grep -E '^(--allow-unsigned-rpm|--nogpgcheck|--gpg-auto-import-keys)\b' "${RULES_FILE}" > "${DASH_RULES}"
DASH_OUT="$(bash "${SCAN_SCRIPT}" "${DASH_RULES}" 2>&1)"
rm -f "${DASH_RULES}"
_dash_hits="$(grep -c '^::error' <<< "${DASH_OUT}")"
if [[ "${_dash_hits}" -eq 3 ]]; then
    ok "all three '--'-prefixed patterns match via git grep -e (regression guard)"
else
    fail "expected 3 hits from the '--'-prefixed patterns alone, got ${_dash_hits} — see git grep -e regression"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
