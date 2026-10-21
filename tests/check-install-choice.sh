#!/usr/bin/env bash
# tests/check-install-choice.sh — D84: install asks about existing config
# before writing anything.
#
# Drives 'wb add' / 'wb update' through bin/wb as a subprocess against a
# local bare-repo fixture module that layers into ~/.gitconfig,
# ~/.ssh/config and a tmux.conf and deploys a whole ~/.config/starship.toml.
# The question is answered through a pty (script(1)), so /dev/tty is real
# while stdin is not the terminal; the no-terminal cases run without a
# controlling terminal (setsid where it exists).
#
# SC2088: '~/...' is quoted on purpose — ledger keys are the literal ~/-form.
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# SC2016: '$all' is starship's own syntax, written and compared literally.
# SC2030/SC2031: the fixture is built in a subshell with its own HOME on
#         purpose; every test HOME is set afterwards by new_home.
# shellcheck disable=SC2088,SC2015,SC2016,SC2030,SC2031
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WB="${REPO_ROOT}/bin/wb"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

if ! command -v script &>/dev/null; then
    echo "SKIP: script(1) not installed — can't attach a pty; skipping."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
OUT="${WORK}/out.log"
export WORKBENCH_PAGER=cat
export GIT_CONFIG_NOSYSTEM=1

# ── Fixture module (built with its own HOME, so the test HOMEs stay clean) ──
FX="${WORK}/fixture"
(
    export HOME="${WORK}/buildhome"
    mkdir -p "${HOME}"
    git init -q --bare "${FX}/m.git"
    git clone -q "${FX}/m.git" "${FX}/src" 2>/dev/null
    cd "${FX}/src" || exit 1
    git config user.email t@t.com; git config user.name Test
    mkdir -p files
    printf '[init]\n\tdefaultBranch = main\n' > files/gitconfig
    printf 'set -g mouse on\n' > files/tmux.conf
    printf 'HashKnownHosts yes\nServerAliveInterval 60\n' > files/ssh
    printf 'format = "$all"\n' > files/starship.toml
    cat > workbench.yml <<'EOF'
version: 2
core_api: ">=1.6 <2.0"
deploy:
  - src: files/starship.toml
    dest: ~/.config/starship.toml
layers:
  - tool: gitconfig
    src: files/gitconfig
  - tool: tmux.conf
    src: files/tmux.conf
  - tool: ssh_config
    src: files/ssh
EOF
    git add -A; git commit -q -m v1; git branch -M main
    git push -q origin main 2>/dev/null
    git tag v1.0.0; git push -q origin v1.0.0 2>/dev/null
)
URL="${FX}/m.git"

# new_home — a fresh scratch HOME, XDG under it like a real host
new_home() {
    export HOME="${WORK}/home-$1"
    export XDG_DATA_HOME="${HOME}/.local/share"
    export XDG_CONFIG_HOME="${HOME}/.config"
    rm -rf "${HOME}"; mkdir -p "${HOME}"
}

seed_user_files() {
    printf '[user]\n\tname = Fixture\n\temail = fixture@example.invalid\n[core]\n\teditor = nano\n' > "${HOME}/.gitconfig"
    printf 'set -g mouse off\n' > "${HOME}/.tmux.conf"
    mkdir -p "${HOME}/.config"
    printf 'format = "mine"\n' > "${HOME}/.config/starship.toml"
}

# snapshot — every file outside workbench's own directories, with content
snapshot() {
    ( cd "${HOME}" && find . -path ./.local/share/workbench -prune -o -path ./.config/workbench -prune \
        -o -type f -print | sort | while IFS= read -r f; do printf '%s\n' "${f}"; cat "${f}"; done )
}

# run_notty <wb args...> — no controlling terminal: nobody can be asked
run_notty() {
    rc=0
    if command -v setsid &>/dev/null; then
        setsid -w bash "${WB}" "$@" </dev/null >"${OUT}" 2>&1 || rc=$?
    else
        bash "${WB}" "$@" </dev/null >"${OUT}" 2>&1 || rc=$?
    fi
}

