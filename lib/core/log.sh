#!/usr/bin/env bash
# lib/core/log.sh — minimal, dependency-free logging used across the Core API,
# the distribution/sync engine, and the wb CLI. Bash 3.2 / zsh safe: no
# associative arrays, no ${var,,}. Defined only if not already present, so a
# host shell (or a future bash-logger-style integration) can shadow these.

if ! command -v log_info &>/dev/null; then
    log_info()  { printf '[INFO]  %s\n' "$*" >&2; }
fi
if ! command -v log_warn &>/dev/null; then
    log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
fi
if ! command -v log_error &>/dev/null; then
    log_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi
if ! command -v log_debug &>/dev/null; then
    log_debug() {
        [[ "${WORKBENCH_DEBUG:-false}" == "true" ]] && printf '[DEBUG] %s\n' "$*" >&2
        return 0
    }
fi
