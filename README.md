# CybrexOS – Debian-Based VM Image Build Pipeline

CybrexOS is a **custom Debian-based Linux OS build pipeline** designed to produce
bootable virtual machine images for **VMware (EFI)**.

The project focuses on:
- Correct boot chain (GRUB EFI + kernel + initramfs)
- Clean root filesystem construction
- Deterministic and inspectable image builds
- Safety-first build scripting (no global destructive operations)

> ⚠️ Project status: **ALPHA**
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

No ISO installer is currently produced.

---

## Repository Structure

```text
.
├── build_scripts/        # Main build pipeline (VM image)
├── rootfs/               # Root filesystem overlay (configs, services)
├── docs/                 # Architecture & usage documentation
├── legacy/               # Deprecated pipelines (if present)
├── .gitignore
└── README.md
Generated artifacts are not tracked in git.

Requirements
Host system:

Linux (tested on WSL2)

Root privileges

Required tools:

debootstrap

qemu-utils

parted

dosfstools

rsync

util-linux (losetup, mount)

grub-efi-amd64

Build Instructions
bash
Kodu kopyala
sudo apt-get update
sudo apt-get install -y \
  debootstrap qemu-utils parted dosfstools rsync util-linux

sudo bash build_scripts/build_vm.sh
Optional environment variables:

bash
Kodu kopyala
DEBIAN_SUITE=bookworm
DISK_SIZE=20G
HOSTNAME=cybrex-dev
USERNAME=cybrex
SKIP_GUI=1
Build Outputs
After a successful build:

text
Kodu kopyala
build_vm/
 └── report.txt           # Build & verification report

artifacts/
 └── CybrexTech_Dev_Preview.vmdk
The VMX file is automatically updated to reference the generated VMDK.

Kernel & Boot Validation
During the build verification stage, the pipeline validates:

Presence of:

/boot/vmlinuz-*

/boot/initrd.img-*

/lib/modules/<kernel-version>/

GRUB configuration contains:

Explicit linux /boot/vmlinuz-* line

Explicit initrd /boot/initrd.img-* line

GRUB root=UUID= matches /etc/fstab root UUID

Results are written to:

text
Kodu kopyala
build_vm/report.txt
Networking
The system uses:

systemd-networkd (DHCP by default)

systemd-resolved with stub resolver

A default DHCP .network file is created if none exists.

Security Notes
Current baseline:

SSH enabled

systemd services explicitly enabled

No firewall or sysctl hardening yet (planned)

Future hardening (not yet implemented):

nftables default policy

sysctl security baseline

CI-based smoke boot testing

Artifact signing & SBOM

What This Project Is NOT
❌ A live ISO installer

❌ A finished desktop distribution

❌ Secure Boot–enabled (yet)

❌ CI/CD automated (yet)

Project Status
Kernel installation: ✅ DONE

Boot (manual verification): ✅ DONE

Automated smoke boot: ❌ Planned

Reproducible builds: ❌ Partial

CI/CD: ❌ Not implemented
