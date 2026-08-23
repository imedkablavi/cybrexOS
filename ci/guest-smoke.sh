#!/bin/bash
set -Eeuo pipefail

LOG_FILE=/var/log/cybrex-boot-qualification.log
SERIAL=/dev/ttyS0

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

emit() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE" >/dev/null
    if [[ -w "$SERIAL" ]]; then
        printf '%s\n' "$*" >"$SERIAL"
    fi
}

fail() {
    local reason="$*"
    trap - ERR
    set +e
    emit "CYBREX_SMOKE:FAIL:$reason"
    sync
    systemctl --no-block poweroff
    exit 1
}

trap 'fail "unexpected-error-line-$LINENO"' ERR

emit "CYBREX_SMOKE:BEGIN"
emit "CYBREX_SMOKE:KERNEL:$(uname -r)"

# Give systemd a bounded amount of time to finish normal boot jobs. The probe is
# launched by a transient timer, so it is not itself part of the boot transaction.
for _ in $(seq 1 60); do
    state="$(systemctl is-system-running 2>/dev/null || true)"
    case "$state" in
        running|degraded) break ;;
    esac
    sleep 1
done

state="$(systemctl is-system-running 2>/dev/null || true)"
[[ "$state" == "running" || "$state" == "degraded" ]] || fail "systemd-state-$state"
emit "CYBREX_SMOKE:SYSTEMD:$state"

for svc in systemd-networkd.service systemd-resolved.service nftables.service; do
    systemctl is-active --quiet "$svc" || fail "inactive-$svc"
    emit "CYBREX_SMOKE:SERVICE:$svc:active"
done

# The qualification image uses QEMU user-mode networking and a virtio NIC.
# Wait for a non-loopback global IPv4 address and a default route.
network_ok=0
for _ in $(seq 1 60); do
    if ip -4 -o addr show scope global | grep -q . && ip -4 route show default | grep -q '^default '; then
        network_ok=1
        break
    fi
    sleep 1
done
[[ "$network_ok" == "1" ]] || fail "network-no-global-ipv4-or-default-route"
emit "CYBREX_SMOKE:NETWORK:ipv4-and-default-route"

nft list ruleset >/tmp/cybrex-nft-ruleset.txt 2>&1 || fail "nft-list-ruleset"
nft list chain inet cybrex_fw inbound 2>/dev/null | grep -Eq 'policy drop' || fail "nft-inbound-policy-not-drop"
nft list chain inet cybrex_fw outbound 2>/dev/null | grep -Eq 'policy accept' || fail "nft-outbound-policy-not-accept"
emit "CYBREX_SMOKE:NFTABLES:qualified"

# Any failed unit after the bounded boot window is a qualification failure.
failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
if [[ -n "${failed_units// }" ]]; then
    fail "failed-units-${failed_units// /,}"
fi

emit "CYBREX_SMOKE:PASS"
sync
systemctl --no-block poweroff || fail "poweroff-request-failed"
