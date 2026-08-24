#!/bin/bash
set -Eeuo pipefail

ISO="${1:-artifacts/cybrexOS-live-amd64.iso}"
TIMEOUT_SECONDS="${QEMU_ISO_BOOT_TIMEOUT:-300}"
LOG_FILE="${QEMU_ISO_BOOT_LOG:-artifacts/qualification-iso-qemu.log}"
TMP_DIR=""

fail() {
    echo "[iso-smoke] ERROR: $*" >&2
    [[ -f "$LOG_FILE" ]] && tail -n 200 "$LOG_FILE" >&2 || true
    exit 1
}

cleanup() {
    set +e
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -f "$ISO" ]] || fail "ISO not found: $ISO"
for bin in qemu-system-x86_64 timeout tr; do
    command -v "$bin" >/dev/null 2>&1 || fail "$bin is required"
done

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
    -m 2048 \
    -smp 2 \
    -nodefaults \
    -device virtio-rng-pci \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0 \
    -drive if=none,id=cdrom,media=cdrom,format=raw,readonly=on,file="$ISO" \
    -device ide-cd,drive=cdrom,bus=ide.1,bootindex=1 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$TMP_DIR/OVMF_VARS.fd" \
    -display none \
    -serial "file:$LOG_FILE" \
    -monitor none \
    -no-reboot
qemu_rc=$?
set -e

NORMALIZED_LOG="$TMP_DIR/iso-boot.normalized.log"
tr -d '\r' <"$LOG_FILE" >"$NORMALIZED_LOG"

if grep -q 'CYBREX_SMOKE:FAIL:' "$NORMALIZED_LOG"; then
    grep 'CYBREX_SMOKE:' "$NORMALIZED_LOG" >&2 || true
    fail "live ISO guest qualification probe reported failure"
fi

if ! grep -q '^CYBREX_SMOKE:PASS$' "$NORMALIZED_LOG"; then
    echo "[iso-smoke] qemu exit code: $qemu_rc" >&2
    if [[ "$qemu_rc" == "124" || "$qemu_rc" == "137" ]]; then
        fail "live ISO boot timed out after ${TIMEOUT_SECONDS}s"
    fi
    fail "live ISO PASS marker not observed"
fi

if [[ "$qemu_rc" != "0" ]]; then
    echo "[iso-smoke] guest emitted PASS but QEMU exited with code $qemu_rc" >&2
    if [[ "$qemu_rc" == "124" || "$qemu_rc" == "137" ]]; then
        fail "live ISO passed checks but did not power off before timeout"
    fi
    fail "live ISO passed checks but QEMU did not exit cleanly"
fi

grep '^CYBREX_SMOKE:' "$NORMALIZED_LOG"
echo "[iso-smoke] PASS"