# pty_run <answers> <command-string> — runs the command in a pty and types
# <answers> (printf escapes) at it. Input stays open until the command has
# finished: BSD script(1) (macOS) sends ^D the moment its stdin ends, which
# the command would read as end-of-input before the answers. Sets rc.
pty_run() {
    local answers="$1" cmd="$2" done_flag="${WORK}/pty.done" n=0
    rm -f "${done_flag}"
    cmd="${cmd}; rc=\$?; touch $(printf '%q' "${done_flag}"); exit \${rc}"
    rc=0
    {
        printf '%b' "${answers}"
        while [[ ! -e "${done_flag}" && "${n}" -lt 1200 ]]; do sleep 0.1; n=$((n + 1)); done
    } | if script --version 2>/dev/null | grep -q util-linux; then
        script -qec "${cmd}" /dev/null
    else
        script -q /dev/null bash -c "${cmd}"
    fi >"${OUT}" 2>&1 || rc=$?
}

# run_tty <answers> <wb args...> — a pty attached, stdin a pipe
run_tty() {
    local answers="$1"
    shift
    pty_run "${answers}" "echo | $(printf '%q ' bash "${WB}" "$@")"
}

asked()    { grep -q "These modules would touch config you already have" "${OUT}"; }
times_asked() { grep -c "These modules would touch config you already have" "${OUT}"; }
blocks_stripped() { awk '/^[#"] >>> workbench /{i=1} !i{print} /^[#"] <<< workbench /{i=0}' "$1"; }
conf_of() { grep "^$2=" "${XDG_DATA_HOME}/workbench/modules/$1/sync.conf" 2>/dev/null | cut -d= -f2; }

# ── 1. fresh HOME: nothing to ask, every target created ─────────────────────
new_home fresh
run_tty 'q\n' add choice "${URL}" --private
! asked && [[ -f "${HOME}/.gitconfig" && -f "${HOME}/.ssh/config" && -f "${HOME}/.config/starship.toml" ]] \
    && ok "fresh HOME: no question, every target created" || { fail "fresh HOME (rc ${rc})"; cat "${OUT}"; }

# ── 2. existing files, no terminal, no flag: keep ───────────────────────────
new_home notty; seed_user_files
cp "${HOME}/.gitconfig" "${WORK}/g0"; cp "${HOME}/.tmux.conf" "${WORK}/t0"; cp "${HOME}/.config/starship.toml" "${WORK}/s0"
run_notty add choice "${URL}" --private
! asked && grep -q '>>> workbench choice/gitconfig under >>>' "${HOME}/.gitconfig" \
    && blocks_stripped "${HOME}/.gitconfig" | cmp -s - "${WORK}/g0" && blocks_stripped "${HOME}/.tmux.conf" | cmp -s - "${WORK}/t0" \
    && cmp -s "${HOME}/.config/starship.toml" "${WORK}/s0" \
    && ok "no terminal: keep — blocks added, your bytes intact outside them, whole files left" || { fail "no terminal keep (rc ${rc})"; cat "${OUT}"; }

# ── 3. answer q: nothing changed; registered; 'wb update' asks again ────────
new_home quit; seed_user_files
snapshot > "${WORK}/before-quit"
run_tty 'q\n' add choice "${URL}" --private
snapshot > "${WORK}/after-quit"
asked && cmp -s "${WORK}/before-quit" "${WORK}/after-quit" \
    && ok "quit: nothing outside workbench's own directories changed" || { fail "quit changed files (rc ${rc})"; diff "${WORK}/before-quit" "${WORK}/after-quit"; cat "${OUT}"; }
[[ "$(conf_of choice REGISTERED)" == "true" && "$(conf_of choice SYNC_ENABLED)" == "true" && -z "$(conf_of choice RESOLVED_SHA)" ]] \
    && ok "quit: the module stays registered with sync enabled, not yet deployed" || fail "quit: sync.conf $(cat "${XDG_DATA_HOME}/workbench/modules/choice/sync.conf")"
