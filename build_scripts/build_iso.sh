#!/bin/bash
# build_iso.sh: Experimental CybrexOS Debian live ISO pipeline.
# The ISO is NOT a qualified release artifact until its own boot/install matrix passes.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ISO_WORK_DIR:-$ROOT_DIR/iso_build}"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
ACTION="${1:-configure}"
DEBIAN_SUITE="${DEBIAN_SUITE:-bookworm}"
IMAGE_NAME="${ISO_IMAGE_NAME:-cybrexOS-live-amd64.iso}"

fail() { echo "[iso] ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo build_scripts/build_iso.sh [configure|build|clean]

  configure  Create a live-build configuration and inject the tracked rootfs overlay.
  build      Configure and run lb build. Output is copied to artifacts/.
  clean      Run lb clean --purge inside the dedicated ISO work directory.

This path is experimental. It does not auto-run the bare-metal installer and is not
included in stable releases until ISO boot and installer qualification are complete.
EOF
}

[[ $EUID -eq 0 ]] || fail "run as root"
case "$ACTION" in
    configure|build|clean) ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage >&2; fail "unknown action: $ACTION" ;;
esac
command -v lb >/dev/null 2>&1 || fail "live-build (lb) is required"
command -v rsync >/dev/null 2>&1 || fail "rsync is required"

mkdir -p "$WORK_DIR" "$ARTIFACTS_DIR"
cd "$WORK_DIR"

if [[ "$ACTION" == "clean" ]]; then
    lb clean --purge
    exit 0
fi

# Only clean live-build state inside the dedicated workspace.
lb clean --purge >/dev/null 2>&1 || true
lb config \
    --mode debian \
    --distribution "$DEBIAN_SUITE" \
    --architectures amd64 \
    --archive-areas "main contrib non-free non-free-firmware" \
    --linux-flavours amd64 \
    --bootappend-live "boot=live components hostname=cybrex-live" \
    --iso-volume "CYBREXOS_LIVE"

mkdir -p config/package-lists config/includes.chroot/usr/local/sbin
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
rsync -a --delete \
    --exclude 'etc/pacman.conf' \
    "$ROOT_DIR/rootfs/" config/includes.chroot/

# The installer remains opt-in and fail-closed. Nothing invokes it automatically.
install -m 0755 "$ROOT_DIR/build_scripts/install_cybrex.sh" \
    config/includes.chroot/usr/local/sbin/cybrex-install

cat >config/includes.chroot/etc/cybrex-live-release-status <<'EOF'
CybrexOS live media is experimental and not bare-metal qualified.
Run `cybrex-install --help` and read docs/BARE_METAL.md from the source repository.
EOF

if [[ "$ACTION" == "configure" ]]; then
    echo "[iso] live-build configuration prepared at $WORK_DIR"
    echo "[iso] no ISO was built; use: sudo build_scripts/build_iso.sh build"
    exit 0
fi

lb build
built_iso="$(find . -maxdepth 1 -type f -name '*.hybrid.iso' -o -name '*.iso' | sort | head -n1)"
[[ -n "$built_iso" && -f "$built_iso" ]] || fail "live-build completed without an ISO"
cp "$built_iso" "$ARTIFACTS_DIR/$IMAGE_NAME"
sha256sum "$ARTIFACTS_DIR/$IMAGE_NAME" >"$ARTIFACTS_DIR/${IMAGE_NAME}.sha256"
echo "[iso] built experimental artifact: $ARTIFACTS_DIR/$IMAGE_NAME"
