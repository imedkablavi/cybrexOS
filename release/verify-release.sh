#!/bin/bash
set -Eeuo pipefail

ARTIFACT_DIR="${1:-artifacts}"
REPOSITORY="${GITHUB_REPOSITORY:-imedkablavi/cybrexOS}"
CHECKSUM_FILE="$ARTIFACT_DIR/SHA256SUMS"
VERIFY_PROVENANCE="${VERIFY_PROVENANCE:-1}"
VERIFY_SBOM_ATTESTATION="${VERIFY_SBOM_ATTESTATION:-0}"
SBOM_JSON="$ARTIFACT_DIR/cybrexOS.spdx.json"

fail() {
    echo "[verify-release] ERROR: $*" >&2
    exit 1
}

[[ -d "$ARTIFACT_DIR" ]] || fail "artifact directory not found: $ARTIFACT_DIR"
[[ -f "$CHECKSUM_FILE" ]] || fail "missing $CHECKSUM_FILE"

(
    cd "$ARTIFACT_DIR"
    sha256sum -c SHA256SUMS
)

if [[ "$VERIFY_PROVENANCE" != "1" ]]; then
    echo "[verify-release] checksum verification complete; provenance check explicitly skipped"
    exit 0
fi

command -v gh >/dev/null 2>&1 || fail "gh is required for provenance verification"
verified=0
while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    echo "[verify-release] verifying GitHub build provenance: $file"
    gh attestation verify "$file" --repo "$REPOSITORY"

    if [[ "$VERIFY_SBOM_ATTESTATION" == "1" ]]; then
        [[ -s "$SBOM_JSON" ]] || fail "missing SPDX JSON SBOM: $SBOM_JSON"
        echo "[verify-release] verifying SPDX 2.3 SBOM attestation: $file"
        gh attestation verify "$file" \
            --repo "$REPOSITORY" \
            --predicate-type 'https://spdx.dev/Document/v2.3'
    fi
    verified=1
done < <(find "$ARTIFACT_DIR" -maxdepth 1 -type f \( -name '*.vmdk' -o -name '*.iso' \) -print | sort)

[[ "$verified" == "1" ]] || fail "no VMDK/ISO artifact found for provenance verification"