run_tty 'k\n' update choice
asked && grep -q '>>> workbench choice/tmux.conf under >>>' "${HOME}/.tmux.conf" && [[ -n "$(conf_of choice RESOLVED_SHA)" ]] \
    && ok "quit, then 'wb update' from a terminal: asked again; keep deploys" || { fail "update after quit (rc ${rc})"; cat "${OUT}"; }

# ── 4. answer u, then y: replaced, [user] carried; restore all ─────────────
new_home use; seed_user_files
cp "${HOME}/.gitconfig" "${WORK}/g0"; cp "${HOME}/.tmux.conf" "${WORK}/t0"; cp "${HOME}/.config/starship.toml" "${WORK}/s0"
run_tty 'u\ny\n' add choice "${URL}" --private
[[ "$(git config --file "${HOME}/.gitconfig" --get user.email)" == "fixture@example.invalid" ]] \
    && ! git config --file "${HOME}/.gitconfig" --get core.editor >/dev/null \
    && grep -q "keep your \[user\] section (name, email)" "${OUT}" \
    && ok "use: gitconfig is workbench's block plus your carried [user] section (shown in the preview)" || { fail "use gitconfig: $(cat "${HOME}/.gitconfig")"; cat "${OUT}"; }
[[ -z "$(blocks_stripped "${HOME}/.tmux.conf" | tr -d '[:space:]')" && "$(cat "${HOME}/.config/starship.toml")" == 'format = "$all"' ]] \
    && ok "use: tmux.conf is block-only; starship.toml is workbench's" || { fail "use tmux/starship"; cat "${HOME}/.tmux.conf"; }
compgen -G "${XDG_DATA_HOME}/workbench/backups/*/*/choice-.gitconfig.*" >/dev/null \
    && ok "use: your originals backed up" || fail "use: no backups"
[[ "$(grep '^INSTALL_DEFAULT=' "${XDG_DATA_HOME}/workbench/files.conf" 2>/dev/null)" == "INSTALL_DEFAULT=use" ]] \
    && ok "use: INSTALL_DEFAULT=use recorded" || fail "INSTALL_DEFAULT not recorded"
run_notty files restore choice all --yes
cmp -s "${HOME}/.gitconfig" "${WORK}/g0" && cmp -s "${HOME}/.tmux.conf" "${WORK}/t0" && cmp -s "${HOME}/.config/starship.toml" "${WORK}/s0" \
    && ok "restore all after use: every original back, byte-identical" || { fail "restore all (rc ${rc})"; cat "${OUT}"; diff "${HOME}/.gitconfig" "${WORK}/g0"; }

# ── 5. answer c: keep / use / skip per file ─────────────────────────────────
new_home choose; seed_user_files
cp "${HOME}/.tmux.conf" "${WORK}/t0"; cp "${HOME}/.config/starship.toml" "${WORK}/s0"
# Plan order: whole files first (starship), then layered files (gitconfig, tmux)
run_tty 'c\ns\nu\nk\ny\n' add choice "${URL}" --private
cmp -s "${HOME}/.config/starship.toml" "${WORK}/s0" \
    && grep -q '^~/.config/starship.toml|skip$' "${XDG_DATA_HOME}/workbench/modules/choice/files.policy" \
    && ok "choose: s — a skip row, the file untouched" || { fail "choose skip"; cat "${OUT}"; }
! git config --file "${HOME}/.gitconfig" --get core.editor >/dev/null && [[ "$(git config --file "${HOME}/.gitconfig" --get user.name)" == "Fixture" ]] \
    && ok "choose: u — gitconfig replaced, [user] kept" || fail "choose use: $(cat "${HOME}/.gitconfig")"
blocks_stripped "${HOME}/.tmux.conf" | cmp -s - "${WORK}/t0" && grep -q 'workbench choice/tmux.conf' "${HOME}/.tmux.conf" \
    && ok "choose: k — tmux.conf layered, your lines kept" || fail "choose keep: $(cat "${HOME}/.tmux.conf")"

