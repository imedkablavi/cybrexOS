#!/bin/bash
set -Eeuo pipefail

IMAGE="${1:-artifacts/CybrexTech_Dev_Preview.vmdk}"
REPORT="${RELEASE_VMDK_REPORT:-artifacts/qualification-release-vmdk.txt}"
QEMU_LOG="${RELEASE_VMDK_QEMU_LOG:-artifacts/qualification-release-vmdk-qemu.log}"
TIMEOUT_SECONDS="${RELEASE_VMDK_TIMEOUT:-240}"
SSH_PORT="${RELEASE_VMDK_SSH_PORT:-2222}"
QUALIFY_USER="${QUALIFY_USER:-cybrex}"
QUALIFY_PASSWORD="${QUALIFY_PASSWORD:-cybrex}"
TMP_DIR=""
QEMU_PID=""

fail() {
    echo "[release-vmdk] ERROR: $*" >&2
    [[ -f "$QEMU_LOG" ]] && tail -n 120 "$QEMU_LOG" >&2 || true
    exit 1
}

cleanup() {
    set +e
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for bin in qemu-system-x86_64 qemu-img ssh sshpass; do
    command -v "$bin" >/dev/null 2>&1 || fail "$bin is required"
done
[[ -f "$IMAGE" ]] || fail "VMDK not found: $IMAGE"
qemu-img check -f vmdk "$IMAGE" >/dev/null || fail "qemu-img check failed"

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

mkdir -p "$(dirname "$REPORT")" "$(dirname "$QEMU_LOG")"
: >"$QEMU_LOG"
TMP_DIR="$(mktemp -d)"
cp "$OVMF_VARS" "$TMP_DIR/OVMF_VARS.fd"

qemu-system-x86_64 \
    -machine q35,accel=tcg \
    -cpu max \
    -m 1536 \
    -smp 2 \
    -nodefaults \
    -device virtio-rng-pci \
    -device virtio-blk-pci,drive=osdisk \
    -drive if=none,id=osdisk,format=vmdk,file="$IMAGE",cache=unsafe \
    -device virtio-net-pci,netdev=net0 \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$TMP_DIR/OVMF_VARS.fd" \
    -display none \
    -serial none \
    -monitor none \
    -no-reboot \
    >"$QEMU_LOG" 2>&1 &
QEMU_PID=$!

export SSHPASS="$QUALIFY_PASSWORD"
SSH_OPTS=(
    -p "$SSH_PORT"
    -o BatchMode=no
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
)

deadline=$((SECONDS + TIMEOUT_SECONDS))
until sshpass -e ssh "${SSH_OPTS[@]}" "$QUALIFY_USER@127.0.0.1" true >/dev/null 2>&1; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        set +e
        wait "$QEMU_PID"
        rc=$?
        set -e
        QEMU_PID=""
        fail "QEMU exited before SSH became ready (rc=$rc)"
    fi
    (( SECONDS < deadline )) || fail "SSH did not become ready within ${TIMEOUT_SECONDS}s"
    sleep 2
done

REMOTE_CHECKS='set -eu
state="$(systemctl is-system-running 2>/dev/null || true)"
case "$state" in
  running|degraded) ;;
  *) echo "RELEASE_VMDK:FAIL:systemd:$state"; exit 1 ;;
esac
for svc in systemd-networkd.service systemd-resolved.service nftables.service; do
  systemctl is-active --quiet "$svc" || { echo "RELEASE_VMDK:FAIL:service:$svc"; exit 1; }
done
ip -4 -o addr show scope global | grep -q . || { echo "RELEASE_VMDK:FAIL:ipv4"; exit 1; }
ip -4 route show default | grep -q . || { echo "RELEASE_VMDK:FAIL:default-route"; exit 1; }
nft list ruleset >/dev/null
nft list chain inet cybrex_fw inbound | grep -Eq "policy[[:space:]]+drop" || { echo "RELEASE_VMDK:FAIL:nft-inbound"; exit 1; }
nft list chain inet cybrex_fw outbound | grep -Eq "policy[[:space:]]+accept" || { echo "RELEASE_VMDK:FAIL:nft-outbound"; exit 1; }
failed="$(systemctl --failed --no-legend --plain 2>/dev/null || true)"
[ -z "$failed" ] || { printf "%s\n" "$failed" >&2; echo "RELEASE_VMDK:FAIL:failed-units"; exit 1; }
printf "RELEASE_VMDK:SYSTEMD:%s\n" "$state"
echo "RELEASE_VMDK:NETWORK:qualified"
echo "RELEASE_VMDK:NFTABLES:qualified"
echo "RELEASE_VMDK:PASS"'

{
    printf '%s\n' "$QUALIFY_PASSWORD"
    printf '%s\n' "$REMOTE_CHECKS"
} | sshpass -e ssh "${SSH_OPTS[@]}" "$QUALIFY_USER@127.0.0.1" 'sudo -S -p "" sh -s' >"$REPORT" \
    || fail "in-guest qualification checks failed"

grep -q '^RELEASE_VMDK:PASS$' "$REPORT" || fail "PASS marker missing from release VMDK report"

# Ask the guest to power off through systemd, then require QEMU to exit cleanly.
{
    printf '%s\n' "$QUALIFY_PASSWORD"
    printf '%s\n' 'systemctl poweroff'
} | sshpass -e ssh "${SSH_OPTS[@]}" "$QUALIFY_USER@127.0.0.1" 'sudo -S -p "" sh -s' >/dev/null 2>&1 || true

shutdown_deadline=$((SECONDS + 60))
while kill -0 "$QEMU_PID" 2>/dev/null; do
    (( SECONDS < shutdown_deadline )) || fail "guest passed checks but did not power off within 60s"
    sleep 1
done

set +e
wait "$QEMU_PID"
qemu_rc=$?
set -e
QEMU_PID=""
[[ "$qemu_rc" == "0" ]] || fail "QEMU exited with code $qemu_rc after guest poweroff"

cat "$REPORT"
echo "[release-vmdk] PASS"
