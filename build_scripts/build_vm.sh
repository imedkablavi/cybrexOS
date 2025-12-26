#!/bin/bash
# build_vm.sh: Deterministic VMware image builder for CybrexTech OS (WSL2-safe)
set -euo pipefail
IFS=$'\n\t'
[[ "${DEBUG:-0}" == "1" ]] && set -x

log_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log_info() { printf '[%s] [INFO] %s\n' "$(log_ts)" "$*"; }
log_warn() { printf '[%s] [WARN] %s\n' "$(log_ts)" "$*" >&2; }
log_err()  { printf '[%s] [ERR ] %s\n' "$(log_ts)" "$*" >&2; }
fatal()    { log_err "$*"; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || fatal "Run as root (sudo)."; }
require_wsl2() { uname -r | grep -qi microsoft || log_warn "Not running under WSL2 kernel; continuing anyway."; }
guard_mnt_c()  { if [[ "$ROOT_DIR" == /mnt/c/* ]]; then fatal "Do not run from /mnt/c; use /mnt/d or another non-C path."; fi; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
BUILD_DIR="$ROOT_DIR/build_vm"
MNT_DIR="$BUILD_DIR/mnt"
VERIFY_MNT="$BUILD_DIR/verify"
LOG_DIR="$BUILD_DIR/logs"
REPORT_FILE="$BUILD_DIR/report.txt"
IMAGE_RAW="$BUILD_DIR/CybrexTech_Dev_Preview.img"
VMDK_PATH="$ARTIFACTS_DIR/CybrexTech_Dev_Preview.vmdk"
VMX_PATH="$ROOT_DIR/CybrexTech_Dev_Preview.vmx"
ROOTFS_OVERLAY="$ROOT_DIR/rootfs"
WEB_PREVIEW_DIR="$ROOT_DIR/cybrex-preview"
GUI_STAGING="$BUILD_DIR/gui-dist"

DEBIAN_SUITE="${DEBIAN_SUITE:-bookworm}"
DISK_SIZE="${DISK_SIZE:-20G}"
HOSTNAME="${HOSTNAME:-cybrex-dev}"
USERNAME="${USERNAME:-cybrex}"
SKIP_GUI="${SKIP_GUI:-0}"

REQUIRED_BINS=(debootstrap qemu-img parted losetup mkfs.vfat mkfs.ext4 rsync mount umount blkid chroot find grep awk sed)

normalize_file() { local f="$1"; [[ -f "$f" ]] || return 0; sed -i 's/\r$//' "$f"; }

cleanup_mounts_and_loops() {
    set +e
    # Unmount only inside build directories
    awk '{print $2}' /proc/mounts | grep -E "^${MNT_DIR}(/|$)|^${VERIFY_MNT}(/|$)" | sort -r | while read -r mp; do
        umount "$mp" 2>/dev/null
    done
    # Detach loops we created or that still point to our images
    for loop in "${LOOP_DEV:-}" "${VERIFY_LOOP:-}"; do
        [[ -n "$loop" ]] && losetup -d "$loop" 2>/dev/null
    done
    # Detach stale loops pointing to our raw image from previous runs
    while read -r dev; do
        [[ -n "$dev" ]] && losetup -d "$dev" 2>/dev/null
    done < <(losetup -a | awk -F: -v img="$IMAGE_RAW" '$2 ~ img {print $1}')
    rm -rf "$GUI_STAGING"
}
trap cleanup_mounts_and_loops EXIT

require_root
require_wsl2
guard_mnt_c

for bin in "${REQUIRED_BINS[@]}"; do
    command -v "$bin" >/dev/null 2>&1 || fatal "Missing dependency: $bin"
done

export DEBIAN_FRONTEND=noninteractive

pre_clean() {
    log_info "[*] Cleaning previous residues..."
    cleanup_mounts_and_loops
    rm -rf "$BUILD_DIR"
    mkdir -p "$ARTIFACTS_DIR" "$BUILD_DIR" "$MNT_DIR" "$VERIFY_MNT" "$LOG_DIR"
    rm -f "$VMDK_PATH" "$REPORT_FILE"
}

normalize_permissions() {
    local target="$1"
    find "$target/etc/systemd/system" -maxdepth 1 -type f -name "*.service" -exec chmod 0644 {} + 2>/dev/null || true
    find "$target/lib/systemd/system" -maxdepth 1 -type f -name "*.service" -exec chmod 0644 {} + 2>/dev/null || true
    find "$target/usr/local/bin" -type f -exec chmod 0755 {} + 2>/dev/null || true
    [[ -d "$target/etc/sudoers.d" ]] && chmod 0440 "$target"/etc/sudoers.d/* 2>/dev/null || true
}

normalize_texts() {
    local target="$1"
    normalize_file "$target/etc/default/grub"
    normalize_file "$target/etc/fstab"
    normalize_file "$target/etc/hostname"
    find "$target/etc/systemd/system" -maxdepth 1 -type f -name "*.service" -exec sed -i 's/\r$//' {} + 2>/dev/null || true
    find "$target/lib/systemd/system" -maxdepth 1 -type f -name "*.service" -exec sed -i 's/\r$//' {} + 2>/dev/null || true
}

disable_or_validate_local_apt_repo() {
    local target="$1"
    local list="$target/etc/apt/sources.list.d/cybrex-local.list"
    local repo="$target/opt/cybrex/repo"
    [[ -f "$list" ]] || return 0
    if [[ -d "$repo" && ( -f "$repo/Packages" || -f "$repo/Packages.gz" || -f "$repo/Release" ) ]]; then
        log_info "[*] Local repo present, keeping cybrex-local.list."
        return 0
    fi
    log_warn "[!] Disabling cybrex-local.list (missing local repo Packages)."
    sed -i 's|^[[:space:]]*deb |# DISABLED missing repo: deb |' "$list"
}

ensure_policy_rc_d() {
    local target="$1"
    mkdir -p "$target/usr/sbin"
    cat > "$target/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
    chmod 755 "$target/usr/sbin/policy-rc.d"
}

remove_policy_rc_d() {
    local target="$1"
    rm -f "$target/usr/sbin/policy-rc.d" || true
}

ensure_default_grub() {
    local target="$1"
    if [[ ! -f "$target/etc/default/grub" ]]; then
        cat > "$target/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=Cybrex
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
EOF
    fi
}

ensure_networkd_config() {
    local target="$1"
    local netdir="$target/etc/systemd/network"
    mkdir -p "$netdir"
    if ! ls "$netdir"/*.network >/dev/null 2>&1; then
        cat > "$netdir/10-wired-dhcp.network" <<'EOF'
[Match]
Name=en*

[Network]
DHCP=ipv4
EOF
    fi
}

enable_if_exists() {
    local target="$1" service="$2"
    if [[ -f "$target/lib/systemd/system/$service" || -f "$target/etc/systemd/system/$service" ]]; then
        chroot "$target" systemctl enable "$service" || true
    fi
}

update_vmx() {
    local vmx="$1" vmdk_rel="artifacts/CybrexTech_Dev_Preview.vmdk"
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "19"
displayName = "CybrexTech OS (Dev Preview)"
guestOS = "debian12-64"
memsize = "4096"
numvcpus = "2"
cpuid.coresPerSocket = "1"
firmware = "efi"
scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "e1000e"
usb.present = "TRUE"
ehci.present = "TRUE"
usb_xhci.present = "TRUE"
sound.present = "TRUE"
sound.virtualDev = "hdaudio"
EOF
    # Preserve existing lines except the ones we control
    {
        grep -v -E '^(firmware|scsi0:0.fileName|scsi0.virtualDev|scsi0.present|scsi0:0.present|displayName|guestOS|memsize|numvcpus|cpuid.coresPerSocket|ethernet0\.present|ethernet0\.connectionType|ethernet0\.virtualDev|usb\.present|ehci\.present|usb_xhci\.present|sound\.present|sound\.virtualDev|virtualHW\.version|config\.version|\.encoding|nvram|extendedConfigFile|vmxstats\.filename|vmci0\.present|tools\.syncTime)' "$vmx" 2>/dev/null || true
        cat "$tmp"
        echo "scsi0:0.fileName = \"$vmdk_rel\""
        echo "nvram = \"CybrexTech_Dev_Preview.nvram\""
        echo "extendedConfigFile = \"CybrexTech_Dev_Preview.vmxf\""
        echo "vmxstats.filename = \"CybrexTech_Dev_Preview.scoreboard\""
    } | awk 'NF' > "${vmx}.new"
    mv "${vmx}.new" "$vmx"
    rm -f "$tmp"
}

write_report() {
    {
        echo "Build summary ($(log_ts))"
        echo "ROOT_DIR=$ROOT_DIR"
        echo "ARTIFACTS=$VMDK_PATH"
    echo "RAW_IMAGE=$IMAGE_RAW"
    echo "VMX=$VMX_PATH"
    echo "HOSTNAME=$HOSTNAME"
    echo "USERNAME=$USERNAME"
} > "$REPORT_FILE"
}

pre_clean

log_info "[*] Creating raw disk ($DISK_SIZE)..."
truncate -s "$DISK_SIZE" "$IMAGE_RAW"

log_info "[*] Partitioning (GPT: EFI + root)..."
parted -s "$IMAGE_RAW" mklabel gpt
parted -s "$IMAGE_RAW" mkpart ESP fat32 1MiB 513MiB
parted -s "$IMAGE_RAW" set 1 esp on
parted -s "$IMAGE_RAW" mkpart ROOT ext4 513MiB 100%

log_info "[*] Attaching loop device..."
LOOP_DEV=$(losetup -P --show -f "$IMAGE_RAW")
ESP_DEV="${LOOP_DEV}p1"
ROOT_DEV="${LOOP_DEV}p2"

log_info "[*] Formatting filesystems..."
mkfs.vfat -F32 "$ESP_DEV"
mkfs.ext4 -F "$ROOT_DEV"

log_info "[*] Mounting target root..."
mount "$ROOT_DEV" "$MNT_DIR"
mkdir -p "$MNT_DIR/boot/efi"
mount "$ESP_DEV" "$MNT_DIR/boot/efi"

log_info "[*] Bootstrapping Debian ($DEBIAN_SUITE)..."
debootstrap --arch=amd64 \
    --include=linux-image-amd64,systemd,systemd-sysv,debian-archive-keyring,locales,grub-efi-amd64,openssh-server,sudo,ca-certificates,lsb-release,open-vm-tools,nftables,iproute2 \
    "$DEBIAN_SUITE" "$MNT_DIR" http://deb.debian.org/debian/ || fatal "debootstrap failed"

log_info "[*] Applying Cybrex rootfs overlay..."
if [[ -d "$ROOTFS_OVERLAY" ]]; then
    rsync -a "$ROOTFS_OVERLAY"/ "$MNT_DIR"/
else
    log_warn "[!] Overlay not found at $ROOTFS_OVERLAY (continuing without it)."
fi

disable_or_validate_local_apt_repo "$MNT_DIR"
ensure_default_grub "$MNT_DIR"
normalize_texts "$MNT_DIR"
normalize_permissions "$MNT_DIR"
ensure_networkd_config "$MNT_DIR"

log_info "[*] Base system configuration..."
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
ESP_UUID=$(blkid -s UUID -o value "$ESP_DEV")

cat > "$MNT_DIR/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 defaults 0 1
UUID=$ESP_UUID /boot/efi vfat umask=0077 0 1
EOF

echo "$HOSTNAME" > "$MNT_DIR/etc/hostname"

cat > "$MNT_DIR/etc/apt/sources.list" <<EOF
deb http://deb.debian.org/debian/ $DEBIAN_SUITE main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $DEBIAN_SUITE-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ $DEBIAN_SUITE-updates main contrib non-free non-free-firmware
EOF

mkdir -p "$MNT_DIR/var/log/cybrex" "$MNT_DIR/var/run/cybrex"

log_info "[*] Binding host pseudo-filesystems..."
mount --bind /dev "$MNT_DIR/dev"
mount --bind /proc "$MNT_DIR/proc"
mount --bind /sys "$MNT_DIR/sys"

log_info "[*] Preparing chroot (DNS + policy-rc.d)..."
if [[ -f /etc/resolv.conf ]]; then
    cp -L /etc/resolv.conf "$MNT_DIR/etc/resolv.conf"
else
    echo "nameserver 1.1.1.1" > "$MNT_DIR/etc/resolv.conf"
fi
ensure_policy_rc_d "$MNT_DIR"

log_info "[*] Installing systemd-resolved (inside chroot)..."
chroot "$MNT_DIR" apt-get update
chroot "$MNT_DIR" apt-get install -y systemd-resolved

log_info "[*] Finalizing inside chroot..."
chroot "$MNT_DIR" bash -c "echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen && locale-gen"
chroot "$MNT_DIR" bash -c "echo 'LANG=en_US.UTF-8' > /etc/default/locale"

if ! chroot "$MNT_DIR" id "$USERNAME" >/dev/null 2>&1; then
    chroot "$MNT_DIR" useradd -m -s /bin/bash -G sudo,adm,systemd-journal "$USERNAME"
    echo "$USERNAME:$USERNAME" | chroot "$MNT_DIR" chpasswd
fi
echo "$USERNAME ALL=(ALL) ALL" > "$MNT_DIR/etc/sudoers.d/$USERNAME"
chmod 440 "$MNT_DIR/etc/sudoers.d/$USERNAME"

rm -f "$MNT_DIR/etc/resolv.conf"
ln -sf /run/systemd/resolve/stub-resolv.conf "$MNT_DIR/etc/resolv.conf"

# Network stack: systemd-networkd/resolved only (no NetworkManager)
enable_if_exists "$MNT_DIR" systemd-networkd.service
enable_if_exists "$MNT_DIR" systemd-resolved.service
enable_if_exists "$MNT_DIR" ssh.service
enable_if_exists "$MNT_DIR" cybrex-daemon.service
enable_if_exists "$MNT_DIR" cybrex-demo.service

log_info "[*] Installing GRUB (EFI)..."
chroot "$MNT_DIR" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Cybrex --removable --recheck
chroot "$MNT_DIR" update-grub || fatal "update-grub failed"

# Copy GUI payload if built
if [[ -d "$GUI_STAGING" ]]; then
    log_info "[*] Copying GUI assets..."
    mkdir -p "$MNT_DIR/opt/cybrex/gui"
    rsync -a "$GUI_STAGING"/ "$MNT_DIR/opt/cybrex/gui"/
fi

remove_policy_rc_d "$MNT_DIR"

log_info "[*] Unmounting chroot binds..."
umount "$MNT_DIR/proc"
umount "$MNT_DIR/sys"
umount "$MNT_DIR/dev"
umount "$MNT_DIR/boot/efi"
umount "$MNT_DIR"
losetup -d "$LOOP_DEV"
LOOP_DEV=""

log_info "[*] Converting raw image to VMDK..."
qemu-img convert -f raw -O vmdk "$IMAGE_RAW" "$VMDK_PATH"

log_info "[*] Validating VMDK..."
qemu-img info "$VMDK_PATH" >/dev/null 2>&1 || fatal "qemu-img info failed on VMDK"

log_info "[*] Validating boot artifacts inside raw image..."
VERIFY_LOOP=$(losetup -P --show -f --read-only "$IMAGE_RAW")
VERIFY_ROOT="${VERIFY_LOOP}p2"
VERIFY_ESP="${VERIFY_LOOP}p1"
mount -o ro "$VERIFY_ROOT" "$VERIFY_MNT"
mkdir -p "$VERIFY_MNT/boot/efi" 2>/dev/null || true
mount -o ro "$VERIFY_ESP" "$VERIFY_MNT/boot/efi"

[[ -s "$VERIFY_MNT/boot/grub/grub.cfg" ]] || fatal "Missing /boot/grub/grub.cfg"
grep -q "menuentry" "$VERIFY_MNT/boot/grub/grub.cfg" || fatal "No menuentry found in grub.cfg"
[[ -f "$VERIFY_MNT/boot/efi/EFI/BOOT/BOOTX64.EFI" ]] || fatal "Missing EFI bootloader BOOTX64.EFI"
[[ -f "$VERIFY_MNT/etc/fstab" ]] || fatal "Missing /etc/fstab"
grep -q "^UUID=" "$VERIFY_MNT/etc/fstab" || fatal "/etc/fstab does not use UUID entries"
[[ -f "$VERIFY_MNT/etc/hostname" ]] || fatal "Missing /etc/hostname"
HOSTNAME_VERIFIED=$(cat "$VERIFY_MNT/etc/hostname")
[[ "$HOSTNAME_VERIFIED" == "$HOSTNAME" ]] || fatal "Hostname mismatch (expected $HOSTNAME, got $HOSTNAME_VERIFIED)"

# Kernel/initrd/grub verification
KERNEL_VMLINUZ=$(find "$VERIFY_MNT/boot" -maxdepth 1 -type f -name "vmlinuz-*" -printf "%f\n" | head -n 1)
[[ -n "$KERNEL_VMLINUZ" ]] || fatal "No /boot/vmlinuz-* found"
KERNEL_VERSION="${KERNEL_VMLINUZ#vmlinuz-}"
INITRD_IMG=$(find "$VERIFY_MNT/boot" -maxdepth 1 -type f -name "initrd.img-*" -printf "%f\n" | head -n 1)
[[ -n "$INITRD_IMG" ]] || fatal "No /boot/initrd.img-* found"
[[ -d "$VERIFY_MNT/lib/modules/$KERNEL_VERSION" ]] || fatal "Missing modules directory for $KERNEL_VERSION"

GRUB_CFG="$VERIFY_MNT/boot/grub/grub.cfg"
GRUB_HAS_LINUX_LINE="no"
GRUB_HAS_INITRD_LINE="no"
GRUB_ROOT_UUID=""
if grep -Eq '^[[:space:]]*linux[[:space:]]+/boot/vmlinuz-' "$GRUB_CFG"; then GRUB_HAS_LINUX_LINE="yes"; fi
if grep -Eq '^[[:space:]]*initrd[[:space:]]+/boot/initrd\.img-' "$GRUB_CFG"; then GRUB_HAS_INITRD_LINE="yes"; fi
GRUB_ROOT_UUID=$(grep -Eo 'root=UUID=[0-9a-fA-F-]+' "$GRUB_CFG" | head -n 1 | sed 's/root=UUID=//')
[[ "$GRUB_HAS_LINUX_LINE" == "yes" ]] || fatal "grub.cfg missing linux /boot/vmlinuz line"
[[ "$GRUB_HAS_INITRD_LINE" == "yes" ]] || fatal "grub.cfg missing initrd /boot/initrd.img line"
[[ -n "$GRUB_ROOT_UUID" ]] || fatal "grub.cfg missing root=UUID entry"

# Cross-check root UUID in fstab vs grub
FSTAB_ROOT_UUID=$(grep -E '^[[:space:]]*UUID=' "$VERIFY_MNT/etc/fstab" | awk '$2=="/"{print $1}' | head -n 1 | sed 's/UUID=//')
[[ -n "$FSTAB_ROOT_UUID" ]] || fatal "Cannot extract root UUID from /etc/fstab"
GRUB_ROOT_UUID_MATCHES_FSTAB="no"
if [[ "$GRUB_ROOT_UUID" == "$FSTAB_ROOT_UUID" ]]; then GRUB_ROOT_UUID_MATCHES_FSTAB="yes"; else fatal "root UUID mismatch: grub=$GRUB_ROOT_UUID fstab=$FSTAB_ROOT_UUID"; fi

# Verify systemd-networkd/resolved/ssh enabled via wants symlinks
WARNINGS=()
for svc in systemd-networkd.service systemd-resolved.service ssh.service; do
    if [[ ! -L "$VERIFY_MNT/etc/systemd/system/multi-user.target.wants/$svc" && ! -L "$VERIFY_MNT/etc/systemd/system/default.target.wants/$svc" ]]; then
        log_warn "[!] $svc not enabled via wants symlink; please verify."
        WARNINGS+=("$svc not enabled via wants symlink")
    fi
done

umount "$VERIFY_MNT/boot/efi"
umount "$VERIFY_MNT"
losetup -d "$VERIFY_LOOP"
VERIFY_LOOP=""

log_info "[*] Updating VMX..."
update_vmx "$VMX_PATH"
write_report
{
    echo "VERIFICATION=passed"
    echo "GRUB_CFG=present"
    echo "EFI_BOOTLOADER=present"
    echo "FSTAB_UUID=yes"
    echo "HOSTNAME_MATCH=yes"
    echo "KERNEL_VMLINUZ=$KERNEL_VMLINUZ"
    echo "KERNEL_VERSION=$KERNEL_VERSION"
    echo "INITRD=$INITRD_IMG"
    echo "GRUB_HAS_LINUX_LINE=$GRUB_HAS_LINUX_LINE"
    echo "GRUB_HAS_INITRD_LINE=$GRUB_HAS_INITRD_LINE"
    echo "GRUB_ROOT_UUID=$GRUB_ROOT_UUID"
    echo "FSTAB_ROOT_UUID=$FSTAB_ROOT_UUID"
    echo "GRUB_ROOT_UUID_MATCHES_FSTAB=$GRUB_ROOT_UUID_MATCHES_FSTAB"
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo "WARNINGS=${WARNINGS[*]}"
    fi
} >> "$REPORT_FILE"

log_info "[+] Build complete."
log_info "VMDK: $VMDK_PATH"
log_info "Load it with CybrexTech_Dev_Preview.vmx (EFI firmware)."
