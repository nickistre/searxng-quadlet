# SearXNG Quadlet Installer

A self-contained installer for deploying a local SearXNG instance as a Podman quadlet service on systemd-based Linux systems.

## Features

- **Dual installation modes**: System-wide (`--mode system`) or per-user (`--mode user`)
- **Self-contained**: All configuration templates embedded in the installer
- **Idempotent**: Safe to re-run without corrupting existing state
- **Automatic updates**: Optional `podman-auto-update.timer` integration
- **Health monitoring**: Built-in startup validation with retry logic
- **SELinux-aware**: Uses `:Z` mount options for proper context labeling
- **Subuid allocation**: Automatic range assignment for rootless containers

## Quick Start

```bash
# Install for current user (no root required)
./install.sh --mode user

# Install as dedicated system service (requires root)
sudo ./install.sh --mode system

# Verify it's working
curl -fsS 'http://127.0.0.1:9123/search?q=test&format=json' | python3 -m json.tool

# View logs
journalctl --user -u searxng.service -f
```

## Installation Modes

### `--mode user` (Default)

Installs into the invoking user's home directory. No root privileges required.

- **Config dir**: `${XDG_DATA_HOME:-~/.local/share}/<user>/config`
- **Data dir**: `${XDG_DATA_HOME:-~/.local/share}/<user>/data`
- **Secret env**: `${XDG_DATA_HOME:-~/.local/share}/<user>/secret.env`
- **Quadlet dir**: `${XDG_CONFIG_HOME:-~/.config}/containers/systemd`

### `--mode system`

Creates a dedicated system user (`searxng` by default). Requires root.

- **Home**: `/var/lib/searxng`
- **Config**: `/var/lib/searxng/config`
- **Data**: `/var/lib/searxng/data`
- **Secret env**: `/var/lib/searxng/secret.env`
- **Quadlet**: `/var/lib/searxng/.config/containers/systemd`

Automatically allocates subuid/subgid ranges and enables lingering for automatic startup.

## Command-Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `--mode system\|user` | Installation mode | `system` |
| `--user NAME` | Service username (system mode only) | `searxng` |
| `--port N` | HTTP port | `9123` |
| `--bind ADDR` | Bind address | `127.0.0.1` |
| `--image REF` | Container image reference | `docker.io/searxng/searxng:latest` |
| `--base-url URL` | Base URL for `SEARXNG_BASE_URL` | `http://<bind>:<port>/` |
| `--state-dir PATH` | Override state directory | (mode-specific) |
| `--instance-name TEXT` | Instance name for settings.yml | `SearXNG (local)` |
| `--no-json` | Disable JSON search format | Enabled by default |
| `--favicons` | Enable favicon caching | Disabled |
| `--auto-update` | Enable `podman-auto-update.timer` | Disabled |
| `--no-pull` | Skip pre-pulling the image | Pulled automatically |
| `--force-settings` | Regenerate `settings.yml` (backs up existing) | Keep existing |
| `--dry-run` | Print the planned layout and render units/settings | Execute |
| `-y`, `--yes` | Answer yes to interactive prompts (unattended / non-TTY) | Prompt |
| `-h`, `--help` | Show help message | |

## Configuration

### `settings.yml`

The installer generates a corrected `settings.yml` that fixes known issues from upstream documentation:

- ✅ **JSON format enabled** by default (fixes `format=json` returning 403)
- ✅ **Correct engine names** (`brave` not `brave_search`)
- ✅ **Proper favicon resolver** configuration (uses TOML cache)
- ✅ **No inert bind_address/port** settings (Granian uses env vars)

Edit `config/settings.yml` directly to customize. Changes take effect on next restart.

### `secret.env`

Contains `SEARXNG_SECRET=<64-hex>` for session signing. Generated automatically on first install. **Never committed to version control.**

### `favicons.toml`

Only created with `--favicons`. Enables favicon caching via DuckDuckGo resolver.

## Management Commands

```bash
# Check status
systemctl --user status searxng.service

# View logs
journalctl --user -u searxng.service -f

# Restart after config changes
systemctl --user restart searxng.service

# Stop the service
systemctl --user stop searxng.service

# Check resource limits applied
podman stats --no-stream searxng

# Inspect container
podman exec searxng cat /etc/searxng/settings.yml
```

