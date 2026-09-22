#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# searxng-quadlet uninstall.sh — Remove a SearXNG quadlet deployment.
#
# Usage:
#   ./uninstall.sh [OPTIONS]
#
# Options:
#   --mode system|user       Installation mode (default: system)
#   --user NAME              Service username (for --mode system)
#   --purge                  Remove state directory and service account
#   --dry-run                Print actions without executing
#   -h, --help               Show this help message

set -euo pipefail

# ============================================================================
# Constants & Defaults
# ============================================================================

readonly USER_MODE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly USER_MODE_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"

# ============================================================================
# Global Variables
# ============================================================================

MODE="system"
USER_NAME=""
PURGE=false
DRY_RUN=false

SERVICE_USER=""
CONFIG_DIR=""
DATA_DIR=""
QUADLET_DIR=""
STATE_DIR=""

# ============================================================================
# Logging Helpers
# ============================================================================

log() { printf "[INFO] %s\n" "$*" ; }
warn() { printf "[WARN] %s\n" "$*" >&2 ; }
die()  { printf "[ERROR] %s\n" "$*" >&2 ; exit 1 ; }
info() { printf "[*] %s\n" "$*" ; }

# ============================================================================
# Argument Parsing
# ============================================================================

usage() {
    sed -n '3,15p' "$0"
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --mode) MODE="$2"; shift 2 ;;
            --user) USER_NAME="$2"; shift 2 ;;
            --purge) PURGE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            -h|--help) usage ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    if [[ "$MODE" != "system" && "$MODE" != "user" ]]; then
        die "Invalid mode: $MODE (must be 'system' or 'user')"
    fi

    if [[ "$MODE" == "system" ]]; then
        if (( EUID != 0 )) && [[ "$DRY_RUN" != true ]]; then
            die "--mode system requires root (runuser/loginctl/userdel). Re-run with: sudo ./uninstall.sh --mode system"
        fi
        SERVICE_USER="${USER_NAME:-searxng}"
        CONFIG_DIR="/var/lib/${SERVICE_USER}/config"
        DATA_DIR="/var/lib/${SERVICE_USER}/data"
        STATE_DIR="/var/lib/${SERVICE_USER}"
        QUADLET_DIR="/var/lib/${SERVICE_USER}/.config/containers/systemd"
    else
        SERVICE_USER="$USER"
        CONFIG_DIR="${USER_MODE_DATA}/${SERVICE_USER}/config"
        DATA_DIR="${USER_MODE_DATA}/${SERVICE_USER}/data"
        STATE_DIR="${USER_MODE_DATA}/${SERVICE_USER}"
        QUADLET_DIR="${USER_MODE_CONFIG}/containers/systemd"
    fi
}

# ============================================================================
# Uninstall Logic
# ============================================================================

stop_service() {
    info "Stopping searxng.service..."

    local cmd="systemctl --user stop searxng.service"
    if [[ "$MODE" == "system" ]]; then
        local svc_uid
        svc_uid=$(id -u "$SERVICE_USER" 2>/dev/null || echo "")
        if [[ -n "$svc_uid" ]]; then
            cmd="runuser -u '${SERVICE_USER}' -- env XDG_RUNTIME_DIR=/run/user/${svc_uid} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${svc_uid}/bus ${cmd}"
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would execute: ${cmd}"
    else
        eval "$cmd" 2>/dev/null || true
    fi
}

