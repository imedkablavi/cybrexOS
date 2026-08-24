# CybrexOS Boot Qualification Report

**Scope:** amd64 VM image release path  
**Firmware under automated test:** QEMU `q35` + OVMF UEFI  
**Acceleration:** TCG (no dependency on host KVM)  
**Status:** qualification framework implemented; the GitHub Actions result for each commit is authoritative  
**Bare metal:** **NOT QUALIFIED**

## Release-engineering baseline

The previous builder performed static checks against the disk image (GRUB, kernel,
initramfs and UUID consistency) but did not actually boot the produced image in CI.
This pass adds a real UEFI smoke boot and an in-guest systemd probe.

## Automated boot gate

`.github/workflows/boot-smoke.yml` builds a fresh Debian-based raw image and boots it
with `ci/smoke_boot_qemu.sh` using QEMU and OVMF. The build enables a CI-only systemd
unit that writes machine-readable qualification markers to the serial console and
powers the VM off after the probe finishes.

A run passes only when the guest proves all of the following after boot:

1. UEFI/GRUB/kernel/initramfs boot reaches systemd user space.
2. `systemd` reaches `running` or `degraded` after a bounded wait.
3. `systemd-networkd.service` is active.
4. `systemd-resolved.service` is active.
5. `nftables.service` is active.
6. A non-loopback global IPv4 address exists.
7. A default IPv4 route exists.
8. `table inet cybrex_fw` is loaded.
9. `cybrex_fw/inbound` has `policy drop`.
10. `cybrex_fw/outbound` has `policy accept`.
11. No systemd unit is left in the failed state at the end of qualification.
12. The serial log contains the exact marker `CYBREX_SMOKE:PASS`.

The host harness treats the PASS marker as the source of truth. A QEMU process exit
without that marker is a failure, and a `CYBREX_SMOKE:FAIL:*` marker is always a
failure.

## Determinism controls in the smoke boot

- QEMU machine type is fixed to `q35`.
- CPU model is fixed to QEMU `max` under TCG.
- vCPU count and memory are fixed.
- Disk interface is fixed to virtio-blk.
- Network interface is fixed to virtio-net with QEMU user-mode networking.
- Firmware is selected from a matching OVMF CODE/VARS pair and the VARS file is
  copied per run so firmware state does not leak between runs.
- The guest probe has bounded waits for systemd and DHCP.
- The CI-only probe is not installed in normal release images.

## Static image checks retained

Before QEMU boot, `build_scripts/build_vm.sh` also verifies:

- `/boot/grub/grub.cfg` exists.
- `EFI/BOOT/BOOTX64.EFI` exists.
- a kernel and initramfs exist.
- a matching `/lib/modules/<kernel>` directory exists.
- GRUB contains Linux and initrd entries.
- GRUB `root=UUID=` matches the generated root filesystem UUID.

## What this qualification does **not** prove

Passing QEMU/OVMF does not prove compatibility with VMware, VirtualBox, Hyper-V,
physical UEFI implementations, individual GPUs, Wi-Fi chipsets, storage controllers,
TPMs, Secure Boot key databases, suspend/resume, audio devices, or vendor firmware.
Those require separate matrices and evidence.

The repository must not convert a QEMU pass into a bare-metal compatibility claim.

## ISO status

The live ISO pipeline is now explicit and reproducible in configuration, but the ISO
is still experimental. It is not promoted into a release channel until it receives a
separate UEFI boot matrix and the bare-metal installer has its own destructive-test
qualification in disposable virtual disks plus documented hardware tests.

## Evidence produced by CI

The boot workflow uploads, even on failure:

- `build_vm/report.txt`
- `build_vm/qemu-boot.log`
- `artifacts/build-report.txt`
- `artifacts/cybrexOS.spdx`
- `artifacts/packages.tsv`
- `artifacts/REPRODUCIBILITY.md`
- `artifacts/SHA256SUMS`

A release candidate is not considered boot-qualified if the smoke workflow is missing,
skipped, cancelled or failing for the candidate commit.
