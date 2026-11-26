#!/usr/bin/env bash
# tests/check-module-docs-topics.sh — docs/decisions-log.md D132 acceptance
# check.
#
# Covers: `wb module docs <name>` listing the module's docs/<topic>.md
# topics after its README; `wb module docs <name> <topic>` showing one;
# an unknown topic failing with the topic list; names outside the topic
# rule never reaching a path outside docs/; `wb __complete doc-topics`;
# and output to a pipe passing straight through the pager.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WB="${REPO_ROOT}/bin/wb"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
# Snapshots are read-only (D120): unseal before deleting them.
trap 'chmod -R u+w "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT

export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
mkdir -p "${HOME}"

# shellcheck source=bin/wb
source "${WB}" >"${WORK}/source.log" 2>&1
_wb_require modules/add.sh modules/info.sh

# ── Fixture: "fx" — a README, docs/alpha.md, docs/b-two.md, docs/Bad.md,
#    and a README.md one level up from docs/ that a "../README" topic would
#    reach. ─────────────────────────────────────────────────────────────────
SRC="${WORK}/src-fx"
BARE="${WORK}/fx.git"
mkdir -p "${SRC}"
git init -q --bare "${BARE}"
git clone -q "${BARE}" "${SRC}" 2>/dev/null
(
    cd "${SRC}" || exit 1
    git config user.email t@t.com
    git config user.name Test
    cat > .dotfiles-sync.yml <<'EOF'
version: 1
branch: main
EOF
    echo "FX-README-BODY" > README.md
    mkdir -p docs/a
    echo "ALPHA-BODY" > docs/alpha.md
    echo "BTWO-BODY" > docs/b-two.md
    echo "BAD-BODY" > docs/Bad.md
    echo "UPPER-A-BODY" > docs/A.md
    echo "HIDDEN-BODY" > docs/.hidden.md
    echo "NESTED-BODY" > docs/a/b.md
    git add -A && git commit -q -m v1
    git branch -M main
    git push -q origin main
    git tag v1.0.0 && git push -q origin v1.0.0
)
workbench_cmd_add fx "${BARE}" --private >"${WORK}/add.log" 2>&1

# ── 1. No topic: the README, then the topic list (Bad and A not in it). ────
OUT="$(_wb_cmd_module_docs fx 2>&1)"
if printf '%s\n' "${OUT}" | grep -q 'FX-README-BODY' \
    && printf '%s\n' "${OUT}" | grep -q '^More from fx: wb module docs fx <topic>, with <topic> one of: alpha b-two$'; then
    ok "'wb module docs fx' shows the README, then lists the topics alpha and b-two"
else
    fail "'wb module docs fx' didn't show the README and the topic list"
    printf '%s\n' "${OUT}"
fi
if printf '%s\n' "${OUT}" | grep -q 'Bad\|UPPER-A\| A '; then
    fail "'wb module docs fx' listed a topic outside the naming rule"
else
    ok "'wb module docs fx' doesn't list Bad or A"
fi

# ── 2. A topic. ─────────────────────────────────────────────────────────────
OUT="$(_wb_cmd_module_docs fx alpha 2>&1)"
if printf '%s\n' "${OUT}" | grep -q '^== fx: docs/alpha.md ==$' \
    && printf '%s\n' "${OUT}" | grep -q 'ALPHA-BODY'; then
    ok "'wb module docs fx alpha' shows docs/alpha.md under its heading"
else
    fail "'wb module docs fx alpha' didn't show docs/alpha.md"
    printf '%s\n' "${OUT}"
fi

# ── 3. An unknown topic: status 1, names it, lists the topics. ────────────
OUT="$(_wb_cmd_module_docs fx nope 2>&1)"
rc=$?
if [[ "${rc}" -eq 1 ]] && printf '%s\n' "${OUT}" | grep -q "no 'nope' document" \
    && printf '%s\n' "${OUT}" | grep -q "topics: alpha b-two"; then
    ok "'wb module docs fx nope' fails with status 1, naming nope and listing the topics"
else
    fail "'wb module docs fx nope' — rc=${rc}, output: ${OUT}"
fi

# ── 4. Names outside the rule never leave docs/. ──────────────────────────
for bad in ../README .hidden A a/b Bad; do
    OUT="$(_wb_cmd_module_docs fx "${bad}" 2>&1)"
    rc=$?
    if [[ "${rc}" -eq 1 ]] && ! printf '%s\n' "${OUT}" | grep -q 'BODY'; then
        ok "'wb module docs fx ${bad}' fails with status 1 and prints no file"
    else
        fail "'wb module docs fx ${bad}' — rc=${rc}, output: ${OUT}"
    fi
done

# ── 5. Completion lists the topics. ─────────────────────────────────────────
OUT="$(bash "${WB}" __complete doc-topics fx 2>/dev/null)"
if [[ "${OUT}" == "alpha
b-two" ]]; then
    ok "'wb __complete doc-topics fx' prints alpha and b-two"
else
    fail "'wb __complete doc-topics fx' printed: ${OUT}"
fi

# ── 6. Output to a pipe isn't paged. ────────────────────────────────────────
OUT="$(WORKBENCH_PAGER="" bash "${WB}" module docs fx alpha 2>&1 | cat)"
if printf '%s\n' "${OUT}" | grep -q 'ALPHA-BODY' \
    && ! printf '%s\n' "${OUT}" | grep -qi 'more\|--\s*(END)\|q to stop\|space for'; then
    ok "'wb module docs fx alpha | cat' passes straight through, with no pager prompt"
else
    fail "'wb module docs fx alpha | cat' showed a pager prompt or lost the document"
    printf '%s\n' "${OUT}"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks failed."
exit 1
