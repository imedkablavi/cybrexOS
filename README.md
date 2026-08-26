# CybrexOS – Debian-Based VM Image Build Pipeline

CybrexOS is a **custom Debian-based Linux OS build pipeline** designed to produce
bootable virtual machine images for **VMware (EFI)**.

The project focuses on:
- Correct boot chain (GRUB EFI + kernel + initramfs)
- Clean root filesystem construction
- Deterministic and inspectable image builds
- Safety-first build scripting (no global destructive operations)
- Security-hardened kernel and firewall out of the box

>  Project status: **ALPHA**
> This repository is under active development and not yet production-ready.

---

## What This Project Builds

- **Raw disk image** (GPT, EFI + root partition)
- **VMware VMDK** converted from raw image
- **VMX configuration** (EFI, auto-updated to reference the built VMDK)

The system is based on:
- Debian **bookworm**
- Debian kernel (`linux-image-amd64`)
- systemd, GRUB EFI, systemd-networkd, systemd-resolved
- nftables (deny-all-inbound firewall, enabled on boot)
- Hardened kernel via `/etc/sysctl.d/99-cybrex-hardening.conf`

No ISO installer is currently produced.

---

## Repository Structure

```text
.
├── build_scripts/        # Main build pipeline (VM image)
│   ├── build_vm.sh       # Primary deterministic VM builder
│   ├── build_iso.sh      # Live ISO builder (live-build, WIP)
│   ├── install_base.sh   # Arch-based bare-metal installer
│   └── install_cybrex.sh # Debian bare-metal installer (LUKS + Btrfs)
├── rootfs/               # Root filesystem overlay (configs, services, binaries)
│   ├── etc/cybrex/       # Centralised TOML configuration
│   ├── etc/nftables.conf # Firewall ruleset (deny-all inbound)
│   ├── etc/sysctl.d/     # Kernel hardening parameters
│   ├── etc/logrotate.d/  # Log rotation for /var/log/cybrex/
│   ├── etc/systemd/      # Custom systemd units & network config
│   └── usr/local/bin/    # cybrex-ctl, cybrex-daemon, dev tools
├── .gitignore
└── README.md
```

Generated artifacts (`build_vm/`, `artifacts/`, `*.img`, `*.vmdk`) are not tracked in git.

---

## Requirements

**Host system:**
- Linux (tested on WSL2)
- Root privileges

**Required tools:**
- `debootstrap`
- `qemu-utils`
- `parted`
- `dosfstools`
- `rsync`
- `util-linux` (`losetup`, `mount`)
- `grub-efi-amd64`
- `logrotate`

---

## Build Instructions

```bash
sudo apt-get update
sudo apt-get install -y \
  debootstrap qemu-utils parted dosfstools rsync util-linux logrotate

sudo bash build_scripts/build_vm.sh
```

**Optional environment variables:**

```bash
DEBIAN_SUITE=bookworm
DISK_SIZE=20G
HOSTNAME=cybrex-dev
USERNAME=cybrex
SKIP_GUI=1
```

---

## Build Outputs

After a successful build:

```text
build_vm/
 └── report.txt           # Build & verification report

artifacts/
 └── CybrexTech_Dev_Preview.vmdk
```

The VMX file is automatically updated to reference the generated VMDK.

---

## Kernel & Boot Validation

During the build verification stage, the pipeline validates:

- Presence of `/boot/vmlinuz-*`, `/boot/initrd.img-*`, `/lib/modules/<kernel-version>/`
- GRUB configuration contains explicit `linux` and `initrd` lines
- GRUB `root=UUID=` matches `/etc/fstab` root UUID

Results are written to `build_vm/report.txt`.

---

## Networking

The system uses:
- `systemd-networkd` (DHCP by default, matches `en*`, `eth*`, `ens*`, `enp*`, `eno*`, `wl*`)
- `systemd-resolved` with stub resolver
- A default DHCP `.network` file is created if none exists

---

## Security

**Active baseline:**
-  SSH enabled (inbound SSH port closed by default firewall; open manually if needed)
-  `nftables` deny-all-inbound firewall - enabled on boot
-  Kernel hardening via `sysctl.d/99-cybrex-hardening.conf` (ASLR, SYN cookies,
  ptrace restriction, dmesg restriction, kptr restriction, etc.)
-  `cybrex-ctl security` - live audit: failed logins, open ports, SUID binaries
-  `cybrex-box` - bubblewrap sandbox wrapper for untrusted apps

**Planned:**
-  Secure Boot (sbctl key enrollment - helper script exists: `cybrex-secureboot`)
-  CI-based smoke boot testing
-  Artifact signing & SBOM

---

## Control Layer (`cybrex-ctl`)

```text
cybrex-ctl status                          – System overview
cybrex-ctl update                          – Full package upgrade
cybrex-ctl power [saver|balanced|performance]
                                           – Get or apply CPU power profile
cybrex-ctl security                        – Security audit
cybrex-ctl firewall [status|reload|flush]  – Manage nftables
cybrex-ctl logs [N]                        – Show last N cybrex log lines
cybrex-ctl health                          – Full health check
```

---

## Daemon API (`cybrex-daemon`)

The `cybrex-daemon` systemd service runs a lightweight Python HTTP API on port **3001**:

| Method | Path         | Description                                      |
|--------|--------------|--------------------------------------------------|
| GET    | `/api/state` | Full JSON system state (power, security, system) |
| GET    | `/api/health`| Liveness probe `{"status":"ok"}`                 |
| POST   | `/api/power` | Switch power profile `{"profile":"balanced"}`    |

---

## Auto-Update

A weekly systemd timer (`cybrex-update.timer`) triggers `cybrex-ctl update --auto`
to keep the system current. It is enabled during the build.

---

## Project Status

| Feature                              | Status      |
|--------------------------------------|-------------|
| Kernel installation                  |  Done     |
| Boot (manual verification)           |  Done     |
| nftables firewall (enabled on boot)  |  Done     |
| Kernel sysctl hardening              |  Done     |
| Log rotation (`logrotate.d/cybrex`)  |  Done     |
| cybrex-ctl (full featured)           |  Done     |
| cybrex-daemon API (health + POST)    |  Done     |
| Weekly auto-update timer             |  Done     |
| Automated smoke boot                 |  Planned  |
| Reproducible builds                  |  Partial  |
| CI/CD                                |  Planned  |
| Secure Boot enrollment               |  Planned  |
