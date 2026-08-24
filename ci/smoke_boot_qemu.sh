#!/bin/bash
set -Eeuo pipefail

IMAGE="${1:-build_vm/CybrexTech_Dev_Preview.img}"
TIMEOUT_SECONDS="${QEMU_BOOT_TIMEOUT:-240}"
LOG_FILE="${QEMU_BOOT_LOG:-build_vm/qemu-boot.log}"
TMP_DIR=""

fail() {
    echo "[qemu-smoke] ERROR: $*" >&2
    exit 1
}

cleanup() {
    set +e
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -f "$IMAGE" ]] || fail "raw image not found: $IMAGE"
command -v qemu-system-x86_64 >/dev/null 2>&1 || fail "qemu-system-x86_64 is required"
command -v timeout >/dev/null 2>&1 || fail "timeout is required"
command -v tr >/dev/null 2>&1 || fail "tr is required"

OVMF_CODE=""
OVMF_VARS=""
for pair in \
    "/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd" \
    "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd"; do
    code="${pair%%:*}"
    vars="${pair#*:}"
    if [[ -r "$code" && -r "$vars" ]]; then
        OVMF_CODE="$code"
        OVMF_VARS="$vars"
        break
    fi
done
[[ -n "$OVMF_CODE" ]] || fail "no supported OVMF CODE/VARS pair found"

mkdir -p "$(dirname "$LOG_FILE")"
: >"$LOG_FILE"
TMP_DIR="$(mktemp -d)"
cp "$OVMF_VARS" "$TMP_DIR/OVMF_VARS.fd"

set +e
timeout --signal=TERM --kill-after=20 "$TIMEOUT_SECONDS" \
    qemu-system-x86_64 \
    -machine q35,accel=tcg \
    -cpu max \
    -m 1536 \
    -smp 2 \
    -nodefaults \
    -device virtio-rng-pci \
    -device virtio-blk-pci,drive=osdisk \
    -drive if=none,id=osdisk,format=raw,file="$IMAGE",cache=unsafe \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$TMP_DIR/OVMF_VARS.fd" \
    -display none \
    -serial "file:$LOG_FILE" \
    -monitor none \
    -no-reboot
qemu_rc=$?
set -e

# QEMU serial files can contain CRLF even on a Linux host. Normalize only for
# machine-readable marker parsing; preserve the original serial log as evidence.
NORMALIZED_LOG="$TMP_DIR/qemu-boot.normalized.log"
tr -d '\r' <"$LOG_FILE" >"$NORMALIZED_LOG"

if grep -q 'CYBREX_SMOKE:FAIL:' "$NORMALIZED_LOG"; then
    grep 'CYBREX_SMOKE:' "$NORMALIZED_LOG" >&2 || true
    fail "guest qualification probe reported failure"
fi

if ! grep -q '^CYBREX_SMOKE:PASS$' "$NORMALIZED_LOG"; then
    echo "[qemu-smoke] qemu exit code: $qemu_rc" >&2
    tail -n 200 "$LOG_FILE" >&2 || true
    if [[ "$qemu_rc" == "124" || "$qemu_rc" == "137" ]]; then
        fail "boot timed out after ${TIMEOUT_SECONDS}s"
    fi
    fail "PASS marker not observed"
fi

if [[ "$qemu_rc" != "0" ]]; then
    echo "[qemu-smoke] guest emitted PASS but QEMU exited with code $qemu_rc" >&2
    tail -n 200 "$LOG_FILE" >&2 || true
    if [[ "$qemu_rc" == "124" || "$qemu_rc" == "137" ]]; then
        fail "guest passed checks but VM did not power off before timeout"
    fi
    fail "guest passed checks but QEMU did not exit cleanly"
fi

grep '^CYBREX_SMOKE:' "$NORMALIZED_LOG"
echo "[qemu-smoke] PASS"
