# Secure Boot Design

## Current status

Secure Boot is **designed but not enabled or qualified** for CybrexOS releases.
The current alpha must not claim Secure Boot compatibility.

`cybrex-secureboot` is intentionally inspection-only in this pass. It does not create,
sign with, enroll, replace or clear firmware keys.

## Threat model and trust boundary

The release goal is to make the UEFI boot chain reject unsigned or untrusted boot
components while keeping signing keys outside normal image-build jobs.

The protected chain is intended to cover:

1. UEFI firmware trust database (`db`).
2. First-stage EFI executable.
3. GRUB EFI binary or a shim-mediated GRUB path.
4. Linux kernel / UKI used by the selected boot design.
5. initramfs policy where the chosen design can authenticate it as part of a signed UKI.

Secure Boot does not authenticate arbitrary user-space files after the kernel starts;
that is a separate integrity problem.

## Preferred architecture for future qualification

### Option A — shim + MOK / distribution-style trust

Use a Microsoft-signed or otherwise platform-trusted shim, then sign CybrexOS GRUB and
kernel/UKI with a project-controlled signing key enrolled through MOK.

Advantages:

- less firmware-specific key management for users;
- avoids replacing OEM PK/KEK/db databases;
- easier recovery on common PCs.

Costs:

- shim policy and tooling become part of the trusted computing base;
- release engineering must track shim/SBAT requirements.

### Option B — owner-managed PK/KEK/db

Enroll project/owner keys directly into firmware Setup Mode and sign EFI artifacts with
the corresponding db key.

Advantages:

- smaller logical trust chain;
- full owner control.

Costs and risks:

- firmware workflows vary significantly;
- a bad enrollment/replacement procedure can make systems unbootable;
- OEM/Windows dual-boot trust must be handled explicitly;
- this path needs real hardware recovery testing before documentation can recommend it.

CybrexOS should not automate PK/KEK/db replacement in an alpha installer.

## Key management requirements

Before enabling signing in a stable channel:

- keep long-lived private signing keys out of the source repository and VM image;
- do not expose private keys to pull-request workflows;
- use a dedicated release environment with restricted approval;
- record key fingerprints and rotation/revocation procedures;
- define an emergency revocation process;
- document how old signed artifacts remain verifiable after rotation;
- back up recovery keys using an offline process controlled by the release owner.

## Build architecture

The normal image builder should remain capable of producing an unsigned development
artifact. A dedicated release-signing stage should consume already-built boot artifacts,
sign them, verify every signature, rebuild the final boot payload if necessary, and then
run Secure Boot qualification.

Signing must not silently occur in ordinary PR builds.

## Required automated qualification

Secure Boot cannot be marked implemented until CI has a separate OVMF Secure Boot job
that uses a test-only PK/KEK/db and demonstrates:

1. signed release image boots successfully;
2. unsigned/tampered EFI bootloader is rejected;
3. unsigned/tampered kernel or UKI is rejected according to the selected chain;
4. valid signed update still boots;
5. key rotation/revocation test vectors behave as documented;
6. recovery procedure works with disposable OVMF variable stores.

Test keys must never be reused as production release keys.

## Required bare-metal qualification

After the OVMF matrix passes, test a documented set of physical UEFI systems with a
recovery path available. Record firmware vendor/version and exact results. Do not infer
support for untested devices or vendors.

## Relationship to release artifact provenance

Secure Boot and release provenance solve different problems:

- Secure Boot controls what firmware/kernel code a machine will execute.
- `SHA256SUMS` detects artifact modification after download.
- GitHub artifact attestations provide signed build provenance for release artifacts.

A complete release should use all applicable layers, but one must not be described as a
replacement for another.