# ── 6. answer d: a unified diff, then the question again ────────────────────
new_home diff; seed_user_files
run_tty 'd\nq\n' add choice "${URL}" --private
grep -q -- '--- yours: ~/.config/starship.toml' "${OUT}" && grep -q -- '+++ workbench: choice' "${OUT}" && [[ "$(times_asked)" -eq 2 ]] \
    && ok "d: yours vs workbench as a unified diff, then asked again" || { fail "diff (asked $(times_asked)x)"; cat "${OUT}"; }

# ── 7. ssh carry-over ───────────────────────────────────────────────────────
new_home ssh
mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
cat > "${HOME}/.ssh/config" <<'EOF'
ServerAliveInterval 15
Include ~/.ssh/extra.conf
Host *
  Compression yes
Host nas
  HostName 10.9.8.7
Match host work-*
  User worker
EOF
chmod 600 "${HOME}/.ssh/config"
run_tty 'u\ny\n' add choice "${URL}" --private
S="${HOME}/.ssh/config"
ok_ssh=true
grep -q 'ServerAliveInterval 15' "${S}" && ok_ssh=false
grep -q 'Compression yes' "${S}" && ok_ssh=false
grep -qx 'Include ~/.ssh/extra.conf' "${S}" || ok_ssh=false
grep -qx 'Host nas' "${S}" && grep -qx 'Match host work-\*' "${S}" || ok_ssh=false
[[ "$(tail -n 1 "${S}")" == "# <<< workbench choice/ssh_config under <<<" ]] || ok_ssh=false
[[ "$(awk '/^Host nas$/{print NR}' "${S}")" -lt "$(awk '/>>> workbench choice\/ssh_config under >>>/{print NR}' "${S}")" ]] || ok_ssh=false
[[ "${ok_ssh}" == "true" ]] && ok "ssh use: globals and Host * dropped; Include, Host nas, Match kept above the bottom block" || { fail "ssh carry"; cat "${S}"; }
grep -q "keep 2 Host/Match entries: nas, host work-\*" "${OUT}" && grep -q "keep 1 Include line" "${OUT}" \
    && ok "ssh use: the preview lists the hosts and includes kept" || { fail "ssh preview"; cat "${OUT}"; }
if command -v ssh &>/dev/null; then
    [[ "$(ssh -F "${S}" -G nas </dev/null 2>/dev/null | awk '$1 == "hostname" { print $2 }')" == "10.9.8.7" ]] \
        && ok "ssh use: 'ssh -G nas' still resolves your HostName" || fail "ssh -G nas: $(ssh -F "${S}" -G nas </dev/null 2>&1 | grep -i hostname)"
fi

# ── 8. INSTALL_DEFAULT=use: Enter picks u; no terminal still keeps ──────────
new_home default; seed_user_files
mkdir -p "${XDG_DATA_HOME}/workbench"; printf 'INSTALL_DEFAULT=use\n' > "${XDG_DATA_HOME}/workbench/files.conf"
run_tty '\ny\n' add choice "${URL}" --private
grep -q "\[u\] use workbench's (default)" "${OUT}" && ! git config --file "${HOME}/.gitconfig" --get core.editor >/dev/null \
    && ok "INSTALL_DEFAULT=use: Enter picks use" || { fail "Enter with default use"; cat "${OUT}"; }
new_home default2; seed_user_files
mkdir -p "${XDG_DATA_HOME}/workbench"; printf 'INSTALL_DEFAULT=use\n' > "${XDG_DATA_HOME}/workbench/files.conf"
run_notty add choice "${URL}" --private
[[ "$(git config --file "${HOME}/.gitconfig" --get core.editor)" == "nano" ]] \
    && ok "INSTALL_DEFAULT=use: with no terminal it still keeps" || { fail "no-tty with default use"; cat "${OUT}"; }

