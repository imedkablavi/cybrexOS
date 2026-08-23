# Release Channels

CybrexOS uses three channels. A channel is a statement about qualification level, not a
marketing label.

## Alpha

Purpose: VM-focused development releases for testers.

Required gates:

- release contract checks pass;
- fresh VM image build succeeds;
- QEMU/OVMF boot qualification passes for the candidate commit;
- SBOM and package manifest are generated;
- SHA256 checksums are generated and verified;
- GitHub build-provenance attestation is created for published VM artifacts;
- known limitations are documented;
- no bare-metal compatibility claim.

Allowed limitations:

- bit-for-bit reproducibility may remain unqualified if the report says so explicitly;
- Secure Boot may remain design-only;
- ISO/bare-metal installer may remain experimental and excluded from release assets.

Recommended tag form: `vMAJOR.MINOR.PATCH-alpha.N`.

## Beta

Purpose: wider testing after the alpha VM path has accumulated successful qualification
history.

Additional gates beyond alpha:

- repeated successful boot qualification across clean CI runs;
- update/rollback behavior documented and tested;
- a qualified live ISO UEFI boot job if the ISO is included;
- destructive installer tests run only against disposable virtual disks;
- release notes include migration and recovery instructions;
- no critical open release-blocking defects.

Recommended tag form: `vMAJOR.MINOR.PATCH-beta.N`.

## Stable

Purpose: release channel for compatibility claims backed by evidence.

Additional gates beyond beta:

- reproducible-build policy is either qualified or the remaining exception is explicitly
  approved and documented;
- Secure Boot claims, if present, have passed the OVMF negative/positive test matrix;
- any bare-metal support statement names only tested hardware/firmware combinations;
- installer recovery/failure paths are qualified;
- signing/provenance verification instructions are tested from a clean consumer machine;
- stable release approval is manual and uses the protected release environment.

Recommended tag form: `vMAJOR.MINOR.PATCH`.

## Promotion rules

- A failing or missing required gate blocks promotion.
- A channel never inherits hardware claims from another virtualization platform.
- Experimental ISO or installer artifacts are not attached to a release merely because a
  VM image passed.
- Release notes must distinguish automated evidence, manual evidence and untested areas.
- Stable promotion is not automatic from a tag alone; repository environment protection
  should require explicit release-owner approval.
