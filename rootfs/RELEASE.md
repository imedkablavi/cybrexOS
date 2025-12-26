# CybrexTech OS - Release Notes
**Version**: 1.0.0 (Alpha)
**Codename**: Obsidian Green

## Overview
CybrexTech OS is a custom, single-owner platform built on Debian Stable, designed for high-security development and daily usage.

## Key Features

### 1. Unified Control Layer
- **CLI**: `cybrex-ctl` manages updates, power profiles, and security audits.
- **Power**: 3 Profiles (Saver, Balanced, Performance) with automated CPU/GPU tuning.
- **Config**: Centralized TOML configuration in `/etc/cybrex/`.

### 2. Security by Default
- **Firewall**: Strict "Deny All" NFTables policy (`/etc/nftables.conf`).
- **Isolation**: Apps can be run in disposable sandboxes via `cybrex-box`.
- **Boot**: Full Secure Boot support with custom enrollment helper (`cybrex-secureboot`).
- **Encyclopedia**: Pre-installed security stack (Nmap, Wireshark).

### 3. Developer Experience
- **Hyprland**: Pre-configured Tiling WM with "Cybrex Green" aesthetics.
- **Dev Stack**: Docker, Python, Go, Node.js ready out-of-the-box.
- **Setup**: One-shot environment hydration via `cybrex-dev-setup`.

## Installation
1.  Boot a live Debian/Ubuntu USB.
2.  Mount your dedicated NVMe drive.
3.  Run: `sudo bash build_scripts/install_cybrex.sh`.
4.  Reboot and run `sudo cybrex-secureboot` to enroll keys.

## Next Steps
- Run `cybrex-ctl status` to verify health.
- Edit `/etc/cybrex/main.toml` to customize your owner profile.

## Build Pipeline Update
- Added strong kernel/initrd/GRUB root UUID verification in `build_scripts/build_vm.sh` verify stage:
  - Checks for `/boot/vmlinuz-*`, `/boot/initrd.img-*`, matching `/lib/modules/<version>/`
  - Ensures `grub.cfg` has linux/initrd lines and root=UUID present
  - Fails if GRUB root UUID does not match `/` UUID in `/etc/fstab`
- Verification results are written to `build_vm/report.txt` with keys:
  `KERNEL_VMLINUZ`, `KERNEL_VERSION`, `INITRD`, `GRUB_HAS_LINUX_LINE`,
  `GRUB_HAS_INITRD_LINE`, `GRUB_ROOT_UUID`, `FSTAB_ROOT_UUID`,
  `GRUB_ROOT_UUID_MATCHES_FSTAB`
