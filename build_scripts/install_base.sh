#!/bin/bash
# install_base.sh - Zero-Copy Installer for Single Owner OS
# WARNING: This script will WIPE the target disk.

DISK="/dev/sda" # Target Disk (Change me)
HOSTNAME="ghost-os"
USER_NAME="owner"

echo "=========================================="
echo "  SINGLE OWNER OS - INSTALLER v1.0"
echo "=========================================="

# 1. Disk Partitioning (UEFI)
echo "[*] Partitioning $DISK..."
sgdisk -Z $DISK
sgdisk -n 1:0:+512M -t 1:ef00 $DISK # EFI
sgdisk -n 2:0:+4G   -t 2:8200 $DISK # Swap
sgdisk -n 3:0:0     -t 3:8300 $DISK # Root

# 2. Encryption (LUKS2)
echo "[*] Encrypting Root Partition..."
cryptsetup luksFormat --type luks2 ${DISK}3
cryptsetup open ${DISK}3 cryptroot

# 3. Filesystem (Btrfs)
echo "[*] Formatting Btrfs..."
mkfs.fat -F32 ${DISK}1
mkswap ${DISK}2
mkfs.btrfs -L ghost_root /dev/mapper/cryptroot

# 4. Subvolumes (Snapshots)
echo "[*] Creating Subvolumes..."
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
umount /mnt

# 5. Mounting
mount -o compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,boot,var/log,.snapshots}
mount -o compress=zstd,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o compress=zstd,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount ${DISK}1 /mnt/boot
swapon ${DISK}2

# 6. Bootstrap Base System
echo "[*] Bootstrapping Base System (Pacstrap)..."
# Using hardened pacman.conf
pacman -Sy archlinux-keyring
pacstrap -C ../rootfs/etc/pacman.conf /mnt base base-devel linux-hardened linux-firmware btrfs-progs neovim git networkmanager

# 7. System Configuration
echo "[*] Configuring System..."
genfstab -U /mnt >> /mnt/etc/fstab
arch-chroot /mnt /bin/bash <<EOF
    echo "$HOSTNAME" > /etc/hostname
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    hwclock --systohc
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    
    # User Setup
    useradd -m -G wheel -s /bin/bash $USER_NAME
    echo "$USER_NAME ALL=(ALL) ALL" >> /etc/sudoers
    
    # Kernel Hardening
    cat /sys/custom/config/cmdline_hardening.txt > /boot/loader/entries/arch.conf
EOF

echo "[SUCCESS] Base System Installed. Reboot to configure Phase 3 (Owner Layer)."
