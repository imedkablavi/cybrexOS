# Bare-Metal Installation Status

## Current support statement

Bare-metal installation is **NOT QUALIFIED** in the current CybrexOS alpha.
No laptop, desktop, motherboard, storage controller, Wi-Fi chipset, GPU, TPM or firmware
model is claimed compatible unless a future qualification report lists it explicitly.

## Why the installer is fail-closed

The previous installer scripts selected `/dev/nvme0n1` or `/dev/sda` by default and
started destructive partitioning immediately. One path also mixed incomplete bootloader
logic with assumptions about partition naming and host tooling.

The release-engineering pass therefore changes the behavior deliberately:

- there is no default target disk;
- the legacy Arch installer is disabled;
- the Debian installer performs preflight only;
- the target must be an explicit whole-disk block device;
- the running root disk is rejected when it can be identified;
- disks with mounted descendants are rejected;
- `--execute` requires an explicit unqualified acknowledgement and an exact repeated
  `--confirm-wipe` path;
- even after those checks, the destructive phase is disabled until qualification exists.

Example safe preflight:

```bash
sudo build_scripts/install_cybrex.sh --disk /dev/nvme1n1 --dry-run
```

This prints the planned layout and makes no disk changes.

## Required qualification before enabling installation

The destructive implementation should remain disabled until all of the following are
implemented and recorded:

1. Disposable-disk integration tests for SATA-style (`/dev/sdX`) and NVMe-style
   (`/dev/nvmeXnY`) partition naming.
2. Positive UEFI boot test after installation into a blank virtual disk.
3. LUKS2 unlock and initramfs boot validation.
4. Btrfs subvolume/fstab validation.
5. GRUB EFI removable/fallback-path validation.
6. Interruption tests during partitioning, encryption, bootstrap and bootloader install.
7. Cleanup tests proving mounts, mappings, swap and loop devices are released on failure.
8. Refusal tests for the running root disk, mounted targets, partitions instead of whole
   disks and ambiguous device paths.
9. Power-loss/retry documentation with an explicit recovery procedure.
10. Manual hardware tests with exact firmware/hardware identifiers and recovery media.

## ISO relationship

`build_scripts/build_iso.sh` can now prepare or build experimental live media, but it does
not auto-run the installer. The ISO must not be promoted merely because it boots.
Installer qualification and live-media boot qualification are separate release gates.

## Secure Boot

Do not enroll or replace firmware keys as part of an unqualified install. Secure Boot is
a separate design and test program documented in `docs/SECURE_BOOT.md`.
