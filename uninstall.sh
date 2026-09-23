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
#   --state-dir PATH         State directory (default: varies by mode; must
#                             match the value given to install.sh, if any)
#   --purge                  Remove state directories and (system mode) the
#                             service account
#   --disable-auto-update    Also disable podman-auto-update.timer (shared
#                             across all quadlets for this user — left alone
#                             by default since other containers may use it)
#   --purge-image             With --purge, also remove the pulled container
#                             image (podman rmi)
#   --image REF               Image ref to remove with --purge-image
#                             (default: docker.io/searxng/searxng:latest —
#                             must match what install.sh --image was given)
#   -y, --yes                Answer yes to interactive prompts (unattended)
#   --dry-run                Print actions without executing
#   -h, --help               Show this help message

set -euo pipefail

# ============================================================================
# Constants & Defaults
# ============================================================================

readonly APP_NAME="searxng"
readonly USER_MODE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly USER_MODE_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
readonly MARKER_NAME=".searxng-quadlet"

# ============================================================================
# Global Variables
# ============================================================================

MODE="system"
USER_NAME=""
STATE_DIR_ARG=""
PURGE=false
PURGE_IMAGE=false
DISABLE_AUTO_UPDATE=false
ASSUME_YES=false
DRY_RUN=false

SERVICE_USER=""
SERVICE_UID=""
QUADLET_DIR=""
STATE_DIR=""
IMAGE_REF="docker.io/searxng/searxng:latest"

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
    cat <<'EOF'
searxng-quadlet uninstall.sh — Remove a SearXNG quadlet deployment.

Usage:
  ./uninstall.sh [OPTIONS]

Options:
  --mode system|user       Installation mode (default: system)
  --user NAME              Service username (for --mode system)
  --state-dir PATH         State directory (default: varies by mode; must
                            match the value given to install.sh, if any)
  --purge                  Remove state directories and (system mode) the
                            service account
  --disable-auto-update    Also disable podman-auto-update.timer (shared
                            across all quadlets for this user — left alone
                            by default since other containers may use it)
  --purge-image            With --purge, also remove the pulled container
                            image (podman rmi)
  --image REF              Image ref to remove with --purge-image
                            (default: docker.io/searxng/searxng:latest —
                            must match what install.sh --image was given)
  -y, --yes                Answer yes to interactive prompts (unattended)
  --dry-run                Print actions without executing
  -h, --help               Show this help message
EOF
    exit 0
}

need_arg() {
    if (( $2 < 2 )); then
        die "Option $1 requires an argument."
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --mode) need_arg "$1" "$#"; MODE="$2"; shift 2 ;;
            --user) need_arg "$1" "$#"; USER_NAME="$2"; shift 2 ;;
            --state-dir) need_arg "$1" "$#"; STATE_DIR_ARG="$2"; shift 2 ;;
            --purge) PURGE=true; shift ;;
            --purge-image) PURGE_IMAGE=true; shift ;;
            --image) need_arg "$1" "$#"; IMAGE_REF="$2"; shift 2 ;;
            --disable-auto-update) DISABLE_AUTO_UPDATE=true; shift ;;
            -y|--yes) ASSUME_YES=true; shift ;;
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
        STATE_DIR="/var/lib/${SERVICE_USER}"
        QUADLET_DIR="${STATE_DIR}/.config/containers/systemd"
    else
        if [[ "$MODE" == "user" && -n "$USER_NAME" ]]; then
            warn "--user is ignored in --mode user (the invoking user is always used)."
        fi
        SERVICE_USER="$(id -un)"
        STATE_DIR="${USER_MODE_DATA}/${APP_NAME}"
        # Matches install.sh's default: the quadlet dir lives under
        # $XDG_CONFIG_HOME, separate from the $XDG_DATA_HOME-rooted state
        # dir — only a --state-dir override nests it under STATE_DIR (below).
        QUADLET_DIR="${USER_MODE_CONFIG}/containers/systemd"
    fi

    if [[ -n "$STATE_DIR_ARG" ]]; then
        STATE_DIR="$STATE_DIR_ARG"
        QUADLET_DIR="${STATE_DIR}/.config/containers/systemd"
    fi
}

