# CybrexTech OS - Release Notes

**Version**: 1.1.0-alpha
**Codename**: Obsidian Green

---

## Overview

CybrexTech OS is a custom, single-owner platform built on Debian Stable,
designed for high-security development and daily use.

---

## What's New in v1.1.0

### Security
- **Kernel hardening**: `/etc/sysctl.d/99-cybrex-hardening.conf` is now shipped
  and applied on every boot via `systemd-sysctl`. Covers network hardening
  (SYN cookies, martian logging, no IP forwarding), memory protections
  (ASLR full, ptrace restrict, kptr restrict, dmesg restrict), and more.
- **nftables enabled on boot**: `nftables.service` is now explicitly enabled
  during image build so the deny-all-inbound ruleset is active from first boot.

### Control Layer
- `cybrex-ctl` upgraded to **v1.1.0**:
  - `power [saver|balanced|performance]`: now writes the CPU frequency
    governor and toggles Intel P-State turbo boost from `/etc/cybrex/power.toml`.
  - `firewall [status|reload|flush]`: sub-command to inspect, reload or flush
    the nftables ruleset.
  - `logs [N]`: tail the cybrex ctl log and the daemon journal.
  - `health`: health check for kernel, disk, memory, services,
    and sysctl hardening validation.
  - `security`: expanded audit for failed SSH logins, open ports, SUID binaries,
    and sudo grants.
  - Removed `set -e` global flag (replaced with `set -uo pipefail`) to prevent
    early exits from non-fatal read operations.

### Daemon
- `cybrex-daemon` rewritten with proper endpoints:
  - `GET /api/health` - liveness probe.
  - `POST /api/power` - switch power profile via the daemon API.
  - Config refresh interval reduced to 5 s.
  - Uses `BaseHTTPRequestHandler` with explicit Content-Length for correct
    HTTP/1.1 compliance.
- `cybrex-daemon.service` fixed: was incorrectly running `cybrex-ctl status`;
  now correctly runs `/usr/bin/python3 /usr/local/bin/cybrex-daemon`.

### Maintenance
- **Log rotation**: `/etc/logrotate.d/cybrex` - daily rotation, 14-day retention,
  compressed, with post-rotate daemon SIGHUP.
- **Auto-update timer**: `cybrex-update.service` + `cybrex-update.timer` provide
  weekly unattended upgrades (enabled during image build).
- **`.gitignore`** added: excludes `build_vm/`, `artifacts/`, `*.img`, `*.vmdk`,
  `*.iso`, VMware runtime files, Python bytecode, and editor noise.
- Removed stale `cybrex-ctl.bak` file.

---

## Key Features

### 1. Unified Control Layer
- **CLI**: `cybrex-ctl` - status, update, power, security, firewall, logs, health.
- **API**: `cybrex-daemon` on port 3001 - `/api/state`, `/api/health`, `/api/power`.
- **Config**: Centralised TOML in `/etc/cybrex/` (main, power, security).

### 2. Security by Default
- **Firewall**: Deny-all-inbound nftables policy (`/etc/nftables.conf`), enabled on boot.
- **Kernel hardening**: sysctl parameters covering network, memory, and kernel hardening.
- **Isolation**: Apps can be run in disposable sandboxes via `cybrex-box` (bubblewrap).
- **Boot**: Secure Boot helper available (`cybrex-secureboot`), enrollment planned.
- **Audit**: Pre-installed security stack (Nmap, Wireshark) + live audit via `cybrex-ctl security`.

### 3. Developer Experience
- **Hyprland**: Pre-configured tiling WM with "Cybrex Green" aesthetics.
- **Dev Stack**: Docker, Python, Go, Node.js ready out-of-the-box.
- **Setup**: One-shot environment hydration via `cybrex-dev-setup`.
  - Profiles: `web`, `backend`, `mobile`, `sec`, `gaming`, `full`
  - Includes optional gaming tooling such as Steam/Lutris/GameMode/MangoHud where available.

---

## Installation

1. Boot a live Debian/Ubuntu USB.
2. Mount your dedicated NVMe drive.
3. Run: `sudo bash build_scripts/install_cybrex.sh`
4. Reboot and run `sudo cybrex-secureboot` to enroll keys.

Or for VM:
```bash
sudo bash build_scripts/build_vm.sh
```

---

## Post-Install First Steps

```bash
cybrex-ctl health          # verify all services and hardening
cybrex-ctl status          # overview
sudo cybrex-ctl power balanced
sudo cybrex-ctl firewall status
```

Edit `/etc/cybrex/main.toml` to customise your owner profile.
