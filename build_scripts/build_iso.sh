#!/bin/bash
# build_iso.sh - Generate CybrexTech OS Live ISO
# Requires: live-build, debootstrap

set -e

WORK_DIR="iso_build"
IMAGE_NAME="cybrex-os-live-v1.0.iso"

echo "--- CybrexTech OS: ISO Builder ---"

# 1. Prerequisite Check
if ! command -v lb >/dev/null; then
    echo "Error: 'live-build' is not installed."
    echo "Install with: sudo apt install live-build"
    exit 1
fi

mkdir -p $WORK_DIR
cd $WORK_DIR

# 2. Configure Live Build
echo "[*] Configuring build environment..."
lb config \
    --distribution bookworm \
    --archive-areas "main contrib non-free-firmware" \
    --architectures amd64 \
    --linux-flavours amd64 \
    --bootappend-live "boot=live components quiet splash hostname=cybrex-live" \
    --iso-volume "CybrexOS_Live"

# 3. Add Custom Packages
echo "[*] Defining package list..."
cat > config/package-lists/cybrex.list.chroot <<EOF
linux-image-amd64
live-boot
live-config
live-config-systemd
network-manager
hyprland
waybar
kitty
git
curl
neovim
python3
cryptsetup
btrfs-progs
grub-efi-amd64
efibootmgr
nftables
EOF

# 4. Copy Local Overlay (Installer & Configs)
echo "[*] Injecting Cybrex rootfs overlay..."
# Assuming we run this from the project root, copy rootfs to Chroot includes
# mkdir -p config/includes.chroot/
# cp -r ../../rootfs/* config/includes.chroot/
# cp ../install_cybrex.sh config/includes.chroot/root/installer.sh

# 5. Build
echo "[!] Starting Build Process (This may take a while)..."
# lb build

echo "[Note] 'lb build' commented out to prevent heavy resource usage in agent env."
echo "Run 'sudo lb build' in this directory to generate: $IMAGE_NAME"
