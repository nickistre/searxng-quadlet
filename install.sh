#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# searxng-quadlet install.sh — Deploy a local SearXNG instance as a Podman quadlet service.
#
# Usage:
#   ./install.sh [OPTIONS]
#
# Options:
#   --mode system|user       Installation mode (default: system)
#   --user NAME              Service username (for --mode system)
#   --port N                 HTTP port (default: 9123)
#   --bind ADDR              Bind address (default: 127.0.0.1)
#   --image REF              Container image reference (default: docker.io/searxng/searxng:latest)
#   --base-url URL           Base URL for SEARXNG_BASE_URL (default: http://${BIND}:${PORT}/)
#   --state-dir PATH         State directory (default: varies by mode)
#   --instance-name TEXT     Instance name for settings.yml
#   --no-json                Disable JSON search format
#   --favicons               Enable favicon caching (writes favicons.toml)
#   --auto-update            Enable podman-auto-update.timer
#   --no-pull                Skip pre-pulling the image
#   --force-settings         Regenerate settings.yml (backs up existing)
#   --dry-run                Print the planned layout and rendered units/settings
#   -y, --yes                Answer yes to interactive prompts (unattended)
#   -h, --help               Show this help message

set -euo pipefail

# ============================================================================
# Constants & Defaults
# ============================================================================

readonly VERSION="1.0.1"
readonly APP_NAME="searxng"
readonly IMAGE_DEFAULT="docker.io/searxng/searxng:latest"
readonly PORT_DEFAULT=9123
readonly BIND_DEFAULT="127.0.0.1"
readonly USER_MODE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly USER_MODE_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
readonly MARKER_NAME=".searxng-quadlet"

# ============================================================================
# Global Variables (populated by arg parsing)
# ============================================================================

MODE="system"
USER_NAME=""
PORT=$PORT_DEFAULT
BIND="$BIND_DEFAULT"
IMAGE="$IMAGE_DEFAULT"
BASE_URL=""
STATE_DIR=""
INSTANCE_NAME=""
NO_JSON=false
FAVICONS=false
AUTO_UPDATE=false
NO_PULL=false
FORCE_SETTINGS=false
DRY_RUN=false
ASSUME_YES=false

# Derived variables (set after arg parsing)
SERVICE_USER=""
SERVICE_UID=""
CONFIG_DIR=""
DATA_DIR=""
SECRET_ENV=""
QUADLET_DIR=""
STATE_ROOT=""

# Podman major version (populated by check_podman; defaults to 0 so any
# ">= 5" guard safely falls through to the literal-ref path if unset)
PODMAN_MAJOR=0

# Set by dry_run_render: config/secret generators skip chown (the rendered
# files live in a scratch dir, and in --mode system the service user may not
# exist yet / we may not be root).
RENDER_ONLY=false

# Detected OS id (populated once by detect_os_id; used for package hints)
OS_ID=""

# ============================================================================
# Logging Helpers
# ============================================================================

log() {
    printf "[INFO] %s\n" "$*"
}

warn() {
    printf "[WARN] %s\n" "$*" >&2
}

die() {
    printf "[ERROR] %s\n" "$*" >&2
    exit 1
}

info() {
    printf "[*] %s\n" "$*"
}

# ============================================================================
# Argument Parsing
# ============================================================================

