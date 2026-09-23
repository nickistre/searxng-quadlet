# SearXNG Quadlet Installer

A self-contained installer for deploying a local SearXNG instance as a Podman quadlet service on systemd-based Linux systems.

This is an off-network fallback: prefer the cluster instance at
`mcp-searxng.house.nickistre.net` when it's reachable, and fall back to a local deployment
from this repo when it isn't (e.g. off the home network).

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

### `--mode system` (Default)

Creates a dedicated system user (`searxng` by default). Requires root.

- **Home**: `/var/lib/searxng`
- **Config**: `/var/lib/searxng/config`
- **Data**: `/var/lib/searxng/data`
- **Secret env**: `/var/lib/searxng/secret.env`
- **Quadlet**: `/var/lib/searxng/.config/containers/systemd`

Automatically allocates subuid/subgid ranges and enables lingering for automatic startup.

### `--mode user`

Installs into the invoking user's own XDG directories. No root privileges required.

- **Config dir**: `${XDG_DATA_HOME:-~/.local/share}/searxng/config`
- **Data dir**: `${XDG_DATA_HOME:-~/.local/share}/searxng/data`
- **Secret env**: `${XDG_DATA_HOME:-~/.local/share}/searxng/secret.env`
- **Quadlet dir**: `${XDG_CONFIG_HOME:-~/.config}/containers/systemd`

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

**Behavior notes:**
- Re-running the installer always rewrites the quadlet unit files and restarts the service
  if it's already running; only `settings.yml`, `favicons.toml`, and `secret.env` are
  preserved across re-runs (unless `--force-settings` is given).
- With Podman < 5.0, there is no `.image` unit — the container unit references the image
  literally instead, and `--no-pull` has no separate effect.
- `--no-pull` only skips the *pre*-pull `.image` unit; Podman still pulls the image on
  first container start if it isn't already present locally.

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

# Full purge (removes state and service account), unattended
sudo ./uninstall.sh --mode system --purge -y
```

| Option | Description |
|--------|-------------|
| `--mode system\|user` | Installation mode (default: `system`) |
| `--user NAME` | Service username (system mode only) |
| `--state-dir PATH` | Must match whatever `--state-dir` install.sh was given, if any |
| `--purge` | Remove state directories and (system mode) the service account |
| `--purge-image` | With `--purge`, also `podman rmi` the pulled image |
| `--image REF` | Image ref for `--purge-image` (must match install.sh's `--image`) |
| `--disable-auto-update` | Also disable `podman-auto-update.timer` |
| `-y`, `--yes` | Answer yes to interactive prompts (unattended) |
| `--dry-run` | Print actions without executing |

With `--purge`:
- Removes the whole state directory (`config/`, `data/`, `secret.env`)
- Disables lingering for the service user (system mode)
- Deletes the service user account (system mode)
- Prints exactly what will be deleted before proceeding, and refuses to remove a directory
  that doesn't carry the marker file `install.sh` leaves in the state root — protects
  against a mistyped `--user`/`--state-dir` pointing at an unrelated path

Without `--purge`:
- Stops and removes the service
- Removes quadlet files
- Preserves all state for future reinstall

`podman-auto-update.timer` is shared across every quadlet the service user runs, so it's
left alone unless you pass `--disable-auto-update`; without the flag, uninstall just warns
if it's still enabled.

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

## Differences from Wiki Documentation

The [wiki write-up](https://llm-wiki.house.nickistre.net/wiki/concepts/searxng-hina-local-deployment/)
this installer is based on has seven defects that would otherwise leave `format=json`
returning 403, the install failing partway through, or settings being silently ignored.
This installer corrects all of them:

| # | Wiki says | Reality | Fix |
|---|-----------|---------|-----|
| 1 | "JSON output … No config change required" | `search.formats` defaults to `[html]` only | `json` enabled by default in the generated `settings.yml` |
| 2 | `- name: brave_search` | The engine is named `brave` | Corrected in the generated `settings.yml` |
| 3 | `favicon: driver: "filesystem"` | No such setting; the favicon cache is a TOML file enabled via `search.favicon_resolver` | Proper `favicons.toml` written with `--favicons` |
| 4 | `[Service] Memory=1g` / `PidsLimit=100` | These are `[Container]` keys, not `[Service]` keys | Moved to the correct section |
| 5 | `settings.yml` written to the quadlet dir while the container mounts a named volume | The file never reaches the container | Bind mounts used instead, so `config/settings.yml` is what the container actually sees |
| 6 | `useradd --no-create-home` + a nologin shell | Rootless quadlets need a home dir, `loginctl enable-linger`, and allocated `/etc/subuid`/`/etc/subgid` ranges | `--create-home` + automatic subuid/subgid allocation + `enable-linger` |
| 7 | `systemctl --user enable searxng.service` | Quadlet-generated units can't be `enable`d | Skipped — `[Install] WantedBy=default.target` already wires it up; the installer only ever `start`s (or `restart`s on re-run) |

Also fixed: the wiki's `server.bind_address: "127.0.0.1"` setting is inert (the image runs
Granian, which binds via `GRANIAN_HOST`) — localhost-only exposure comes from
`PublishPort=127.0.0.1:...` instead, and this installer omits the dead setting.

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
The installer uses the `:Z` mount option, which asks Podman to relabel `config/` and
`data/` with a private container context on every start. If you still see AVC denials:

```bash
# See exactly what was denied
sudo ausearch -m avc -ts recent

# Confirm the mounts actually got relabeled
ls -Zd /var/lib/searxng/config /var/lib/searxng/data   # or your --state-dir/--mode user paths
```

If the context still looks wrong, a manual relabel usually fixes it:
```bash
sudo chcon -Rt container_file_t /var/lib/searxng/config /var/lib/searxng/data
```

As a last resort you can disable SELinux separation for just this container by adding to
the `[Container]` section of `searxng.container` — this loosens confinement, so prefer the
`ausearch`/`chcon` fixes above first:
```ini
PodmanArgs=--security-opt label=disable
```

Then reload and restart:
```bash
systemctl --user daemon-reload
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