## Uninstallation

```bash
# Remove service (preserves state)
./uninstall.sh --mode user

# Full purge (removes state and service account)
sudo ./uninstall.sh --mode system --purge
```

With `--purge`:
- Removes state directories (`config/`, `data/`)
- Disables lingering for the service user
- Deletes the service user account
- Prints exactly what will be deleted before proceeding

Without `--purge`:
- Stops and removes the service
- Removes quadlet files
- Preserves all state for future reinstall

## Differences from Wiki Documentation

This installer corrects seven documented defects from the wiki page:

| # | Wiki says | Reality | Fix |
|---|-----------|---------|-----|
| 1 | "JSON output … No config change required" | `search.formats` defaults to `[html]` only | **`json` enabled by default** |
| 2 | `- name: brave_search` | Engine is named `brave` | Corrected in generated `settings.yml` |
| 3 | `favicon: driver: "filesystem"` | Favicon cache is TOML, enabled via `search.favicon_resolver` | Proper TOML config with `--favicons` flag |
| 4 | `[Service] Memory=1g` / `PidsLimit=100` | These are `[Container]` keys | Moved to correct section |
| 5 | `settings.yml` written to quadlet dir | Container mounts named volume | **Bind mounts used instead** |
| 6 | `useradd --no-create-home` + nologin shell | Rootless needs home dir + subuids | `--create-home` + auto subid allocation |
| 7 | `systemctl enable searxng.service` | Quadlet units cannot be enabled | `[Install] WantedBy=` handles this |

Additional corrections:
- Removed inert `server.bind_address: "127.0.0.1"` (Granian uses `GRANIAN_HOST`)
- `wget` is available in the current image (confirmed) and `/healthz` returns 200, so the in-container health check works

## MCP / Agent Integration

SearXNG exposes a JSON API compatible with MCP-style tool calling:

```bash
curl -fsS 'http://127.0.0.1:9123/search?q=your+query&format=json'
```

Response shape:
```json
{
  "results": [
    {
      "title": "...",
      "url": "...",
      "content": "...",
      "engine": "duckduckgo",
      "score": 0.95,
      "category": "general"
    }
  ]
}
```

## Troubleshooting

### Port already in use
```bash
ss -tlnp | grep :9123
# Or choose a different port:
./install.sh --port 9124
```

### Service won't start
```bash
journalctl --user -u searxng.service -n 50
# Common causes:
# - Port conflict
# - SELinux denials (check with: sudo ausearch -m avc -ts recent)
# - Missing dependencies (newuidmap/newgidmap)
```

### JSON API returns 403
Verify `settings.yml` contains:
```yaml
search:
  formats:
    - html
    - json
```

### Health check times out
First pull can take several minutes. The installer waits up to 180s. If it still fails:
```bash
# Check if container is running
podman ps -qf name=searxng

# Enter container shell
podman exec -it searxng /bin/sh

# Test Granian directly
wget -qO- http://127.0.0.1:8080/healthz
```

### SELinux permission errors
The installer uses `:Z` mount option for private labeling. If you still see denials:
```ini
# Add to searxng.container [Container] section:
PodmanArgs=--security-opt label=type:container_runtime_t
```

Then rebuild:
```bash
systemctl --user restart searxng.service
```

## System Requirements

- **OS**: Any systemd-based Linux (Fedora, Debian, Ubuntu, Arch, etc.)
- **Podman**: ≥ 4.4 (recommended: ≥ 5.0 for `.image` unit support)
- **Systemd**: User-level services enabled
- **Disk**: ~1GB for image + cache (varies by usage)
- **RAM**: 1GB recommended (enforced via `Memory=1g`)
- **Root**: Only for `--mode system`; `--mode user` runs entirely unprivileged

## Security Considerations

- `settings.yml` is mounted read-only (`ro,Z`) — a compromised instance cannot modify its own config
- `secret.env` is excluded from container mounts — secrets never touch the container filesystem
- Host directories are owned by the service user — no root access needed inside the container
- Published port defaults to `127.0.0.1` — not exposed to the network

## License

MIT

## Credits

Based on community deployments and upstream SearXNG documentation. Corrects known issues with the official wiki guide.