usage() {
    cat <<'EOF'
searxng-quadlet install.sh — Deploy a local SearXNG instance as a Podman quadlet service.

Usage:
  ./install.sh [OPTIONS]

Options:
  --mode system|user       Installation mode (default: system)
  --user NAME              Service username (for --mode system)
  --port N                 HTTP port (default: 9123)
  --bind ADDR              Bind address (default: 127.0.0.1)
  --image REF              Container image reference (default: docker.io/searxng/searxng:latest)
  --base-url URL           Base URL for SEARXNG_BASE_URL (default: http://${BIND}:${PORT}/)
  --state-dir PATH         State directory (default: varies by mode)
  --instance-name TEXT     Instance name for settings.yml
  --no-json                Disable JSON search format
  --favicons               Enable favicon caching (writes favicons.toml)
  --auto-update            Enable podman-auto-update.timer
  --no-pull                Skip pre-pulling the image
  --force-settings         Regenerate settings.yml (backs up existing)
  --dry-run                Print the planned layout and rendered units/settings
  -y, --yes                Answer yes to interactive prompts (unattended)
  -h, --help               Show this help message
EOF
    exit 0
}

need_arg() {
    # $1 = option name, $2 = remaining arg count after the option
    if (( $2 < 2 )); then
        die "Option $1 requires an argument."
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --mode)
                need_arg "$1" "$#"
                MODE="$2"
                shift 2
                ;;
            --user)
                need_arg "$1" "$#"
                USER_NAME="$2"
                shift 2
                ;;
            --port)
                need_arg "$1" "$#"
                PORT="$2"
                shift 2
                ;;
            --bind)
                need_arg "$1" "$#"
                BIND="$2"
                shift 2
                ;;
            --image)
                need_arg "$1" "$#"
                IMAGE="$2"
                shift 2
                ;;
            --base-url)
                need_arg "$1" "$#"
                BASE_URL="$2"
                shift 2
                ;;
            --state-dir)
                need_arg "$1" "$#"
                STATE_DIR="$2"
                shift 2
                ;;
            --instance-name)
                need_arg "$1" "$#"
                INSTANCE_NAME="$2"
                shift 2
                ;;
            --no-json)
                NO_JSON=true
                shift
                ;;
            --favicons)
                FAVICONS=true
                shift
                ;;
            --auto-update)
                AUTO_UPDATE=true
                shift
                ;;
            --no-pull)
                NO_PULL=true
                shift
                ;;
            --force-settings)
                FORCE_SETTINGS=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -y|--yes)
                ASSUME_YES=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    # Validate mode
    if [[ "$MODE" != "system" && "$MODE" != "user" ]]; then
        die "Invalid mode: $MODE (must be 'system' or 'user')"
    fi

    # Validate port
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        die "Invalid port: $PORT (must be an integer 1-65535)"
    fi

    # Validate bind address (IPv4, or bracketed/bare IPv6 — accepted loosely,
    # PublishPort= will reject anything actually malformed)
    if [[ -z "$BIND" ]]; then
        die "Invalid bind address: (empty)"
    fi

    if [[ "$MODE" == "user" && -n "$USER_NAME" ]]; then
        warn "--user is ignored in --mode user (the invoking user is always used)."
    fi

    # Set derived variables
    if [[ "$MODE" == "system" ]]; then
        SERVICE_USER="${USER_NAME:-searxng}"
        STATE_ROOT="/var/lib/${SERVICE_USER}"
        CONFIG_DIR="${STATE_ROOT}/config"
        DATA_DIR="${STATE_ROOT}/data"
        SECRET_ENV="${STATE_ROOT}/secret.env"
        QUADLET_DIR="${STATE_ROOT}/.config/containers/systemd"
    else
        SERVICE_USER="$(id -un)"
        STATE_ROOT="${USER_MODE_DATA}/${APP_NAME}"
        CONFIG_DIR="${STATE_ROOT}/config"
        DATA_DIR="${STATE_ROOT}/data"
        SECRET_ENV="${STATE_ROOT}/secret.env"
        QUADLET_DIR="${USER_MODE_CONFIG}/containers/systemd"
    fi

    # Apply --state-dir override if provided (same layout for both modes).
    # Note: the quadlet dir always moves under STATE_DIR too — in --mode user
    # this differs from the XDG-default layout, where quadlet units live
    # under $XDG_CONFIG_HOME regardless of where app state is rooted.
    if [[ -n "$STATE_DIR" ]]; then
        STATE_ROOT="$STATE_DIR"
        CONFIG_DIR="${STATE_DIR}/config"
        DATA_DIR="${STATE_DIR}/data"
        SECRET_ENV="${STATE_DIR}/secret.env"
        QUADLET_DIR="${STATE_DIR}/.config/containers/systemd"
    fi

    # Default base URL
    if [[ -z "$BASE_URL" ]]; then
        BASE_URL="http://${BIND}:${PORT}/"
    fi

    # Default instance name
    if [[ -z "$INSTANCE_NAME" ]]; then
        INSTANCE_NAME="SearXNG (local)"
    fi
}

# ============================================================================
# Preflight Checks
# ============================================================================

