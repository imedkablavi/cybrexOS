# CybrexOS

CybrexOS is an **alpha Debian-based OS image build pipeline** with a security-oriented
rootfs overlay and explicit release qualification gates.

The release-engineering focus is evidence: a build is not called boot-qualified merely
because GRUB files exist. CI builds a fresh image, boots it under QEMU + OVMF, and checks
systemd, networking and the live nftables policy from inside the guest.

> **Status: ALPHA.** Automated qualification currently covers one amd64 QEMU/OVMF VM
> configuration. Bare-metal hardware, VMware, Secure Boot and the live ISO have separate
> status and must not inherit compatibility claims from the QEMU result.

## Qualified scope

Automated CI currently targets:

- architecture: amd64/x86_64;
- firmware: OVMF UEFI;
- machine: QEMU `q35` under TCG;
- disk: virtio-blk;
- network: virtio-net + QEMU user-mode networking;
- base: Debian bookworm;
- init/service manager: systemd;
- network stack: systemd-networkd + systemd-resolved;
- firewall: nftables with `cybrex_fw` inbound `drop` and outbound `accept` policies.

See [Boot Qualification](docs/BOOT_QUALIFICATION.md) for the exact pass/fail contract.

## What the VM builder produces

`build_scripts/build_vm.sh` creates:

```text
build_vm/
├── CybrexTech_Dev_Preview.img   # raw GPT/UEFI image
└── report.txt                   # static image-verification report

artifacts/
├── CybrexTech_Dev_Preview.vmdk  # omitted when SKIP_VMDK=1
├── cybrexOS.spdx                # SPDX 2.3 package SBOM
├── packages.tsv                 # installed Debian package manifest
├── REPRODUCIBILITY.md           # build reproducibility status
├── build-report.txt
└── SHA256SUMS
```

A normal VMDK build also writes `CybrexTech_Dev_Preview.vmx` in the repository root.
Release workflows copy it into the release bundle and checksum it.

## Local VM build

On a Debian/Ubuntu build host with root privileges:

```bash
sudo apt-get update
sudo apt-get install -y \
  debootstrap qemu-utils parted dosfstools rsync util-linux
sudo bash build_scripts/build_vm.sh
```

Development defaults remain `USERNAME=cybrex` and `VM_PASSWORD=cybrex`; override the
password for any non-disposable image.

More detail: [VM Build and Test Guide](docs/VM.md).

## Automated boot qualification

The pull-request and `main` CI path:

1. runs static release contract tests;
2. builds a fresh 4 GiB raw image with a CI-only systemd probe;
3. boots the raw image with QEMU `q35` + OVMF;
4. waits for systemd and DHCP with bounded timeouts;
5. verifies `systemd-networkd`, `systemd-resolved` and `nftables` are active;
6. verifies global IPv4 plus a default route;
7. verifies the loaded nftables inbound policy is `drop` and outbound is `accept`;
8. fails if any systemd unit is left failed;
9. requires the exact serial marker `CYBREX_SMOKE:PASS`.

Qualification logs and build metadata are uploaded even when the workflow fails.

## Release integrity

A release candidate workflow performs a QEMU qualification build first, then builds a
clean release image from the same commit without the CI poweroff probe.

The clean release bundle includes:

- SHA256 checksums;
- SPDX 2.3 SBOM;
- sorted Debian package manifest;
- build report;
- explicit reproducibility report;
- QEMU qualification serial evidence;
- GitHub signed build-provenance attestation for the VMDK.

Consumer verification:

```bash
bash release/verify-release.sh artifacts
```

The helper verifies `SHA256SUMS` and uses `gh attestation verify` for the published
VMDK provenance.

## Reproducible builds

CybrexOS **does not currently claim bit-for-bit reproducible images**. The build records
inputs and generates deterministic package ordering, but Debian repositories are not yet
pinned to immutable snapshots and filesystem/GRUB/initramfs metadata can vary between
runs.

Every build emits `artifacts/REPRODUCIBILITY.md` with this limitation. Reproducibility
must be proven by two clean, snapshot-pinned builds with identical artifact hashes before
the project changes that claim.

## ISO status

`build_scripts/build_iso.sh` now has explicit `configure`, `build` and `clean` modes and
injects the tracked Debian rootfs overlay. It can build **experimental** live media when
`live-build` is installed:

```bash
sudo build_scripts/build_iso.sh configure
sudo build_scripts/build_iso.sh build
```

The ISO is not currently part of the qualified release bundle. It does not auto-run the
bare-metal installer.

## Bare-metal installer safety

Bare metal is **NOT QUALIFIED**.

The previous hardcoded `/dev/nvme0n1` and `/dev/sda` destructive paths have been removed
from executable release behavior:

- the legacy Arch installer is disabled;
- the Debian installer is a fail-closed preflight tool;
- no default disk exists;
- the running root disk and mounted targets are rejected when detected;
- destructive execution remains disabled pending a disposable-disk and hardware test
  matrix.

See [Bare-Metal Installation Status](docs/BARE_METAL.md).

## Secure Boot

Secure Boot is **design-only, not a current compatibility claim**. The
`cybrex-secureboot` helper is inspection-only and will not create/enroll firmware keys.

The design, key-management boundary, OVMF negative tests and future hardware gates are
in [Secure Boot Design](docs/SECURE_BOOT.md).

## Release channels

CybrexOS defines `alpha`, `beta` and `stable` as evidence gates, not marketing labels.
Stable requires stronger installer, provenance, reproducibility and hardware evidence
than alpha.

See [Release Channels](docs/RELEASE_CHANNELS.md).

## Rootfs security baseline

The tracked overlay includes:

- `/etc/nftables.conf` with deny-by-default inbound filtering;
- `/etc/sysctl.d/99-cybrex-hardening.conf`;
- custom systemd units and network configuration;
- `cybrex-ctl` control tooling;
- `cybrex-daemon` local control service;
- log rotation and update timer definitions.

The VM builder normalizes tracked service/network/firewall text files before installation
and explicitly enables the required network/resolver/firewall services.

## Repository layout

```text
.
├── .github/workflows/
│   ├── boot-smoke.yml       # PR/main QEMU+OVMF qualification
│   └── release.yml          # release candidate, checksums and provenance
├── build_scripts/
│   ├── build_vm.sh
│   ├── build_iso.sh
│   ├── install_cybrex.sh    # fail-closed bare-metal preflight
│   └── install_base.sh      # disabled legacy installer
├── ci/
│   ├── guest-smoke.sh
│   ├── cybrex-ci-smoke.service
│   └── smoke_boot_qemu.sh
├── docs/
│   ├── BOOT_QUALIFICATION.md
│   ├── VM.md
│   ├── BARE_METAL.md
│   ├── SECURE_BOOT.md
│   └── RELEASE_CHANNELS.md
├── release/verify-release.sh
├── tests/release_contracts.sh
└── rootfs/
```

## Compatibility statement

Only the automated QEMU/OVMF configuration described above is continuously qualified by
this repository. Any additional hypervisor or physical-hardware compatibility statement
must link to separate test evidence.
