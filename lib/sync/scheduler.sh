#!/usr/bin/env bash
# lib/sync/scheduler.sh — OS-level scheduled-sync timer install (systemd
# --user timer on Linux/WSL2, launchd agent on macOS).
#
# Replaces the Ansible-only path that used to live in
# ansible/roles/module_sync/tasks/main.yml's "Scheduled sync" section
# (ARCHITECTURE.md §12 D38): the sync engine itself has always been
# Ansible-free on its hot path (§9.1), but the timer that *fires* that
# engine had none of its own — Ansible was the only thing that ever wrote
# and enabled the unit, so a host without ansible-playbook silently never
# got scheduled sync at all, with no warning. Confirmed on a real host,
# not hypothetical.
#
# Fixed-interval design is unchanged (contracts/tracking-spec.md
# §Cadence): this fires `wb sync run-if-due` every 5 minutes
# unconditionally; workbench_sync_due() decides in userspace, on every
# firing, whether this cycle should actually do anything. Reconfiguring a
# *running* timer's own interval requires reloading it — exactly the
# "restart of timer infrastructure" a tracking-mode change must never
# require, which is why this file never changes OnCalendar/StartInterval
# to anything other than the fixed 5-minute value, even though the unit
# content (those keys included) is rewritten unconditionally below.
#
# Best-effort like the Ansible version it replaces: a missing systemd
# --user session bus or a launchctl failure is warned about, never fatal
# to the rest of `wb install`/`wb apply` — `wb update`/`wb sync
# run-if-due` remain available manually either way.

_wb_scheduler_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# shellcheck disable=SC2015
command -v _workbench_register_script_version &>/dev/null && _workbench_register_script_version "lib/sync/scheduler.sh" "0.2.0" || true

# workbench_scheduler_wb_path
# The path scheduled invocations should use — the stable ~/.local/bin/wb
# symlink (_wb_link_cli_bin, ARCHITECTURE.md §12 D19), never a module
# snapshot path directly: it survives a core update without the unit file
# itself ever needing to be rewritten for that reason.
workbench_scheduler_wb_path() {
    printf '%s\n' "${HOME}/.local/bin/wb"
}

# ── Linux / WSL2 — systemd --user timer ─────────────────────────────────────

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
# Fires every 5 minutes, unconditionally. This interval never changes and
# is never re-registered — the actual weekly/5-minute cadence decision is
# made in userspace by lib/sync/engine.sh's workbench_sync_due() on every
# firing, based on current TRACK_MODE state across all registered modules.
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

    # Unconditional, every run — not gated on whether the files above
    # actually changed. This is the same WSL2 workaround the Ansible
    # sync-external role already relies on: the user systemd instance is
    # often not yet fully up on first convergence, and daemon-reload is
    # cheap enough to always pay.
    if ! out="$(systemctl --user daemon-reload 2>&1)"; then
        log_warn "workbench_scheduler: 'systemctl --user daemon-reload' failed (no active user session bus? try 'loginctl enable-linger \$USER' and re-run 'wb apply'): ${out}"
        return 0
    fi

    if out="$(systemctl --user enable --now workbench-sync.timer 2>&1)"; then
        log_info "workbench_scheduler: workbench-sync.timer enabled (systemd --user)"
    else
        log_warn "workbench_scheduler: could not enable/start workbench-sync.timer (no active user session bus? try 'loginctl enable-linger \$USER' and re-run 'wb apply'): ${out}. Scheduled sync will not run automatically until this is resolved — 'wb update'/'wb sync run-if-due' still work manually in the meantime."
    fi
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

    mkdir -p "${agents_dir}"
    mkdir -p "${XDG_DATA_HOME:-${HOME}/.local/share}/workbench"

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
    # is a silent no-op against the stale in-memory definition. This is
    # more correct than the Ansible version it replaces, which only ever
    # called `load` on first install (`when: ...plist.changed`) and never
    # handled a later content change cleanly.
    [[ "${was_loaded}" == "true" ]] && launchctl unload "${plist_file}" &>/dev/null

    if out="$(launchctl load -w "${plist_file}" 2>&1)"; then
        log_info "workbench_scheduler: com.workbench.sync loaded (launchd)"
    else
        log_warn "workbench_scheduler: 'launchctl load' for com.workbench.sync failed: ${out}. Scheduled sync will not run automatically until this is resolved — 'wb update'/'wb sync run-if-due' still work manually in the meantime."
    fi
}

# ── entry point ──────────────────────────────────────────────────────────────

# workbench_scheduler_install
# OS-appropriate entry point, called from bin/wb's _wb_cmd_install
# unconditionally — every wb install/apply run, on every platform,
# independent of whether Ansible/ansible-playbook is present at all
# (ARCHITECTURE.md §12 D38). Never fatal: worst case is a log_warn, the
# same non-fatal behaviour the Ansible-era version had.
workbench_scheduler_install() {
    case "${WORKBENCH_OS:-}" in
        Mac)   _workbench_scheduler_install_macos ;;
        Linux) _workbench_scheduler_install_linux ;;
        *)
            log_warn "workbench_scheduler: unrecognised WORKBENCH_OS '${WORKBENCH_OS:-<unset>}' — skipping scheduled-sync timer install. 'wb update'/'wb sync run-if-due' still work manually."
            ;;
    esac
}