check_systemd() {
    info "Checking systemd..."
    if ! command -v systemctl &>/dev/null; then
        die "systemctl not found. Please install systemd."
    fi
}

# Populates the global OS_ID from /etc/os-release (ID=, falling back to the
# first token of ID_LIKE=). Safe to call unconditionally; idempotent.
detect_os_id() {
    OS_ID=""
    if [[ -f /etc/os-release ]]; then
        OS_ID=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
        if [[ -z "$OS_ID" ]]; then
            OS_ID=$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"' | awk '{print $1}')
        fi
    fi
}

# Resolves and returns the podman major version on stdout, using the
# structured `podman version` output where available (more portable than
# scraping `podman --version`, which needs PCRE-capable grep for -oP).
podman_major() {
    local v=""
    v=$(podman version --format '{{.Client.Version}}' 2>/dev/null || true)
    if [[ -z "$v" ]]; then
        v=$(podman --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -1)
    fi
    echo "${v%%.*}"
}

check_podman() {
    info "Checking podman..."
    detect_os_id

    if ! command -v podman &>/dev/null; then
        case "${OS_ID:-}" in
            fedora|rhel|centos|rocky|alma)
                die "podman not found. Install with: sudo dnf install -y podman"
                ;;
            debian|ubuntu)
                die "podman not found. Install with: sudo apt-get install -y podman"
                ;;
            arch|manjaro|endeavouros)
                die "podman not found. Install with: sudo pacman -S podman"
                ;;
            suse|opensuse*)
                die "podman not found. Install with: sudo zypper install -y podman"
                ;;
            *)
                die "podman not found. Please install Podman (https://podman.io)."
                ;;
        esac
    fi

    local podman_version major minor
    podman_version=$(podman --version | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -1)
    major=$(echo "$podman_version" | cut -d. -f1)
    minor=$(echo "$podman_version" | cut -d. -f2)
    # Publish for the generators (which run later in the same script)
    PODMAN_MAJOR="$major"

    if (( major < 4 || (major == 4 && minor < 4) )); then
        warn "Podman version ${podman_version} detected. Quadlet requires >= 4.4."
        warn "You may experience issues with older versions."
    fi

    if (( major < 5 )); then
        warn "Podman < 5.0 detected. Image pre-pull (--no-pull) will use literal ref instead of .image unit."
    fi

    # Check for the quadlet generator across the layouts distros use.
    local quadlet_found=false gen
    for gen in \
        /usr/lib/systemd/user-generators/podman-user-generator \
        /usr/lib64/systemd/user-generators/podman-user-generator \
        /usr/local/lib/systemd/user-generators/podman-user-generator \
        /usr/libexec/podman/quadlet
    do
        if [[ -f "$gen" ]]; then
            quadlet_found=true
            break
        fi
    done

    if [[ "$quadlet_found" != true ]]; then
        die "Podman quadlet generator not found (looked in /usr/lib*/systemd/user-generators/podman-user-generator and /usr/libexec/podman/quadlet). Ensure your podman package ships quadlet."
    fi

    # Check for newuidmap/newgidmap
    if ! command -v newuidmap &>/dev/null || ! command -v newgidmap &>/dev/null; then
        local pkg_hint=""
        case "${OS_ID:-}" in
            fedora|rhel|centos|rocky|alma) pkg_hint="shadow-utils" ;;
            debian|ubuntu) pkg_hint="uidmap" ;;
            arch|manjaro|endeavouros) pkg_hint="shadow" ;;
            suse|opensuse*) pkg_hint="shadow" ;;
        esac
        if [[ "$MODE" == "system" ]]; then
            die "newuidmap/newgidmap not found — required to allocate subuid ranges for the service user. Install package: ${pkg_hint:-shadow-utils}."
        else
            warn "newuidmap/newgidmap not found. Install package: ${pkg_hint:-shadow-utils} (rootless containers need subuid allocation)."
        fi
    fi

    if ! command -v curl &>/dev/null; then
        local curl_hint=""
        case "${OS_ID:-}" in
            fedora|rhel|centos|rocky|alma) curl_hint="sudo dnf install -y curl" ;;
            debian|ubuntu) curl_hint="sudo apt-get install -y curl" ;;
            arch|manjaro|endeavouros) curl_hint="sudo pacman -S curl" ;;
            suse|opensuse*) curl_hint="sudo zypper install -y curl" ;;
            *) curl_hint="install curl (https://curl.se)" ;;
        esac
        die "curl not found — required for the post-install health check. Install with: ${curl_hint}"
    fi

    podman --version
}

