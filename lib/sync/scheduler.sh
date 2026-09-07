#!/usr/bin/env bash
# lib/sync/scheduler.sh — OS-level scheduled-sync timer, opt-in and
# host-wide (systemd --user timer on Linux/WSL2, launchd agent on macOS).
#
# Replaces the Ansible-only path that used to live in
# ansible/roles/module_sync/tasks/main.yml's "Scheduled sync" section
# (ARCHITECTURE.md §12 D38): the sync engine itself has always been
# Ansible-free on its hot path (§9.1), but the timer that *fires* that
# engine had none of its own — Ansible was the only thing that ever wrote
# and enabled the unit, so a host without ansible-playbook silently never
# got scheduled sync at all, with no warning. Confirmed on a real host.
#
# Default OFF, deliberately (D38): no background timer is ever written to
# a host's disk, or handed to systemd/launchd, without an explicit,
# one-time opt-in via `wb scheduler enable`. This is a separate, host-wide
# layer *underneath* each module's own SYNC_ENABLED (lib/sync/state.sh) —
# that governs what a *running* timer is allowed to touch; this governs
# whether the timer runs at all. Both must be "on" for a module to ever be
# touched automatically.
#
# Fixed-interval design is unchanged (contracts/tracking-spec.md
# §Cadence): once enabled, this fires `wb sync run-if-due` every 5 minutes
# unconditionally; workbench_sync_due() decides in userspace, on every
# firing, whether this cycle should actually do anything.
#
# Best-effort: a missing systemd --user session bus or a launchctl
# failure is warned about, never fatal to the rest of `wb install`/`wb
# apply`.

_wb_scheduler_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/sync/scheduler.sh" "0.2.0" || true

# ── persisted on/off state ───────────────────────────────────────────────────

_workbench_scheduler_conf_path() {
    printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}/workbench/core/scheduler.conf"
}

# _workbench_scheduler_conf_get <NAME> [default]
# Same shape as workbench_module_conf_get (lib/sync/state.sh) — no file at
# all is a valid, expected state (a host that's never touched this),
# distinct from the file existing with an explicit value.
_workbench_scheduler_conf_get() {
    local name="$1" default="${2:-}" file value
    file="$(_workbench_scheduler_conf_path)"
    [[ -f "${file}" ]] || { printf '%s\n' "${default}"; return 0; }
    value="$(grep -E "^${name}=" "${file}" 2>/dev/null | tail -n 1 | cut -d= -f2-)"
    printf '%s\n' "${value:-${default}}"
}

# _workbench_scheduler_conf_set <NAME> <value>
# Same mktemp+awk-rewrite discipline as _workbench_version_set_var
# (lib/core/version.sh) — no `sed -i`, portability reasons identical.
_workbench_scheduler_conf_set() {
    local name="$1" value="$2" file tmp
    file="$(_workbench_scheduler_conf_path)"
    mkdir -p "$(dirname "${file}")"
    touch "${file}"

    if grep -q "^${name}=" "${file}" 2>/dev/null; then
        tmp="$(mktemp "${file}.XXXXXX")"
        awk -v var="${name}" -v val="${value}" '
            BEGIN { key = var "=" }
            index($0, key) == 1 { print var "=" val; next }
            { print }
        ' "${file}" > "${tmp}"
        mv "${tmp}" "${file}"
    else
        printf '%s=%s\n' "${name}" "${value}" >> "${file}"
    fi
}

# workbench_scheduler_enabled
# True/false predicate — the single source of truth every other function
# below checks before touching systemd/launchd. Default (no file at all,
# or the key absent): false.
workbench_scheduler_enabled() {
    [[ "$(_workbench_scheduler_conf_get SCHEDULER_ENABLED false)" == "true" ]]
}

# ── one-time upgrade-safety migration ───────────────────────────────────────

# _workbench_scheduler_migrate_existing_install
# Called once, before every workbench_scheduler_install attempt. A host
# that already had a working Ansible-installed timer/agent before D38
# shipped must not have it silently vanish just because the new default
# is off — that's the same "changed something a user was already relying
# on" failure this design otherwise exists to prevent. Fires only when
# scheduler.conf doesn't exist AT ALL yet (never overrides an explicit
# choice, including one it just wrote itself on a prior run).
_workbench_scheduler_migrate_existing_install() {
    local conf_file
    conf_file="$(_workbench_scheduler_conf_path)"
    [[ -f "${conf_file}" ]] && return 0

    local was_active="false"
    case "${WORKBENCH_OS:-}" in
        Linux)
            command -v systemctl &>/dev/null \
                && systemctl --user is-enabled --quiet workbench-sync.timer 2>/dev/null \
                && was_active="true"
            ;;
        Mac)
            command -v launchctl &>/dev/null \
                && launchctl list com.workbench.sync &>/dev/null \
                && was_active="true"
            ;;
    esac

    if [[ "${was_active}" == "true" ]]; then
        log_info "workbench_scheduler: found an already-active scheduled-sync timer from before this host's upgrade — preserving it as enabled (run 'wb scheduler disable' if you'd rather turn it off)"
        _workbench_scheduler_conf_set SCHEDULER_ENABLED true
    fi
}