confirm() {
    # $1 = prompt. Returns 0 (proceed) or 1 (cancel).
    if [[ "$ASSUME_YES" == true ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        warn "$1 — stdin is not a TTY; skipping (pass --yes to proceed unattended)."
        return 1
    fi
    local reply
    read -rp "$1 [y/N] " -n 1 -r reply
    echo
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ============================================================================
# Service-user command execution
# ============================================================================

# Resolves SERVICE_UID once, if the service account exists (system mode
# only). Left empty in user mode (unused there) or if the account is gone.
resolve_service_uid() {
    if [[ "$MODE" == "system" ]]; then
        SERVICE_UID=$(id -u "$SERVICE_USER" 2>/dev/null || true)
    fi
}

# Runs "$@" as the service user with its user-session env, mirroring
# install.sh's as_service_user(). Returns 1 without running anything if the
# service account is gone in system mode (nothing to act on).
as_service_user() {
    if [[ "$MODE" == "system" ]]; then
        if [[ -z "$SERVICE_UID" ]]; then
            return 1
        fi
        runuser -u "$SERVICE_USER" -- env \
            XDG_RUNTIME_DIR="/run/user/${SERVICE_UID}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${SERVICE_UID}/bus" \
            "$@"
    else
        "$@"
    fi
}

# ============================================================================
# Uninstall Logic
# ============================================================================

stop_service() {
    info "Stopping searxng.service..."

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would run (as ${SERVICE_USER}): systemctl --user stop searxng.service"
        return 0
    fi

    if [[ "$MODE" == "system" && -z "$SERVICE_UID" ]]; then
        info "Service user '${SERVICE_USER}' not found; nothing to stop."
        return 0
    fi

    as_service_user systemctl --user stop searxng.service 2>/dev/null || true
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

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would run (as ${SERVICE_USER}): systemctl --user daemon-reload"
        return 0
    fi

    if [[ "$MODE" == "system" && -z "$SERVICE_UID" ]]; then
        info "Service user '${SERVICE_USER}' not found; skipping daemon-reload."
        return 0
    fi

    as_service_user systemctl --user daemon-reload 2>/dev/null || true
}

remove_container() {
    info "Removing container 'searxng' if it exists..."

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would run (as ${SERVICE_USER}): podman rm -f searxng"
        return 0
    fi

    if [[ "$MODE" == "system" && -z "$SERVICE_UID" ]]; then
        info "Service user '${SERVICE_USER}' not found; skipping container removal."
        return 0
    fi

    as_service_user podman rm -f searxng &>/dev/null || true
}

purge_image() {
    if [[ "$PURGE" != true || "$PURGE_IMAGE" != true ]]; then
        return 0
    fi

    info "Removing pulled image '${IMAGE_REF}'..."

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would run (as ${SERVICE_USER}): podman rmi ${IMAGE_REF}"
        return 0
    fi

    if [[ "$MODE" == "system" && -z "$SERVICE_UID" ]]; then
        info "Service user '${SERVICE_USER}' not found; skipping image removal."
        return 0
    fi

    as_service_user podman rmi "$IMAGE_REF" 2>/dev/null || \
        warn "Could not remove image '${IMAGE_REF}' (already gone, or still referenced)."
}

disable_auto_update() {
    if [[ "$DISABLE_AUTO_UPDATE" != true ]]; then
        # podman-auto-update.timer is shared across every quadlet the
        # service user runs, not something searxng-quadlet owns — leave it
        # alone unless explicitly asked to touch it.
        if [[ "$DRY_RUN" != true ]] && as_service_user systemctl --user is-enabled --quiet podman-auto-update.timer 2>/dev/null; then
            warn "podman-auto-update.timer is still enabled (left running — it may be used by other containers)."
            warn "Pass --disable-auto-update to disable it."
        fi
        return 0
    fi

    info "Disabling podman-auto-update.timer..."

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would run (as ${SERVICE_USER}): systemctl --user disable --now podman-auto-update.timer"
        return 0
    fi

    if [[ "$MODE" == "system" && -z "$SERVICE_UID" ]]; then
        info "Service user '${SERVICE_USER}' not found; skipping."
        return 0
    fi

    as_service_user systemctl --user disable --now podman-auto-update.timer 2>/dev/null || true
}

purge_state() {
    if [[ "$PURGE" != true ]]; then
        return 0
    fi

    info "Purging state directories..."

    if [[ ! -d "$STATE_DIR" ]]; then
        info "No state directory found to remove (${STATE_DIR})."
        return 0
    fi

    # Refuse to rm -rf a directory we didn't create ourselves — protects
    # against a mistyped --user/--state-dir pointing at something unrelated
    # (e.g. --user root would otherwise target /var/lib/root).
    if [[ ! -f "${STATE_DIR}/${MARKER_NAME}" ]]; then
        die "${STATE_DIR} has no ${MARKER_NAME} marker — refusing to purge a directory searxng-quadlet did not create. If this really is the right path, remove it manually."
    fi

    info "The following will be deleted:"
    info "  - ${STATE_DIR} (includes config/, data/, and the quadlet dir if nested under it)"

    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    if ! confirm "Proceed with purge of ${STATE_DIR}?"; then
        info "Purge cancelled."
        return 0
    fi

    rm -rf "$STATE_DIR"
    info "Removed: ${STATE_DIR}"
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

    if [[ -z "$SERVICE_UID" ]]; then
        info "User '${SERVICE_USER}' does not exist; nothing to remove."
        return 0
    fi

    info "Removing service user '${SERVICE_USER}'..."

    # List what will be removed
    info "This will delete:"
    info "  - User account: ${SERVICE_USER}"
    info "  - Home directory: $(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6 || echo "/var/lib/${SERVICE_USER}")"
    info "  - SubUID/SubGID ranges"

    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    if ! confirm "Proceed with user deletion?"; then
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
    resolve_service_uid

    if [[ "$DRY_RUN" == true ]]; then
        info "Dry run mode — no changes will be made."
        info "Mode: ${MODE}"
        info "Service User: ${SERVICE_USER}"
        info "State Dir: ${STATE_DIR}"
        info "Purge: $([[ $PURGE == true ]] && echo yes || echo no)"
        info "Purge Image: $([[ $PURGE_IMAGE == true ]] && echo yes || echo no)"
        info "Disable Auto Update: $([[ $DISABLE_AUTO_UPDATE == true ]] && echo yes || echo no)"
        echo ""
    else
        info "SearXNG Quadlet Uninstaller"
        info "==========================="
    fi

    stop_service
    remove_quadlet_files
    reload_daemon
    remove_container
    purge_image
    disable_auto_update
    purge_state
    disable_linger
    remove_user

    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

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