check_port() {
    info "Checking port ${BIND}:${PORT}..."

    # A re-run of the installer will see its own already-running instance
    # listening on the target port — that's not a conflict, so don't prompt.
    # (setup_service_account hasn't run yet, so in --mode system this only
    # detects an *existing* service user; a first-ever run has nothing to
    # find here anyway, which is fine — there's no prior instance to skip.)
    local existing_names=""
    if [[ "$MODE" == "system" ]]; then
        if id "$SERVICE_USER" &>/dev/null; then
            local svc_uid
            svc_uid=$(id -u "$SERVICE_USER")
            existing_names=$(runuser -u "$SERVICE_USER" -- env XDG_RUNTIME_DIR="/run/user/${svc_uid}" podman ps --format '{{.Names}}' 2>/dev/null || true)
        fi
    else
        existing_names=$(podman ps --format '{{.Names}}' 2>/dev/null || true)
    fi

    if grep -qx searxng <<< "$existing_names"; then
        info "Port check skipped: an existing 'searxng' container is already running (this looks like a re-run)."
        return 0
    fi

    if ss -ltn 2>/dev/null | grep -Eq "[:.]${PORT}([[:space:]]|$)"; then
        warn "Port ${PORT} appears to be in use:"
        ss -tlnp 2>/dev/null | grep -E "[:.]${PORT}([[:space:]]|$)" || true
        if [[ "$ASSUME_YES" == true ]]; then
            warn "Proceeding as requested (--yes)."
            return 0
        fi
        if [[ ! -t 0 ]]; then
            die "Port ${BIND}:${PORT} is in use and stdin is not a TTY. Stop the existing listener, or re-run with a different --port/--bind (or --yes to proceed)."
        fi
        read -rp "Continue anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# ============================================================================
# Account Setup (System Mode Only)
# ============================================================================

setup_service_account() {
    if [[ "$MODE" != "system" ]]; then
        return 0
    fi

    if (( EUID != 0 )); then
        die "--mode system requires root. Re-run with: sudo ./install.sh --mode system"
    fi

    info "Setting up service account '${SERVICE_USER}'..."

    # Check if user exists
    if id "$SERVICE_USER" &>/dev/null; then
        info "User '${SERVICE_USER}' already exists."
        SERVICE_UID=$(id -u "$SERVICE_USER")
    else
        # Find nologin shell
        local nologin_shell=""
        for shell in /usr/sbin/nologin /sbin/nologin /bin/false; do
            if [[ -x "$shell" ]]; then
                nologin_shell="$shell"
                break
            fi
        done

        if [[ -z "$nologin_shell" ]]; then
            die "No nologin shell found. Cannot create service user."
        fi

        info "Creating system user '${SERVICE_USER}'..."
        useradd --system --create-home --home-dir "$STATE_ROOT" --shell "$nologin_shell" "$SERVICE_USER"
        SERVICE_UID=$(id -u "$SERVICE_USER")
    fi

    # Allocate subuids/subgids if needed
    allocate_subids

    # Enable lingering (so the user manager + dbus socket exist at boot)
    if ! command -v loginctl &>/dev/null; then
        die "loginctl not found — cannot enable lingering (the service would not auto-start at boot)."
    fi
    info "Enabling lingering for '${SERVICE_USER}'..."
    loginctl enable-linger "$SERVICE_USER"

    # Wait for dbus socket
    local bus_path="/run/user/${SERVICE_UID}/bus"
    info "Waiting for dbus socket at ${bus_path}..."
    local waited=0
    while [[ ! -S "$bus_path" ]] && (( waited < 30 )); do
        sleep 1
        waited=$((waited + 1))
    done

    if [[ ! -S "$bus_path" ]]; then
        die "dbus socket ${bus_path} did not appear within 30s after enable-linger. Check logind: journalctl -u systemd-logind -n 30"
    fi
    info "dbus socket ready."
}

allocate_subids() {
    if [[ "$MODE" != "system" ]]; then
        return 0
    fi

    info "Allocating subuid/subgid range for '${SERVICE_USER}'..."

    # Check if already allocated
    if grep -q "^${SERVICE_USER}:" /etc/subuid 2>/dev/null; then
        info "SubUID range already allocated for '${SERVICE_USER}'."
        return 0
    fi

    # Find highest end value across ALL users in BOTH files.
    # (Scanning only /etc/subuid could allocate a range that collides with a
    # /etc/subgid entry, silently breaking the allocated subgid map.)
    local max_end=0 line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        local start count
        IFS=: read -r _ start count <<< "$line"
        [[ -n "${start:-}" && -n "${count:-}" ]] || continue
        local end=$((start + count - 1))
        if (( end > max_end )); then
            max_end=$end
        fi
    done < <(cat /etc/subuid /etc/subgid 2>/dev/null)

    # Round up to next 65536 boundary
    local new_start=$(( ((max_end / 65536) + 1) * 65536 ))
    local new_end=$((new_start + 65535))

    info "Allocating range ${new_start}-${new_end} (after current max: ${max_end})"

    usermod --add-subuids "${new_start}-${new_end}" --add-subgids "${new_start}-${new_end}" "$SERVICE_USER"
    info "SubUID/SubGID range allocated."
}

# ============================================================================
# State Directory Setup
# ============================================================================

setup_state_dirs() {
    info "Setting up state directories..."

    if [[ "$MODE" == "system" ]]; then
        install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$CONFIG_DIR"
        install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DATA_DIR"
    else
        install -d -m 0755 "$CONFIG_DIR"
        install -d -m 0755 "$DATA_DIR"
    fi

    install -d -m 0755 "$QUADLET_DIR"

    if [[ "$MODE" == "system" ]]; then
        # `install -d` only sets owner/mode on the leaf directory it creates,
        # not on intermediate parents (e.g. .config, .config/containers) —
        # chown the whole state tree so the service user owns everything
        # under it, matching the design (one useradd, one chown).
        chown -R "${SERVICE_USER}:${SERVICE_USER}" "$STATE_ROOT"
    fi

    # Drop a marker so uninstall.sh --purge can confirm a directory it is
    # about to rm -rf is actually one we created, not e.g. a caller-supplied
    # --state-dir/--user that happens to collide with something else.
    printf '%s\n' "searxng-quadlet state root — safe to remove with uninstall.sh --purge" \
        > "${STATE_ROOT}/${MARKER_NAME}"
    if [[ "$MODE" == "system" ]]; then
        chown "${SERVICE_USER}:${SERVICE_USER}" "${STATE_ROOT}/${MARKER_NAME}"
    fi

    log "Config dir: ${CONFIG_DIR}"
    log "Data dir:   ${DATA_DIR}"
    log "Quadlet:    ${QUADLET_DIR}"
}

# ============================================================================
# Configuration Generation
# ============================================================================

generate_settings_yml() {
    local settings_file="${CONFIG_DIR}/settings.yml"

    if [[ -f "$settings_file" ]] && [[ "$FORCE_SETTINGS" != true ]]; then
        info "settings.yml already exists. Skipping (use --force-settings to regenerate)."
        return 0
    fi

    info "Generating settings.yml..."

    if [[ -f "$settings_file" ]]; then
        mv "$settings_file" "${settings_file}.bak-$(date +%s)"
        info "Backed up existing settings.yml"
    fi

    # Build formats array
    local formats=("html")
    if [[ "$NO_JSON" != true ]]; then
        formats+=("json")
    fi

    # Format formats as YAML list
    local formats_yaml=""
    for f in "${formats[@]}"; do
        formats_yaml+="    - ${f}\n"
    done

    cat > "$settings_file" <<EOF
# Managed by searxng-quadlet install.sh — re-run with --force-settings to regenerate.
use_default_settings: true

general:
  instance_name: "${INSTANCE_NAME}"

server:
  image_proxy: true
  method: "GET"
  limiter: false

search:
  safe_search: 0
  autocomplete: "duckduckgo"
  default_lang: "auto"
  formats:
$(echo -e "$formats_yaml" | sed '/^$/d')
$(if [[ "$FAVICONS" == true ]]; then echo '  favicon_resolver: "duckduckgo"'; fi)

ui:
  default_theme: simple
  static_hash: true

engines:
  - name: duckduckgo
    disabled: false
  - name: wikipedia
    disabled: false
  - name: google
    disabled: false
  - name: bing
    disabled: false
  - name: brave
    disabled: false
  - name: youtube
    disabled: true
EOF

    chmod 0644 "$settings_file"
    if [[ "$MODE" == "system" && "$RENDER_ONLY" != true ]]; then
        chown "${SERVICE_USER}:${SERVICE_USER}" "$settings_file"
    fi

    log "Written: ${settings_file}"
}

generate_favicons_toml() {
    if [[ "$FAVICONS" != true ]]; then
        return 0
    fi

    local favicons_file="${CONFIG_DIR}/favicons.toml"

    if [[ -f "$favicons_file" ]]; then
        info "favicons.toml already exists. Skipping."
        return 0
    fi

    info "Generating favicons.toml..."

    # db_url is resolved by SearXNG *inside* the container, whose view of
    # DATA_DIR is always /var/cache/searxng (the Volume= target below) — not
    # the host-side DATA_DIR path, which the container never sees.
    cat > "$favicons_file" <<EOF
[favicons]
cfg_schema = 1

[favicons.cache]
db_url = "/var/cache/searxng/faviconcache.db"
HOLD_TIME = 5184000
LIMIT_TOTAL_BYTES = 209715200
EOF

    chmod 0644 "$favicons_file"
    if [[ "$MODE" == "system" && "$RENDER_ONLY" != true ]]; then
        chown "${SERVICE_USER}:${SERVICE_USER}" "$favicons_file"
    fi

    log "Written: ${favicons_file}"
}

generate_secret_env() {
    if [[ -f "$SECRET_ENV" ]]; then
        info "secret.env already exists. Skipping generation."
        return 0
    fi

    info "Generating secret.env..."

    local secret=""
    if command -v openssl &>/dev/null; then
        secret=$(openssl rand -hex 32)
    elif [[ -r /dev/urandom ]]; then
        # /dev/urandom is a character device, not a regular file — test with
        # -r, not -f (which is always false for it).
        secret=$(od -An -tx1 -N 32 /dev/urandom | tr -d ' \n')
    elif command -v python3 &>/dev/null; then
        secret=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
    else
        die "Cannot generate random bytes. None of openssl, /dev/urandom, or python3 available."
    fi

    cat > "$SECRET_ENV" <<EOF
SEARXNG_SECRET=${secret}
EOF

    chmod 0600 "$SECRET_ENV"
    if [[ "$MODE" == "system" && "$RENDER_ONLY" != true ]]; then
        chown "${SERVICE_USER}:${SERVICE_USER}" "$SECRET_ENV"
    fi

    log "Written: ${SECRET_ENV}"
}

# ============================================================================
# Quadlet File Generation
# ============================================================================

generate_container_unit() {
    local container_file="${QUADLET_DIR}/searxng.container"

    info "Generating searxng.container..."

    local image_ref
    if [[ "$NO_PULL" != true ]] && (( PODMAN_MAJOR >= 5 )); then
        # .image unit pre-pulls (and, with the auto-update timer, refreshes) the image.
        image_ref="searxng.image"
    else
        # No .image unit (--no-pull, or podman < 5): point directly at the
        # (possibly --image-overridden) ref so the container unit is self-contained.
        image_ref="$IMAGE"
    fi

    cat > "$container_file" <<EOF
[Unit]
Description=SearXNG local metasearch engine
After=network-online.target
Wants=network-online.target

[Container]
ContainerName=searxng
Image=${image_ref}
AutoUpdate=registry
PublishPort=${BIND}:${PORT}:8080
Volume=${CONFIG_DIR}:/etc/searxng:ro,Z
Volume=${DATA_DIR}:/var/cache/searxng:Z
EnvironmentFile=${SECRET_ENV}
Environment=SEARXNG_BASE_URL=${BASE_URL}
Environment=SEARXNG_LIMITER=false
Environment=FORCE_OWNERSHIP=false
Memory=1g
PidsLimit=100
HealthCmd=wget -qO /dev/null http://127.0.0.1:8080/healthz || exit 1
HealthInterval=1m
HealthStartPeriod=30s

[Service]
Restart=on-failure
RestartSec=10
TimeoutStartSec=900

[Install]
WantedBy=default.target
EOF

    chmod 0644 "$container_file"
    log "Written: ${container_file}"
}

generate_image_unit() {
    if [[ "$NO_PULL" == true ]]; then
        return 0
    fi

    local major
    major=$(podman_major)

    if (( major < 5 )); then
        info "Podman < 5.0 detected. Skipping .image unit (literal ref used in .container)."
        return 0
    fi

    local image_file="${QUADLET_DIR}/searxng.image"

    info "Generating searxng.image..."

    cat > "$image_file" <<EOF
[Image]
Image=${IMAGE}

[Service]
TimeoutStartSec=900

[Install]
WantedBy=default.target
EOF

    chmod 0644 "$image_file"
    log "Written: ${image_file}"
}

# ============================================================================
# Activation
# ============================================================================

as_service_user() {
    if [[ "$MODE" == "system" ]]; then
        runuser -u "$SERVICE_USER" -- env XDG_RUNTIME_DIR=/run/user/"$SERVICE_UID" DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/"$SERVICE_UID"/bus "$@"
    else
        "$@"
    fi
}

activate_services() {
    info "Reloading systemd user services..."
    as_service_user systemctl --user daemon-reload

    # On a re-run the unit files and/or settings.yml may have just been
    # rewritten while the service was already active — `start` is then a
    # no-op and the new config never takes effect. Restart in that case.
    if as_service_user systemctl --user is-active --quiet searxng.service; then
        info "Restarting searxng.service (already running)..."
        as_service_user systemctl --user restart searxng.service
    else
        info "Starting searxng.service..."
        as_service_user systemctl --user start searxng.service
    fi

    if [[ "$AUTO_UPDATE" == true ]]; then
        info "Enabling podman-auto-update.timer..."
        as_service_user systemctl --user enable --now podman-auto-update.timer
    fi
}

# ============================================================================
# Health Check
# ============================================================================

dump_journal() {
    warn "Last 50 journal lines for searxng.service:"
    as_service_user journalctl --user -u searxng.service -n 50 --no-pager || true
    warn "Likely causes:"
    warn "  - Port ${BIND}:${PORT} conflict (ss -ltnp)"
    warn "  - SELinux denials (sudo ausearch -m avc -ts recent)"
    warn "  - Invalid settings.yml (podman exec searxng cat /etc/searxng/settings.yml)"
    warn "  - Image pull failed or registry unreachable"
}

perform_health_check() {
    info "Performing health check (up to 180s)..."

    local url="http://${BIND}:${PORT}/"
    local json_url="http://${BIND}:${PORT}/search?q=test&format=json"

    local waited=0
    while (( waited < 180 )); do
        if curl -fsS "$url" &>/dev/null; then
            info "HTTP check passed."
            break
        fi

        if (( waited == 0 )); then
            info "Waiting for SearXNG to start..."
        fi

        sleep 5
        waited=$((waited + 5))
    done

    if (( waited >= 180 )); then
        warn "Health check timed out after 180s."
        dump_journal
        return 1
    fi

    # Test JSON API
    info "Testing JSON API..."
    local response
    response=$(curl -fsS "$json_url" 2>&1) || {
        warn "JSON API request failed (check search.formats in settings.yml — json must be enabled)."
        dump_journal
        return 1
    }

    # Validate the response actually contains results (the whole point of the
    # JSON check — a defect #1 regression would otherwise slip through).
    if command -v python3 &>/dev/null; then
        if printf '%s' "$response" | python3 -c '
import json, sys
d = json.load(sys.stdin)
results = d.get("results")
assert isinstance(results, list) and len(results) > 0, "no results returned"
'; then
            info "JSON API validated (non-empty results)."
        else
            warn "JSON API response had no results or was not valid JSON."
            warn "Response snippet: $(printf '%s' "$response" | head -c 200)"
            return 1
        fi
    else
        warn "python3 not found; skipping JSON body validation (HTTP 200 confirmed)."
    fi
    return 0
}

# ============================================================================
# Summary
# ============================================================================

print_summary() {
    echo ""
    echo "=========================================="
    echo "  SearXNG Installation Complete"
    echo "=========================================="
    echo ""
    echo "  Instance:     ${INSTANCE_NAME}"
    echo "  URL:          ${BASE_URL}"
    echo "  Bind:         ${BIND}:${PORT}"
    echo "  Mode:         ${MODE}"
    echo "  Image:        ${IMAGE}"
    echo ""
    echo "  State Directory:  ${STATE_ROOT}"
    echo "  Config:           ${CONFIG_DIR}"
    echo "  Data:             ${DATA_DIR}"
    echo ""
    echo "  Management Commands:"
    echo "    Status:   systemctl --user status searxng.service"
    echo "    Logs:     journalctl --user -u searxng.service -f"
    echo "    Restart:  systemctl --user restart searxng.service"
    echo "    Stop:     systemctl --user stop searxng.service"
    echo ""
    echo "  MCP Integration:"
    echo "    Endpoint: http://${BIND}:${PORT}/search"
    echo "    Format:   ?q=<query>&format=json"
    echo "    Response: {\"results\": [{\"title\", \"url\", \"content\", \"engine\", \"score\", \"category\"}]}"
    echo ""
    echo "  Edit settings.yml and restart to apply changes."
    echo ""
}

# ============================================================================
# Dry-run artifact rendering (shows what would be written; touches no real state)
# ============================================================================

dry_run_render() {
    # Resolve podman major version for the .image/literal-ref decision.
    if command -v podman &>/dev/null; then
        PODMAN_MAJOR=$(podman_major)
    fi

    # Rendered files live in a scratch dir and nothing here is chowned —
    # RENDER_ONLY makes that explicit so this never touches a real uid,
    # whether or not the service user exists yet (--mode system dry-run
    # needs no root and must not require the account to pre-exist).
    RENDER_ONLY=true

    local tmpdir saved_config saved_quadlet f
    tmpdir=$(mktemp -d)
    saved_config="$CONFIG_DIR"
    saved_quadlet="$QUADLET_DIR"
    CONFIG_DIR="${tmpdir}/config"; mkdir -p "$CONFIG_DIR"
    QUADLET_DIR="${tmpdir}/quadlet"; mkdir -p "$QUADLET_DIR"

    generate_settings_yml
    generate_favicons_toml
    generate_container_unit
    generate_image_unit

    CONFIG_DIR="$saved_config"
    QUADLET_DIR="$saved_quadlet"
    RENDER_ONLY=false

    for f in "${tmpdir}/config/settings.yml" "${tmpdir}/config/favicons.toml" \
             "${tmpdir}/quadlet/searxng.container" "${tmpdir}/quadlet/searxng.image"; do
        if [[ -f "$f" ]]; then
            local rel="${f#"${tmpdir}"/}"
            echo ""
            echo "----- ${rel} -----"
            cat "$f"
        fi
    done
    rm -rf "$tmpdir"
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
        info "Config Dir: ${CONFIG_DIR}"
        info "Data Dir: ${DATA_DIR}"
        info "Quadlet Dir: ${QUADLET_DIR}"
        info "Port: ${PORT}, Bind: ${BIND}"
        info "Image: ${IMAGE}"
        info "Base URL: ${BASE_URL}"
        info "Instance Name: ${INSTANCE_NAME}"
        info "JSON enabled: $([[ $NO_JSON == true ]] && echo no || echo yes)"
        info "Favicons: $([[ $FAVICONS == true ]] && echo yes || echo no)"
        info "Auto Update: $([[ $AUTO_UPDATE == true ]] && echo yes || echo no)"
        info "Force Settings: $([[ $FORCE_SETTINGS == true ]] && echo yes || echo no)"
        info "No Pull: $([[ $NO_PULL == true ]] && echo yes || echo no)"

        dry_run_render
        return 0
    fi

    info "SearXNG Quadlet Installer v${VERSION}"
    info "============================================="

    check_systemd
    check_podman
    check_port

    setup_service_account
    setup_state_dirs

    generate_settings_yml
    generate_favicons_toml
    generate_secret_env

    generate_container_unit
    generate_image_unit

    activate_services

    perform_health_check || die "SearXNG did not come up — see the journal output above."

    print_summary

    log "Installation complete!"
}

main "$@"