remove_quadlet_files() {
    info "Removing quadlet files from ${QUADLET_DIR}..."

    local removed=0
    for f in searxng.container searxng.image; do
        local path="${QUADLET_DIR}/${f}"
        if [[ -f "$path" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                info "[DRY-RUN] Would remove: ${path}"
            else
                rm -f "$path"
                info "Removed: ${path}"
            fi
            removed=$((removed + 1))
        fi
    done

    if (( removed == 0 )); then
        info "No quadlet files found."
    fi
}

reload_daemon() {
    info "Reloading systemd user daemon..."

    local cmd="systemctl --user daemon-reload"
    if [[ "$MODE" == "system" ]]; then
        local svc_uid
        svc_uid=$(id -u "$SERVICE_USER" 2>/dev/null || echo "")
        if [[ -n "$svc_uid" ]]; then
            cmd="runuser -u '${SERVICE_USER}' -- env XDG_RUNTIME_DIR=/run/user/${svc_uid} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${svc_uid}/bus ${cmd}"
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would execute: ${cmd}"
    else
        eval "$cmd" 2>/dev/null || true
    fi
}

remove_container() {
    info "Removing container 'searxng' if it exists..."

    local cmd="podman rm -f searxng 2>/dev/null || true"
    if [[ "$MODE" == "system" ]]; then
        local svc_uid
        svc_uid=$(id -u "$SERVICE_USER" 2>/dev/null || echo "")
        if [[ -n "$svc_uid" ]]; then
            cmd="runuser -u '${SERVICE_USER}' -- env XDG_RUNTIME_DIR=/run/user/${svc_uid} ${cmd}"
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would execute: ${cmd}"
    else
        eval "$cmd" 2>/dev/null || true
    fi
}

disable_auto_update() {
    info "Disabling podman-auto-update.timer..."

    local cmd="systemctl --user disable --now podman-auto-update.timer"
    if [[ "$MODE" == "system" ]]; then
        local svc_uid
        svc_uid=$(id -u "$SERVICE_USER" 2>/dev/null || echo "")
        if [[ -n "$svc_uid" ]]; then
            cmd="runuser -u '${SERVICE_USER}' -- env XDG_RUNTIME_DIR=/run/user/${svc_uid} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${svc_uid}/bus ${cmd}"
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would execute: ${cmd}"
    else
        eval "$cmd" 2>/dev/null || true
    fi
}

purge_state() {
    if [[ "$PURGE" != true ]]; then
        return 0
    fi

    info "Purging state directories..."

    # List what will be removed
    local files_to_remove=()
    if [[ -d "$CONFIG_DIR" ]]; then
        files_to_remove+=("$CONFIG_DIR")
    fi
    if [[ -d "$DATA_DIR" ]]; then
        files_to_remove+=("$DATA_DIR")
    fi
    if [[ -d "$STATE_DIR" ]]; then
        files_to_remove+=("$STATE_DIR")
    fi

    if [[ ${#files_to_remove[@]} -eq 0 ]]; then
        info "No state directories found to remove."
        return 0
    fi

    info "The following will be deleted:"
    for f in "${files_to_remove[@]}"; do
        info "  - ${f}"
    done

    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    # Confirm removal
    read -rp "Proceed with purge? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Purge cancelled."
        return 0
    fi

    for f in "${files_to_remove[@]}"; do
        if [[ -d "$f" ]]; then
            rm -rf "$f"
            info "Removed: ${f}"
        fi
    done
}

disable_linger() {
    if [[ "$MODE" != "system" ]]; then
        return 0
    fi

    info "Disabling lingering for '${SERVICE_USER}'..."

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would execute: loginctl disable-linger ${SERVICE_USER}"
    else
        loginctl disable-linger "$SERVICE_USER" 2>/dev/null || true
    fi
}

remove_user() {
    if [[ "$MODE" != "system" ]]; then
        return 0
    fi

    if [[ "$PURGE" != true ]]; then
        return 0
    fi

    info "Removing service user '${SERVICE_USER}'..."

    # List what will be removed
    info "This will delete:"
    info "  - User account: ${SERVICE_USER}"
    info "  - Home directory: /var/lib/${SERVICE_USER}"
    info "  - SubUID/SubGID ranges"

    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    # Confirm removal
    read -rp "Proceed with user deletion? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "User deletion cancelled."
        return 0
    fi

    userdel --remove "$SERVICE_USER" 2>/dev/null || {
        warn "Failed to remove user '${SERVICE_USER}'. You may need to run manually:"
        warn "  sudo userdel --remove ${SERVICE_USER}"
    }

    info "User '${SERVICE_USER}' removed."
}

# ============================================================================
# Main
# ============================================================================

main() {
    parse_args "$@"

    if [[ "$DRY_RUN" == true ]]; then
        info "Dry run mode — no changes will be made."
        info "Mode: ${MODE}"
        info "Service User: ${SERVICE_USER}"
        info "State Dir: ${STATE_DIR}"
        info "Purge: $([[ $PURGE == true ]] && echo yes || echo no)"
        return 0
    fi

    info "SearXNG Quadlet Uninstaller"
    info "==========================="

    stop_service
    remove_quadlet_files
    reload_daemon
    remove_container
    disable_auto_update
    purge_state
    disable_linger
    remove_user

    echo ""
    echo "=========================================="
    echo "  SearXNG Uninstallation Complete"
    echo "=========================================="
    echo ""

    if [[ "$PURGE" == true ]]; then
        echo "  All state has been purged."
    else
        echo "  State preserved. Re-run with --purge to remove data."
    fi

    echo ""
}

main "$@"
