#!/usr/bin/env bash
# tests/check-tarball-mtime.sh — workbench_fetch_tarball_public extracts
# without restoring the tarball's mtimes. GitHub stamps every entry with the
# commit time; on a host whose clock is behind that, GNU tar printed one
# "time stamp ... is N s in the future" warning per file during 'wb update'.
# A stub curl serves a tarball dated 2099, so no network is needed.
# Plain bash, numbered OK:/FAIL: checks, no framework.
#
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# SC2016: the grep pattern is bootstrap.sh's literal text.
# shellcheck disable=SC2015,SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/src/owner-repo-abc123/files"

# The tarball: one directory, as codeload serves it, every entry in 2099.
printf 'hello\n' > "${WORK}/src/owner-repo-abc123/files/a.txt"
touch -t 209901010000 "${WORK}/src/owner-repo-abc123/files/a.txt" \
    "${WORK}/src/owner-repo-abc123/files" "${WORK}/src/owner-repo-abc123"
tar -czf "${WORK}/fixture.tar.gz" -C "${WORK}/src" owner-repo-abc123

# Stub curl: writes the fixture to the -o path.
cat > "${WORK}/bin/curl" <<STUB
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "-o" ]]; then cp "${WORK}/fixture.tar.gz" "\$2"; exit 0; fi
    shift
done
exit 1
STUB
chmod +x "${WORK}/bin/curl"

DEST="${WORK}/dest"
out="$(PATH="${WORK}/bin:${PATH}" bash -c '
    source "'"${REPO_ROOT}"'/lib/core/log.sh"
    source "'"${REPO_ROOT}"'/lib/distribution/fetch-tarball.sh"
    workbench_fetch_tarball_public owner repo commit abc123 "'"${DEST}"'"' 2>&1)"
rc=$?

[[ "${rc}" -eq 0 && "$(cat "${DEST}/files/a.txt" 2>/dev/null)" == "hello" ]] \
    && ok "the tarball extracts into the snapshot directory" \
    || fail "fetch rc ${rc}: ${out}"
[[ "${out}" != *"in the future"* ]] \
    && ok "no 'time stamp ... in the future' warnings" \
    || fail "tar warned: $(printf '%s\n' "${out}" | head -n 3)"

# Neither the files nor the snapshot directory keep the 2099 date: prune's
# newest-first order is fetch order.
now="$(date +%s)"
future=0
for p in "${DEST}" "${DEST}/files/a.txt"; do
    m="$(stat -c '%Y' "${p}" 2>/dev/null || stat -f '%m' "${p}")"
    [[ "${m}" -gt $((now + 60)) ]] && future=$((future + 1))
done
[[ "${future}" -eq 0 ]] \
    && ok "extracted entries carry the fetch time, not the tarball's" \
    || fail "${future} extracted entries still dated in the future"

grep -q 'tar -xmzf "${_tmp_tar}"' "${REPO_ROOT}/bootstrap.sh" \
    && ok "bootstrap.sh extracts with -m too" \
    || fail "bootstrap.sh's tar extraction doesn't pass -m"

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
