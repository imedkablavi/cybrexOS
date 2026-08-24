#!/bin/bash
# build_iso.sh: Experimental CybrexOS Debian live ISO pipeline.
# The ISO is NOT a qualified release artifact until its own boot/install matrix passes.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ISO_WORK_DIR:-$ROOT_DIR/iso_build}"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
ACTION="${1:-configure}"
DEBIAN_SUITE="${DEBIAN_SUITE:-bookworm}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian/}"
SECURITY_MIRROR="${SECURITY_MIRROR:-http://security.debian.org/debian-security/}"
IMAGE_NAME="${ISO_IMAGE_NAME:-cybrexOS-live-amd64.iso}"
CI_SMOKE="${CYBREX_ISO_CI_SMOKE:-0}"

fail() { echo "[iso] ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo build_scripts/build_iso.sh [configure|build|clean]

  configure  Create a live-build configuration and inject the tracked rootfs overlay.
  build      Configure and run lb build. Output is copied to artifacts/.
  clean      Run lb clean --purge inside the dedicated ISO work directory.

Environment:
  CYBREX_ISO_CI_SMOKE=1  Add a CI-only boot probe and serial console parameters.

This path is experimental. It does not auto-run the bare-metal installer and is not
included in stable releases until ISO boot and installer qualification are complete.
EOF
}

cleanup() {
    set +e
    if [[ -d "$WORK_DIR" ]] && command -v lb >/dev/null 2>&1; then
        (cd "$WORK_DIR" && lb clean >/dev/null 2>&1) || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ $EUID -eq 0 ]] || fail "run as root"
case "$ACTION" in
    configure|build|clean) ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage >&2; fail "unknown action: $ACTION" ;;
esac
case "$CI_SMOKE" in
    0|1) ;;
    *) fail "CYBREX_ISO_CI_SMOKE must be 0 or 1" ;;
esac
command -v lb >/dev/null 2>&1 || fail "live-build (lb) is required"
command -v rsync >/dev/null 2>&1 || fail "rsync is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

mkdir -p "$WORK_DIR" "$ARTIFACTS_DIR"
cd "$WORK_DIR"

if [[ "$ACTION" == "clean" ]]; then
    trap - EXIT
    lb clean --purge
    exit 0
fi

# Only clean live-build state inside the dedicated workspace. Never operate on host mounts.
lb clean --purge >/dev/null 2>&1 || true

bootappend="boot=live components hostname=cybrex-live"
if [[ "$CI_SMOKE" == "1" ]]; then
    # Keep VGA as a fallback while making the serial console deterministic for CI evidence.
    bootappend+=" console=tty0 console=ttyS0,115200n8 systemd.log_target=console"
fi

lb config \
    --mode debian \
    --distribution "$DEBIAN_SUITE" \
    --architectures amd64 \
    --archive-areas "main contrib non-free non-free-firmware" \
    --linux-flavours amd64 \
    --binary-images iso-hybrid \
    --debian-installer false \
    --mirror-bootstrap "$DEBIAN_MIRROR" \
    --mirror-chroot "$DEBIAN_MIRROR" \
    --mirror-chroot-security "$SECURITY_MIRROR" \
    --mirror-binary "$DEBIAN_MIRROR" \
    --mirror-binary-security "$SECURITY_MIRROR" \
    --bootappend-live "$bootappend" \
    --checksums sha256 \
    --iso-volume "CYBREXOS_LIVE"

mkdir -p config/package-lists
cat >config/package-lists/cybrex.list.chroot <<'EOF'
linux-image-amd64
live-boot
live-config
live-config-systemd
systemd-sysv
systemd-resolved
nftables
iproute2
sudo
ca-certificates
curl
python3
EOF

# Inject the same tracked rootfs overlay used by the VM builder. The legacy pacman
# configuration is irrelevant on Debian live media and is intentionally excluded.
mkdir -p config/includes.chroot
rsync -a \
    --exclude 'etc/pacman.conf' \
    "$ROOT_DIR/rootfs/" config/includes.chroot/

# Normalize tracked text exactly as the VM builder does. Some historical files contain
# CRLF; systemd and nftables configuration in an ISO must not depend on tolerant parsing.
while IFS= read -r file; do
    sed -i 's/\r$//' "$file"
done < <(find config/includes.chroot/etc -type f \
    \( -name '*.service' -o -name '*.timer' -o -name '*.network' -o -name '*.conf' -o -name 'nftables.conf' \) \
    -print 2>/dev/null)

# The installer remains opt-in and fail-closed. Nothing invokes it automatically.
install -D -m 0755 "$ROOT_DIR/build_scripts/install_cybrex.sh" \
    config/includes.chroot/usr/local/sbin/cybrex-install

install -D -m 0644 /dev/stdin config/includes.chroot/etc/cybrex-live-release-status <<'EOF'
CybrexOS live media is experimental and not bare-metal qualified.
The included cybrex-install command is preflight-only; destructive installation remains disabled.
EOF

# Chroot hooks are the supported live-build mechanism for enabling services after package
# installation and includes have been applied.
mkdir -p config/hooks/live
cat >config/hooks/live/0100-cybrex-services.hook.chroot <<'EOF'
#!/bin/sh
set -eu
systemctl enable systemd-networkd.service
systemctl enable systemd-resolved.service
systemctl enable nftables.service
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
EOF
chmod 0755 config/hooks/live/0100-cybrex-services.hook.chroot

if [[ "$CI_SMOKE" == "1" ]]; then
    [[ -f "$ROOT_DIR/ci/guest-smoke.sh" ]] || fail "missing ci/guest-smoke.sh"
    [[ -f "$ROOT_DIR/ci/cybrex-ci-smoke.service" ]] || fail "missing ci/cybrex-ci-smoke.service"
    install -D -m 0755 "$ROOT_DIR/ci/guest-smoke.sh" \
        config/includes.chroot/usr/local/libexec/cybrex-ci-smoke
    install -D -m 0644 "$ROOT_DIR/ci/cybrex-ci-smoke.service" \
        config/includes.chroot/etc/systemd/system/cybrex-ci-smoke.service
    cat >>config/hooks/live/0100-cybrex-services.hook.chroot <<'EOF'
systemctl enable cybrex-ci-smoke.service
EOF
fi

if [[ "$ACTION" == "configure" ]]; then
    trap - EXIT
    echo "[iso] live-build configuration prepared at $WORK_DIR"
    echo "[iso] no ISO was built; use: sudo build_scripts/build_iso.sh build"
    exit 0
fi

lb build
built_iso="$(find . -maxdepth 1 -type f \( -name '*.hybrid.iso' -o -name '*.iso' \) | sort | head -n1)"
[[ -n "$built_iso" && -f "$built_iso" ]] || fail "live-build completed without an ISO"

cp "$built_iso" "$ARTIFACTS_DIR/$IMAGE_NAME"
(
    cd "$ARTIFACTS_DIR"
    sha256sum "$IMAGE_NAME" >"${IMAGE_NAME}.sha256"
    sha256sum -c "${IMAGE_NAME}.sha256"
)

trap - EXIT
echo "[iso] built experimental artifact: $ARTIFACTS_DIR/$IMAGE_NAME"
echo "[iso] status: experimental; QEMU boot success does not imply bare-metal compatibility"
