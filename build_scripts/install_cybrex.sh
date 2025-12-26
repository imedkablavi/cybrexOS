#!/bin/bash
# install_cybrex.sh - Debian-based Installer for CybrexTech OS
# WARNING: This script will WIPE the target disk.

DISK="/dev/nvme0n1" # Modern Laptop Target
HOSTNAME="cybrex-node-01"
USER_NAME="owner"
DEBIAN_RELEASE="bookworm" # Stable Base

echo "=========================================="
echo "  CYBREX TECH OS - INSTALLER v2.0"
echo "  Base: Debian $DEBIAN_RELEASE"
echo "=========================================="

# 1. Disk Partitioning (UEFI + GPT)
echo "[*] Partitioning $DISK..."
sgdisk -Z $DISK
sgdisk -n 1:0:+512M -t 1:ef00 $DISK # EFI System
sgdisk -n 2:0:0     -t 2:8309 $DISK # LUKS Container

# 2. Encryption (LUKS2 with TPM support ready)
echo "[*] Encrypting Root Container..."
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 2000 ${DISK}p2
cryptsetup open ${DISK}p2 cryptroot

# 3. Filesystem (Btrfs with Subvolumes)
echo "[*] Formatting Filesystems..."
mkfs.vfat -F32 -n EFI ${DISK}p1
mkfs.btrfs -L cybrex_root /dev/mapper/cryptroot

echo "[*] Creating Btrfs Layout..."
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
umount /mnt

# 4. Mounting & Bootstrapping
echo "[*] Mounting & Bootstrapping Debian..."
mount -o noatime,compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,boot/efi,var,.snapshots}
mount -o noatime,compress=zstd,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd,subvol=@var /dev/mapper/cryptroot /mnt/var
mount ${DISK}p1 /mnt/boot/efi

# Debootstrap (requires host to have debootstrap installed)
debootstrap --arch amd64 --include=linux-image-amd64,grub-efi-amd64,network-manager,sudo,cryptsetup,btrfs-progs,firmware-linux $DEBIAN_RELEASE /mnt http://deb.debian.org/debian/

# 5. Core Configuration
echo "[*] Configuring System..."
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot to finalize
cat <<EOF | chroot /mnt /bin/bash
    echo "$HOSTNAME" > /etc/hostname
    
    # User Setup
    useradd -m -s /bin/bash -G sudo,video,plugdev $USER_NAME
    echo "$USER_NAME ALL=(ALL) ALL" > /etc/sudoers.d/owner
    
    # APT Sources (Contrib & Non-Free for Firmware)
    cat > /etc/apt/sources.list <<APT
deb http://deb.debian.org/debian/ $DEBIAN_RELEASE main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $DEBIAN_RELEASE-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ $DEBIAN_RELEASE-updates main contrib non-free non-free-firmware
APT
    
    apt update
    
    # Bootloader (GRUB)
    # Enable Cryptodisk
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="cryptdevice=UUID=$(blkid -s UUID -o value ${DISK}p2):cryptroot root=\/dev\/mapper\/cryptroot /' /etc/default/grub
    echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
    
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=CybrexOS
    update-grub
EOF

echo "[SUCCESS] CybrexTech OS Base Installed."
