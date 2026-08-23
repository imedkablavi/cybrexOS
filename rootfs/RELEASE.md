# CybrexOS – Alpha Release Notes

**Channel:** alpha  
**Base:** Debian bookworm / amd64 VM image  
**Compatibility claim:** QEMU + OVMF only when the candidate commit's boot-qualification workflow passes

## Release-engineering changes

This alpha introduces a real boot qualification gate rather than relying only on static
image inspection.

- Fresh raw images can be booted under QEMU `q35` with OVMF UEFI in CI.
- An in-guest systemd probe verifies systemd state, systemd-networkd,
  systemd-resolved, DHCP/default route and the live nftables policy.
- Qualification requires a serial `CYBREX_SMOKE:PASS` marker.
- Loop devices and mounts are cleaned from the VM build on normal exit and failures.
- The VM builder emits an SPDX 2.3 package SBOM, package manifest, SHA256 checksums,
  build report and an explicit reproducibility report.
- Release-candidate automation creates signed GitHub build provenance for the VMDK and
  verifies it with consumer-facing `gh attestation verify` tooling.
- Release channels `alpha`, `beta` and `stable` now have documented promotion gates.

## Reproducibility status

Byte-for-byte reproducibility is **not yet qualified**. Debian package sources are not
pinned to immutable snapshots, and filesystem/GRUB/initramfs/VMDK metadata can vary.
Each build emits `artifacts/REPRODUCIBILITY.md` rather than claiming identical hashes
across independent builds.

## ISO status

The live-build script now has explicit configure/build/clean modes and injects the
tracked Debian rootfs overlay. The resulting ISO remains **experimental** and is excluded
from the qualified release bundle until it receives its own UEFI boot matrix and the
installer is qualified.

## Bare-metal status

Bare-metal installation is **not qualified**. The previous hardcoded-disk destructive
paths have been removed from executable release behavior:

- `install_base.sh` is disabled as a legacy unqualified path.
- `install_cybrex.sh` is fail-closed preflight only.
- No default target disk is selected.
- The destructive phase remains disabled until disposable-disk and hardware testing is
  documented.

Do not infer physical hardware compatibility from a QEMU result.

## Secure Boot status

Secure Boot remains **design-only**. The `cybrex-secureboot` helper is inspection-only
and does not create or enroll firmware keys. The design and required positive/negative
OVMF tests are documented in `docs/SECURE_BOOT.md`.

## Security baseline in the image

The tracked rootfs still includes:

- nftables deny-by-default inbound rules;
- sysctl hardening configuration;
- systemd-networkd/systemd-resolved configuration;
- `cybrex-ctl` and `cybrex-daemon` components;
- log rotation and update timer definitions.

The automated boot gate verifies the network/resolver/firewall services and loaded
firewall policy. Other feature claims require their own tests and should not be inferred
from this boot qualification.

## Documentation

- VM build/test: `docs/VM.md`
- Boot qualification report: `docs/BOOT_QUALIFICATION.md`
- Bare metal: `docs/BARE_METAL.md`
- Secure Boot design: `docs/SECURE_BOOT.md`
- Release channels: `docs/RELEASE_CHANNELS.md`
