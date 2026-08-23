#!/bin/bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for script in \
    build_scripts/build_vm.sh \
    build_scripts/build_iso.sh \
    build_scripts/install_cybrex.sh \
    build_scripts/install_base.sh \
    ci/guest-smoke.sh \
    ci/smoke_boot_qemu.sh \
    release/verify-release.sh \
    rootfs/usr/local/bin/cybrex-secureboot; do
    [[ -f "$script" ]] || { echo "missing script: $script" >&2; exit 1; }
    bash -n "$script"
done

grep -q 'CYBREX_CI_SMOKE' build_scripts/build_vm.sh
grep -q 'cybrex-ci-smoke.service' build_scripts/build_vm.sh
grep -q 'policy drop' rootfs/etc/nftables.conf
grep -q 'policy accept' rootfs/etc/nftables.conf
grep -q 'Name=en\*' rootfs/etc/systemd/network/20-dhcp.network
grep -q -- '--confirm-wipe' build_scripts/install_cybrex.sh
grep -q 'UNQUALIFIED' build_scripts/install_base.sh
grep -q 'CYBREX_SMOKE:PASS' ci/guest-smoke.sh
grep -q 'OVMF_CODE' ci/smoke_boot_qemu.sh
grep -q 'gh attestation verify' release/verify-release.sh

echo "release contract checks: PASS"
