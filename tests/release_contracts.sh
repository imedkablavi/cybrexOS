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
    ci/qualify_release_vmdk.sh \
    release/verify-release.sh \
    rootfs/usr/local/bin/cybrex-secureboot; do
    [[ -f "$script" ]] || { echo "missing script: $script" >&2; exit 1; }
    bash -n "$script"
done

python3 -m py_compile release/generate_spdx_json.py

grep -q 'CYBREX_CI_SMOKE' build_scripts/build_vm.sh
grep -q 'cybrex-ci-smoke.service' build_scripts/build_vm.sh
grep -q -- '--keyring=' build_scripts/build_vm.sh
grep -q 'e2fsck -pf' build_scripts/build_vm.sh
grep -q 'assert_unmounted_tree' build_scripts/build_vm.sh
grep -q 'policy drop' rootfs/etc/nftables.conf
grep -q 'policy accept' rootfs/etc/nftables.conf
grep -q 'Name=en\*' rootfs/etc/systemd/network/20-dhcp.network
grep -q -- '--confirm-wipe' build_scripts/install_cybrex.sh
grep -q 'UNQUALIFIED' build_scripts/install_base.sh
grep -q 'CYBREX_SMOKE:PASS' ci/guest-smoke.sh
grep -q 'OVMF_CODE' ci/smoke_boot_qemu.sh
grep -q 'qemu_rc' ci/smoke_boot_qemu.sh
grep -q 'RELEASE_VMDK:PASS' ci/qualify_release_vmdk.sh
grep -q 'format=vmdk' ci/qualify_release_vmdk.sh
grep -q 'systemd-networkd.service' ci/qualify_release_vmdk.sh
grep -q 'gh attestation verify' release/verify-release.sh
grep -q 'https://spdx.dev/Document/v2.3' release/verify-release.sh
grep -q 'uses: actions/attest@v4' .github/workflows/release.yml
grep -q 'cybrexOS.spdx.json' .github/workflows/release.yml

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
printf 'bash\t5.2-test\tamd64\n' >"$tmp_dir/packages.tsv"
GITHUB_SHA=contract-test SOURCE_DATE_EPOCH=0 \
    python3 release/generate_spdx_json.py "$tmp_dir/packages.tsv" "$tmp_dir/sbom.json" >/dev/null
python3 - "$tmp_dir/sbom.json" <<'PY'
import json
import sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    doc = json.load(fh)
assert doc["spdxVersion"] == "SPDX-2.3"
assert doc["SPDXID"] == "SPDXRef-DOCUMENT"
assert len(doc["packages"]) == 1
assert doc["packages"][0]["name"] == "bash"
assert doc["relationships"][0]["relationshipType"] == "DESCRIBES"
PY

echo "release contract checks: PASS"