# ── Linux / WSL2 — systemd --user timer ─────────────────────────────────────

# workbench_scheduler_wb_path
# The path scheduled invocations should use — the stable ~/.local/bin/wb
# symlink (_wb_link_cli_bin, ARCHITECTURE.md §12 D19), never a module
# snapshot path directly: it survives a core update without the unit file
# itself ever needing to be rewritten for that reason.
workbench_scheduler_wb_path() {
    printf '%s\n' "${HOME}/.local/bin/wb"
}

_workbench_scheduler_install_linux() {
    local unit_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
    local service_file="${unit_dir}/workbench-sync.service"
    local timer_file="${unit_dir}/workbench-sync.timer"
    local wb_path out
    wb_path="$(workbench_scheduler_wb_path)"

    if ! command -v systemctl &>/dev/null; then
        log_warn "workbench_scheduler: systemctl not found — scheduled sync will not run automatically on this host. 'wb update'/'wb sync run-if-due' still work manually."
        return 0
    fi

    mkdir -p "${unit_dir}"

    if ! cat > "${service_file}" <<EOF
[Unit]
Description=workbench-core sync (run-if-due — see workbench-sync.timer)

[Service]
Type=oneshot
ExecStart=${wb_path} sync run-if-due
EOF
    then
        log_warn "workbench_scheduler: could not write ${service_file} — scheduled sync will not run automatically on this host. 'wb update'/'wb sync run-if-due' still work manually."
        return 0
    fi

    if ! cat > "${timer_file}" <<'EOF'
[Unit]
Description=workbench-core sync timer (fixed-interval poll; the sync engine self-throttles to the current dynamic cadence — see contracts/tracking-spec.md §Cadence)

[Timer]
OnCalendar=*:0/5
Persistent=true
Unit=workbench-sync.service

[Install]
WantedBy=timers.target
EOF
    then
        log_warn "workbench_scheduler: could not write ${timer_file} — scheduled sync will not run automatically on this host. 'wb update'/'wb sync run-if-due' still work manually."
        return 0
    fi

    if ! out="$(systemctl --user daemon-reload 2>&1)"; then
        log_warn "workbench_scheduler: 'systemctl --user daemon-reload' failed (no active user session bus? try 'loginctl enable-linger \$USER' and re-run 'wb apply'): ${out}"
        return 0
    fi

    if out="$(systemctl --user enable --now workbench-sync.timer 2>&1)"; then
        log_info "workbench_scheduler: workbench-sync.timer enabled (systemd --user)"
    else
        log_warn "workbench_scheduler: could not enable/start workbench-sync.timer (no active user session bus? try 'loginctl enable-linger \$USER' and re-run 'wb apply'): ${out}. Scheduled sync will not run automatically until this is resolved."
    fi
}

_workbench_scheduler_uninstall_linux() {
    local unit_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"

    if command -v systemctl &>/dev/null; then
        systemctl --user disable --now workbench-sync.timer &>/dev/null || true
    fi
    rm -f "${unit_dir}/workbench-sync.timer" "${unit_dir}/workbench-sync.service"
    if command -v systemctl &>/dev/null; then
        systemctl --user daemon-reload &>/dev/null || true
    fi
    log_info "workbench_scheduler: workbench-sync.timer disabled and removed (systemd --user)"
}

# ── macOS — launchd agent ───────────────────────────────────────────────────

_workbench_scheduler_install_macos() {
    local agents_dir="${HOME}/Library/LaunchAgents"
    local plist_file="${agents_dir}/com.workbench.sync.plist"
    local wb_path out was_loaded="false"
    wb_path="$(workbench_scheduler_wb_path)"

    if ! command -v launchctl &>/dev/null; then
        log_warn "workbench_scheduler: launchctl not found — scheduled sync will not run automatically on this host. 'wb update'/'wb sync run-if-due' still work manually."
        return 0
    fi

    mkdir -p "${agents_dir}" "${XDG_DATA_HOME:-${HOME}/.local/share}/workbench"
    launchctl list com.workbench.sync &>/dev/null && was_loaded="true"

    if ! cat > "${plist_file}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.workbench.sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>${wb_path}</string>
        <string>sync</string>
        <string>run-if-due</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>StandardOutPath</key>
    <string>${HOME}/.local/share/workbench/sync.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.local/share/workbench/sync.log</string>
</dict>
</plist>
EOF
    then
        log_warn "workbench_scheduler: could not write ${plist_file} — scheduled sync will not run automatically on this host. 'wb update'/'wb sync run-if-due' still work manually."
        return 0
    fi

    # launchd has no in-place "reload config" — an already-loaded agent
    # must be unloaded before a rewritten plist takes effect, or `load -w`
    # is a silent no-op against the stale in-memory definition.
    [[ "${was_loaded}" == "true" ]] && launchctl unload "${plist_file}" &>/dev/null

    if out="$(launchctl load -w "${plist_file}" 2>&1)"; then
        log_info "workbench_scheduler: com.workbench.sync loaded (launchd)"
    else
        log_warn "workbench_scheduler: 'launchctl load' for com.workbench.sync failed: ${out}. Scheduled sync will not run automatically until this is resolved."
    fi
}

