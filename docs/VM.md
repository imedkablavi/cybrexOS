# VM Build and Test Guide

This document covers virtual-machine images only. It does not imply bare-metal support.

## Qualified automated path

The automated release gate uses:

- amd64/x86_64 guest architecture;
- QEMU `q35` machine model;
- OVMF UEFI firmware;
- TCG CPU emulation;
- virtio-blk disk;
- virtio-net with QEMU user-mode networking.

See `docs/BOOT_QUALIFICATION.md` for the exact assertions.

## Build locally

On a Debian/Ubuntu host with loop/mount privileges:

```bash
sudo apt-get update
sudo apt-get install -y \
  debootstrap debian-archive-keyring qemu-utils parted dosfstools e2fsprogs rsync util-linux
sudo bash build_scripts/build_vm.sh
```

The builder requires `/usr/share/keyrings/debian-archive-keyring.gpg` by default and
passes it explicitly to debootstrap. A missing keyring is a hard failure rather than an
unsigned Debian bootstrap. Override `DEBIAN_KEYRING` only with a deliberate trusted
keyring path.

Normal output includes:

- `build_vm/CybrexTech_Dev_Preview.img` — raw build image;
- `artifacts/CybrexTech_Dev_Preview.vmdk` — VMware-format artifact;
- `artifacts/cybrexOS.spdx` — SPDX 2.3 package SBOM;
- `artifacts/packages.tsv` — installed Debian package manifest;
- `artifacts/SHA256SUMS` — checksums for release metadata/artifacts;
- `artifacts/REPRODUCIBILITY.md` — reproducibility status and limitations;
- `build_vm/report.txt` — static image verification report.

Before reopening the raw image read-only, the builder syncs and unmounts all build
mounts, verifies that none remain, and runs `e2fsck -p` on the unmounted ext4 root. This
turns leaked mounts or filesystem inconsistency into release-build failures instead of
silently carrying them into QEMU.

## Run the same QEMU smoke boot locally

Install QEMU and OVMF, then build the CI qualification image:

```bash
sudo apt-get install -y qemu-system-x86 ovmf
sudo env CYBREX_CI_SMOKE=1 SKIP_VMDK=1 DISK_SIZE=4G \
  bash build_scripts/build_vm.sh
sudo bash ci/smoke_boot_qemu.sh build_vm/CybrexTech_Dev_Preview.img
```

The test is successful only when the serial log contains `CYBREX_SMOKE:PASS` and QEMU
then exits cleanly after the guest requests poweroff.

## VMware artifact

The builder still emits a VMDK and a minimal EFI VMX configuration for VMware-oriented
manual testing. Automated QEMU qualification does **not** prove VMware compatibility.
Record VMware product/version and test evidence separately before making a VMware support
claim.

## Credentials

The current alpha VM builder preserves the existing development credential behavior:
`USERNAME` defaults to `cybrex` and `VM_PASSWORD` defaults to `cybrex`. Do not treat this
as a production credential policy. Override `VM_PASSWORD` for any non-disposable image.

## No hardware inference

A successful VM boot says nothing about physical GPU, Wi-Fi, storage, audio, TPM,
suspend/resume or vendor firmware compatibility. See `docs/BARE_METAL.md`.