# ── 9. --keep-files --use-files: usage error, nothing changed ──────────────
new_home both; seed_user_files
snapshot > "${WORK}/before-both"
run_notty add choice "${URL}" --private --keep-files --use-files
[[ "${rc}" -eq 2 && ! -d "${XDG_DATA_HOME}/workbench/modules/choice" ]] && snapshot | cmp -s - "${WORK}/before-both" \
    && ok "--keep-files with --use-files: usage error, nothing registered or changed" || { fail "both flags (rc ${rc})"; cat "${OUT}"; }

new_home keepflag; seed_user_files
cp "${HOME}/.config/starship.toml" "${WORK}/s0"
run_tty 'u\ny\n' add choice "${URL}" --private --keep-files
! asked && grep -q 'workbench choice/gitconfig' "${HOME}/.gitconfig" && cmp -s "${HOME}/.config/starship.toml" "${WORK}/s0" \
    && ok "--keep-files: no question even with a terminal; keep" || { fail "--keep-files"; cat "${OUT}"; }

new_home useflag; seed_user_files
run_notty add choice "${URL}" --private --use-files --yes
[[ "${rc}" -eq 0 ]] && ! git config --file "${HOME}/.gitconfig" --get core.editor >/dev/null \
    && [[ "$(git config --file "${HOME}/.gitconfig" --get user.name)" == "Fixture" ]] \
    && ok "--use-files --yes: no questions, workbench's files, your identity kept" || { fail "--use-files --yes (rc ${rc})"; cat "${OUT}"; }

# ── 10. bootstrap path: stdin a pipe, a pty attached → still asks ───────────
# bootstrap.sh hands off with 'exec wb install "$@"', so when bootstrap is
# piped into bash the question's process inherits the pipe as stdin. A stub wb (bootstrap's
# own test pattern: mock curl, fixture tarball) asks through /dev/tty the
# way _wb_install_ask does, and reports what it read.
BS="${WORK}/bootstrap"
mkdir -p "${BS}/src/workbench-core-testref/bin" "${BS}/mockbin"
cat > "${BS}/src/workbench-core-testref/bin/wb" <<'EOF'
#!/usr/bin/env bash
if { : </dev/tty; } 2>/dev/null; then
    printf 'question> ' >/dev/tty
    IFS= read -r answer </dev/tty
    echo "stub-wb: asked, answer '${answer}', args: $*"
else
    echo "stub-wb: no terminal"
fi
EOF
chmod +x "${BS}/src/workbench-core-testref/bin/wb"
tar -czf "${BS}/core.tar.gz" -C "${BS}/src" workbench-core-testref
printf '{"sha":"3333333333333333333333333333333333333333","commit":{"tree":{"sha":"4444444444444444444444444444444444444444"}}}\n' > "${BS}/main.json"
cat > "${BS}/mockbin/curl" <<EOF
#!/usr/bin/env bash
url=""; out=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in -o) out="\$2"; shift ;; -H|-A) shift ;; -*) ;; *) url="\$1" ;; esac
    shift
done
case "\${url}" in
    */codeload.github.com/*) cp "${BS}/core.tar.gz" "\${out}" ;;
    */repos/*/tags*) echo '[]' ;;
    */commits/main) cat "${BS}/main.json" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "${BS}/mockbin/curl"
new_home bootstrap
cmd="$(printf '%q ' env PATH="${BS}/mockbin:${PATH}" HOME="${HOME}" XDG_DATA_HOME="${XDG_DATA_HOME}" bash -s -- --bundle minimal)"
pty_run 'k\n' "cat $(printf '%q' "${REPO_ROOT}/bootstrap.sh") | ${cmd}"
grep -q "stub-wb: asked, answer 'k', args: install --bundle minimal" "${OUT}" \
    && ok "bootstrap via 'cat bootstrap.sh | bash -s -- --bundle minimal' with a pty: the question reaches the terminal" \
    || { fail "bootstrap pipe+pty (rc ${rc})"; cat "${OUT}"; }

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