_workbench_scheduler_uninstall_macos() {
    local plist_file="${HOME}/Library/LaunchAgents/com.workbench.sync.plist"

    if command -v launchctl &>/dev/null && [[ -f "${plist_file}" ]]; then
        launchctl unload "${plist_file}" &>/dev/null || true
    fi
    rm -f "${plist_file}"
    log_info "workbench_scheduler: com.workbench.sync unloaded and removed (launchd)"
}

# ── entry points ─────────────────────────────────────────────────────────────

# workbench_scheduler_install
# Called from bin/wb's _wb_cmd_install/_wb_cmd_apply on every run, every
# platform, independent of Ansible. Does nothing — not even a log line
# above debug — unless workbench_scheduler_enabled is true. This is the
# ONLY thing that decides whether systemd/launchd get touched at all.
workbench_scheduler_install() {
    _workbench_scheduler_migrate_existing_install

    if ! workbench_scheduler_enabled; then
        log_debug "workbench_scheduler: scheduled sync is disabled (default) — not installing the OS timer. Run 'wb scheduler enable' to turn it on."
        return 0
    fi

    case "${WORKBENCH_OS:-}" in
        Mac)   _workbench_scheduler_install_macos ;;
        Linux) _workbench_scheduler_install_linux ;;
        *)
            log_warn "workbench_scheduler: unrecognised WORKBENCH_OS '${WORKBENCH_OS:-<unset>}' — skipping scheduled-sync timer install."
            ;;
    esac
}

# workbench_scheduler_cmd_enable
# 'wb scheduler enable' — persists the choice, then installs immediately;
# no separate 'wb apply' required to take effect.
workbench_scheduler_cmd_enable() {
    if workbench_scheduler_enabled; then
        log_info "wb scheduler enable: already enabled — refreshing the installed timer"
    else
        _workbench_scheduler_conf_set SCHEDULER_ENABLED true
        log_info "wb scheduler enable: scheduled sync is now enabled for this host"
    fi
    case "${WORKBENCH_OS:-}" in
        Mac)   _workbench_scheduler_install_macos ;;
        Linux) _workbench_scheduler_install_linux ;;
        *)     log_warn "workbench_scheduler: unrecognised WORKBENCH_OS '${WORKBENCH_OS:-<unset>}' — nothing to install." ;;
    esac
}

# workbench_scheduler_cmd_disable
# 'wb scheduler disable' — persists the choice, then actively tears down
# whatever's currently installed. Not just "stop reinstalling on the next
# wb apply" — immediate and complete.
workbench_scheduler_cmd_disable() {
    if ! workbench_scheduler_enabled; then
        log_info "wb scheduler disable: already disabled — no-op"
        return 0
    fi
    _workbench_scheduler_conf_set SCHEDULER_ENABLED false
    log_info "wb scheduler disable: scheduled sync is now disabled for this host — removing the installed timer"
    case "${WORKBENCH_OS:-}" in
        Mac)   _workbench_scheduler_uninstall_macos ;;
        Linux) _workbench_scheduler_uninstall_linux ;;
        *) ;;
    esac
}

# workbench_scheduler_cmd_status
# 'wb scheduler status' — the persisted choice, plus live systemd/launchd
# state when enabled (a disabled-but-still-somehow-active unit, or an
# enabled-but-not-actually-running one, are both things worth surfacing).
workbench_scheduler_cmd_status() {
    if workbench_scheduler_enabled; then
        printf 'scheduled sync: enabled\n'
        case "${WORKBENCH_OS:-}" in
            Linux)
                if command -v systemctl &>/dev/null && systemctl --user is-active --quiet workbench-sync.timer 2>/dev/null; then
                    printf '  systemd --user timer: active\n'
                else
                    printf "  systemd --user timer: NOT active — run 'wb apply' to (re)install it\n"
                fi
                ;;
            Mac)
                if command -v launchctl &>/dev/null && launchctl list com.workbench.sync &>/dev/null; then
                    printf '  launchd agent: loaded\n'
                else
                    printf "  launchd agent: NOT loaded — run 'wb apply' to (re)install it\n"
                fi
                ;;
        esac
    else
        printf "scheduled sync: disabled (default) — run 'wb scheduler enable' to turn it on\n"
    fi
}
