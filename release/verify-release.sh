#!/bin/bash
set -Eeuo pipefail

ARTIFACT_DIR="${1:-artifacts}"
REPOSITORY="${GITHUB_REPOSITORY:-imedkablavi/cybrexOS}"
CHECKSUM_FILE="$ARTIFACT_DIR/SHA256SUMS"

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

if command -v gh >/dev/null 2>&1; then
    verified=0
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        echo "[verify-release] verifying GitHub artifact attestation: $file"
        gh attestation verify "$file" --repo "$REPOSITORY"
        verified=1
    done < <(find "$ARTIFACT_DIR" -maxdepth 1 -type f \( -name '*.vmdk' -o -name '*.iso' \) -print | sort)

    if [[ "$verified" == "0" ]]; then
        echo "[verify-release] no VMDK/ISO present; checksum verification only"
    fi
else
    echo "[verify-release] gh not installed; checksums verified, provenance not checked" >&2
fi
