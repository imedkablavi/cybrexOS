#!/bin/bash
# build_vm.sh: CybrexOS amd64 UEFI image builder for VM qualification/release.
set -Eeuo pipefail
IFS=$'\n\t'
[[ "${DEBUG:-0}" == "1" ]] && set -x

log_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log_info() { printf '[%s] [INFO] %s\n' "$(log_ts)" "$*"; }
log_warn() { printf '[%s] [WARN] %s\n' "$(log_ts)" "$*" >&2; }
log_err()  { printf '[%s] [ERR ] %s\n' "$(log_ts)" "$*" >&2; }
fatal()    { log_err "$*"; exit 1; }

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
PACKAGE_MANIFEST="$ARTIFACTS_DIR/packages.tsv"
SBOM_PATH="$ARTIFACTS_DIR/cybrexOS.spdx"
REPRO_REPORT="$ARTIFACTS_DIR/REPRODUCIBILITY.md"

DEBIAN_SUITE="${DEBIAN_SUITE:-bookworm}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-http://security.debian.org/debian-security}"
DISK_SIZE="${DISK_SIZE:-20G}"
HOSTNAME="${HOSTNAME:-cybrex-dev}"
USERNAME="${USERNAME:-cybrex}"
VM_PASSWORD="${VM_PASSWORD:-cybrex}"
BUILD_CHANNEL="${BUILD_CHANNEL:-alpha}"
CI_SMOKE="${CYBREX_CI_SMOKE:-0}"
SKIP_VMDK="${SKIP_VMDK:-0}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}"
BUILD_SOURCE_SHA="${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)}"

LOOP_DEV=""
VERIFY_LOOP=""

case "$BUILD_CHANNEL" in
    alpha|beta|stable) ;;
    *) fatal "BUILD_CHANNEL must be alpha, beta, or stable" ;;
esac

require_root() { [[ $EUID -eq 0 ]] || fatal "Run as root (sudo)."; }

safe_umount_tree() {
    local root="$1" mp
    [[ -d "$root" ]] || return 0
    while IFS= read -r mp; do
        [[ -n "$mp" ]] && umount "$mp" 2>/dev/null || true
    done < <(findmnt -Rno TARGET "$root" 2>/dev/null | sort -r)
}

cleanup() {
    set +e
    safe_umount_tree "$VERIFY_MNT"
    safe_umount_tree "$MNT_DIR"

    for loop in "$VERIFY_LOOP" "$LOOP_DEV"; do
        [[ -n "$loop" ]] && losetup -d "$loop" 2>/dev/null || true
    done

    if [[ -f "$IMAGE_RAW" ]]; then
        while IFS= read -r loop; do
            [[ -n "$loop" ]] && losetup -d "$loop" 2>/dev/null || true
        done < <(losetup -j "$IMAGE_RAW" 2>/dev/null | cut -d: -f1)
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

require_root
[[ "$(uname -m)" == "x86_64" ]] || fatal "This builder currently qualifies amd64/x86_64 only."

REQUIRED_BINS=(
    debootstrap parted losetup mkfs.vfat mkfs.ext4 rsync mount umount findmnt
    blkid chroot find grep awk sed sort sha256sum install truncate
)
if [[ "$SKIP_VMDK" != "1" ]]; then
    REQUIRED_BINS+=(qemu-img)
fi
for bin in "${REQUIRED_BINS[@]}"; do
    command -v "$bin" >/dev/null 2>&1 || fatal "Missing dependency: $bin"
done

normalize_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    sed -i 's/\r$//' "$file"
}

normalize_overlay() {
    local target="$1" file
    normalize_file "$target/etc/default/grub"
    normalize_file "$target/etc/fstab"
    normalize_file "$target/etc/hostname"
    normalize_file "$target/etc/nftables.conf"
    if [[ -d "$target/etc/systemd" ]]; then
        while IFS= read -r file; do normalize_file "$file"; done < <(
            find "$target/etc/systemd" -type f \( -name '*.service' -o -name '*.timer' -o -name '*.network' \) -print
        )
    fi
    find "$target/usr/local/bin" -type f -exec chmod 0755 {} + 2>/dev/null || true
    find "$target/etc/systemd/system" -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' \) -exec chmod 0644 {} + 2>/dev/null || true
}

ensure_networkd_config() {
    local target="$1" netdir="$1/etc/systemd/network"
    mkdir -p "$netdir"
    if ! compgen -G "$netdir/*.network" >/dev/null; then
        cat >"$netdir/10-wired-dhcp.network" <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=ipv4
EOF
    fi
}

install_policy_rc_d() {
    local target="$1"
    install -d -m 0755 "$target/usr/sbin"
    cat >"$target/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
    chmod 0755 "$target/usr/sbin/policy-rc.d"
}

bind_chroot_filesystems() {
    mount --bind /dev "$MNT_DIR/dev"
    mount -t proc proc "$MNT_DIR/proc"
    mount -t sysfs sysfs "$MNT_DIR/sys"
}

enable_required() {
    local target="$1" service="$2"
    if [[ ! -f "$target/lib/systemd/system/$service" && ! -f "$target/usr/lib/systemd/system/$service" && ! -f "$target/etc/systemd/system/$service" ]]; then
        fatal "Required service missing from image: $service"
    fi
    chroot "$target" systemctl enable "$service" >/dev/null
}

enable_optional() {
    local target="$1" service="$2"
    if [[ -f "$target/lib/systemd/system/$service" || -f "$target/usr/lib/systemd/system/$service" || -f "$target/etc/systemd/system/$service" ]]; then
        chroot "$target" systemctl enable "$service" >/dev/null || log_warn "Could not enable optional service $service"
    fi
}

install_ci_smoke_hook() {
    local target="$1"
    [[ "$CI_SMOKE" == "1" ]] || return 0
    [[ -f "$ROOT_DIR/ci/guest-smoke.sh" ]] || fatal "Missing ci/guest-smoke.sh"
    [[ -f "$ROOT_DIR/ci/cybrex-ci-smoke.service" ]] || fatal "Missing ci/cybrex-ci-smoke.service"

    install -D -m 0755 "$ROOT_DIR/ci/guest-smoke.sh" "$target/usr/local/libexec/cybrex-ci-smoke"
    install -D -m 0644 "$ROOT_DIR/ci/cybrex-ci-smoke.service" "$target/etc/systemd/system/cybrex-ci-smoke.service"

    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$target/etc/default/grub"; then
        sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=""/' "$target/etc/default/grub"
    else
        echo 'GRUB_CMDLINE_LINUX_DEFAULT=""' >>"$target/etc/default/grub"
    fi
    if grep -q '^GRUB_CMDLINE_LINUX=' "$target/etc/default/grub"; then
        sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="console=ttyS0,115200n8 systemd.log_target=console"/' "$target/etc/default/grub"
    else
        echo 'GRUB_CMDLINE_LINUX="console=ttyS0,115200n8 systemd.log_target=console"' >>"$target/etc/default/grub"
    fi
    enable_required "$target" cybrex-ci-smoke.service
}

write_package_manifest_and_sbom() {
    local created namespace name version arch spdx_id index=0
    chroot "$MNT_DIR" dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' | LC_ALL=C sort >"$PACKAGE_MANIFEST"

    if [[ -n "$SOURCE_DATE_EPOCH" ]]; then
        created="$(date -u -d "@$SOURCE_DATE_EPOCH" +'%Y-%m-%dT%H:%M:%SZ')"
    else
        created="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    fi
    namespace="https://github.com/imedkablavi/cybrexOS/sbom/${BUILD_SOURCE_SHA//[^A-Za-z0-9._-]/_}/${SOURCE_DATE_EPOCH:-unfixed}"

    {
        echo 'SPDXVersion: SPDX-2.3'
        echo 'DataLicense: CC0-1.0'
        echo 'SPDXID: SPDXRef-DOCUMENT'
        echo 'DocumentName: cybrexOS-rootfs'
        echo "DocumentNamespace: $namespace"
        echo 'Creator: Tool: cybrexOS-build_vm.sh'
        echo "Created: $created"
        echo

        while IFS=$'\t' read -r name version arch; do
            [[ -n "$name" ]] || continue
            index=$((index + 1))
            spdx_id="SPDXRef-Package-$(printf '%s' "$name-$arch-$index" | sed 's/[^A-Za-z0-9.-]/-/g')"
            echo "PackageName: $name"
            echo "SPDXID: $spdx_id"
            echo "PackageVersion: $version"
            echo "PackageDownloadLocation: NOASSERTION"
            echo 'FilesAnalyzed: false'
            echo 'PackageLicenseConcluded: NOASSERTION'
            echo 'PackageLicenseDeclared: NOASSERTION'
            echo 'PackageCopyrightText: NOASSERTION'
            echo "PackageComment: Debian architecture: $arch"
            echo "Relationship: SPDXRef-DOCUMENT DESCRIBES $spdx_id"
            echo
        done <"$PACKAGE_MANIFEST"
    } >"$SBOM_PATH"
}

write_reproducibility_report() {
    cat >"$REPRO_REPORT" <<EOF
# CybrexOS Reproducibility Report

Status: **NOT BIT-REPRODUCIBLE / NOT YET QUALIFIED**

This build records its inputs and emits deterministic package ordering, but byte-for-byte
reproducibility is not claimed.

## Recorded inputs

- Source commit: \`$BUILD_SOURCE_SHA\`
- Release channel: \`$BUILD_CHANNEL\`
- Debian suite: \`$DEBIAN_SUITE\`
- Debian mirror: \`$DEBIAN_MIRROR\`
- Security mirror: \`$SECURITY_MIRROR\`
- Architecture: \`amd64\`
- Disk size: \`$DISK_SIZE\`
- SOURCE_DATE_EPOCH: \`${SOURCE_DATE_EPOCH:-unset}\`

## Remaining nondeterminism

- Debian repositories are not pinned to a snapshot timestamp.
- Filesystem UUIDs and filesystem metadata are generated during each build.
- Package, initramfs and GRUB tooling can embed timestamps or host-dependent metadata.
- VMDK conversion can contain format metadata that is not guaranteed reproducible.

A future reproducible-build qualification must build the same source twice in isolated
runners from pinned package snapshots and compare the release artifact hashes. Until that
passes, identical SHA256 values across independent builds are not promised.
EOF
}

write_vmx() {
    cat >"$VMX_PATH" <<'EOF'
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "19"
displayName = "CybrexOS Alpha"
guestOS = "debian12-64"
memsize = "4096"
numvcpus = "2"
firmware = "efi"
scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "artifacts/CybrexTech_Dev_Preview.vmdk"
ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "e1000e"
usb.present = "TRUE"
usb_xhci.present = "TRUE"
EOF
}

pre_clean() {
    cleanup
    rm -rf "$BUILD_DIR"
    rm -rf "$ARTIFACTS_DIR"
    mkdir -p "$BUILD_DIR" "$MNT_DIR" "$VERIFY_MNT" "$LOG_DIR" "$ARTIFACTS_DIR"
}

pre_clean
export DEBIAN_FRONTEND=noninteractive

log_info "Creating raw disk ($DISK_SIZE)"
truncate -s "$DISK_SIZE" "$IMAGE_RAW"
parted -s "$IMAGE_RAW" mklabel gpt
parted -s "$IMAGE_RAW" mkpart ESP fat32 1MiB 513MiB
parted -s "$IMAGE_RAW" set 1 esp on
parted -s "$IMAGE_RAW" mkpart ROOT ext4 513MiB 100%

LOOP_DEV="$(losetup -P --show -f "$IMAGE_RAW")"
ESP_DEV="${LOOP_DEV}p1"
ROOT_DEV="${LOOP_DEV}p2"
[[ -b "$ESP_DEV" && -b "$ROOT_DEV" ]] || fatal "Loop partitions were not created"

mkfs.vfat -F32 -n CYBREXEFI "$ESP_DEV" >/dev/null
mkfs.ext4 -F -L cybrex-root "$ROOT_DEV" >/dev/null

mount "$ROOT_DEV" "$MNT_DIR"
mkdir -p "$MNT_DIR/boot/efi"
mount "$ESP_DEV" "$MNT_DIR/boot/efi"

log_info "Bootstrapping Debian $DEBIAN_SUITE"
debootstrap --arch=amd64 \
    --include=linux-image-amd64,systemd,systemd-sysv,debian-archive-keyring,locales,grub-efi-amd64,grub-efi-amd64-bin,openssh-server,sudo,ca-certificates,lsb-release,open-vm-tools,nftables,iproute2,systemd-resolved,logrotate,python3 \
    "$DEBIAN_SUITE" "$MNT_DIR" "$DEBIAN_MIRROR"

[[ -d "$ROOTFS_OVERLAY" ]] || fatal "Missing rootfs overlay: $ROOTFS_OVERLAY"
rsync -a "$ROOTFS_OVERLAY"/ "$MNT_DIR"/
normalize_overlay "$MNT_DIR"
ensure_networkd_config "$MNT_DIR"

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV")"
ESP_UUID="$(blkid -s UUID -o value "$ESP_DEV")"
[[ -n "$ROOT_UUID" && -n "$ESP_UUID" ]] || fatal "Could not determine filesystem UUIDs"

cat >"$MNT_DIR/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 defaults 0 1
UUID=$ESP_UUID /boot/efi vfat umask=0077 0 1
EOF
printf '%s\n' "$HOSTNAME" >"$MNT_DIR/etc/hostname"
cat >"$MNT_DIR/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_SUITE main contrib non-free non-free-firmware
deb $SECURITY_MIRROR $DEBIAN_SUITE-security main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR $DEBIAN_SUITE-updates main contrib non-free non-free-firmware
EOF

mkdir -p "$MNT_DIR/var/log/cybrex" "$MNT_DIR/var/run/cybrex"
bind_chroot_filesystems

if [[ -f /etc/resolv.conf ]]; then
    cp -L /etc/resolv.conf "$MNT_DIR/etc/resolv.conf"
else
    printf 'nameserver 1.1.1.1\n' >"$MNT_DIR/etc/resolv.conf"
fi
install_policy_rc_d "$MNT_DIR"

chroot "$MNT_DIR" bash -c "echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen && locale-gen >/dev/null"
printf 'LANG=en_US.UTF-8\n' >"$MNT_DIR/etc/default/locale"

if ! chroot "$MNT_DIR" id "$USERNAME" >/dev/null 2>&1; then
    chroot "$MNT_DIR" useradd -m -s /bin/bash -G sudo,adm,systemd-journal "$USERNAME"
fi
printf '%s:%s\n' "$USERNAME" "$VM_PASSWORD" | chroot "$MNT_DIR" chpasswd
printf '%s ALL=(ALL) ALL\n' "$USERNAME" >"$MNT_DIR/etc/sudoers.d/$USERNAME"
chmod 0440 "$MNT_DIR/etc/sudoers.d/$USERNAME"

rm -f "$MNT_DIR/etc/resolv.conf"
ln -s /run/systemd/resolve/stub-resolv.conf "$MNT_DIR/etc/resolv.conf"

enable_required "$MNT_DIR" systemd-networkd.service
enable_required "$MNT_DIR" systemd-resolved.service
enable_required "$MNT_DIR" nftables.service
enable_optional "$MNT_DIR" ssh.service
enable_optional "$MNT_DIR" cybrex-daemon.service
enable_optional "$MNT_DIR" cybrex-update.timer
# cybrex-demo.service is intentionally not enabled in the headless release image.

install_ci_smoke_hook "$MNT_DIR"

log_info "Installing GRUB EFI removable boot path"
chroot "$MNT_DIR" grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=Cybrex \
    --removable \
    --no-nvram \
    --recheck
chroot "$MNT_DIR" update-grub

write_package_manifest_and_sbom
rm -f "$MNT_DIR/usr/sbin/policy-rc.d"

safe_umount_tree "$MNT_DIR"
losetup -d "$LOOP_DEV"
LOOP_DEV=""

if [[ "$SKIP_VMDK" != "1" ]]; then
    log_info "Converting raw image to VMDK"
    qemu-img convert -f raw -O vmdk "$IMAGE_RAW" "$VMDK_PATH"
    qemu-img check -f vmdk "$VMDK_PATH" >/dev/null
    write_vmx
else
    log_info "SKIP_VMDK=1: raw image retained for QEMU qualification only"
fi

log_info "Static boot artifact verification"
VERIFY_LOOP="$(losetup -P --show -f --read-only "$IMAGE_RAW")"
VERIFY_ROOT="${VERIFY_LOOP}p2"
VERIFY_ESP="${VERIFY_LOOP}p1"
mount -o ro "$VERIFY_ROOT" "$VERIFY_MNT"
mkdir -p "$VERIFY_MNT/boot/efi"
mount -o ro "$VERIFY_ESP" "$VERIFY_MNT/boot/efi"

[[ -s "$VERIFY_MNT/boot/grub/grub.cfg" ]] || fatal "Missing /boot/grub/grub.cfg"
[[ -f "$VERIFY_MNT/boot/efi/EFI/BOOT/BOOTX64.EFI" ]] || fatal "Missing EFI/BOOT/BOOTX64.EFI"
KERNEL_VMLINUZ="$(find "$VERIFY_MNT/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' | sort | head -n1)"
INITRD_IMG="$(find "$VERIFY_MNT/boot" -maxdepth 1 -type f -name 'initrd.img-*' -printf '%f\n' | sort | head -n1)"
[[ -n "$KERNEL_VMLINUZ" ]] || fatal "No kernel image found"
[[ -n "$INITRD_IMG" ]] || fatal "No initramfs found"
KERNEL_VERSION="${KERNEL_VMLINUZ#vmlinuz-}"
[[ -d "$VERIFY_MNT/lib/modules/$KERNEL_VERSION" ]] || fatal "Missing modules for $KERNEL_VERSION"

grep -Eq '^[[:space:]]*linux[[:space:]]+/boot/vmlinuz-' "$VERIFY_MNT/boot/grub/grub.cfg" || fatal "grub.cfg has no linux entry"
grep -Eq '^[[:space:]]*initrd[[:space:]]+/boot/initrd.img-' "$VERIFY_MNT/boot/grub/grub.cfg" || fatal "grub.cfg has no initrd entry"
GRUB_ROOT_UUID="$(grep -Eo 'root=UUID=[0-9a-fA-F-]+' "$VERIFY_MNT/boot/grub/grub.cfg" | head -n1 | cut -d= -f3)"
[[ "$GRUB_ROOT_UUID" == "$ROOT_UUID" ]] || fatal "GRUB root UUID does not match root filesystem"

safe_umount_tree "$VERIFY_MNT"
losetup -d "$VERIFY_LOOP"
VERIFY_LOOP=""

{
    echo "BUILD_TIME=$(log_ts)"
    echo "SOURCE_SHA=$BUILD_SOURCE_SHA"
    echo "CHANNEL=$BUILD_CHANNEL"
    echo "DEBIAN_SUITE=$DEBIAN_SUITE"
    echo "DISK_SIZE=$DISK_SIZE"
    echo "RAW_IMAGE=$IMAGE_RAW"
    echo "VMDK=$([[ "$SKIP_VMDK" == "1" ]] && echo skipped || echo "$VMDK_PATH")"
    echo "SBOM=$SBOM_PATH"
    echo "PACKAGE_MANIFEST=$PACKAGE_MANIFEST"
    echo "EFI_BOOTLOADER=present"
    echo "KERNEL=$KERNEL_VMLINUZ"
    echo "INITRD=$INITRD_IMG"
    echo "ROOT_UUID_MATCH=yes"
    echo "CI_SMOKE_HOOK=$CI_SMOKE"
    echo "STATIC_VERIFICATION=passed"
} >"$REPORT_FILE"

write_reproducibility_report
cp "$REPORT_FILE" "$ARTIFACTS_DIR/build-report.txt"

(
    cd "$ARTIFACTS_DIR"
    files=(cybrexOS.spdx packages.tsv REPRODUCIBILITY.md build-report.txt)
    [[ -f CybrexTech_Dev_Preview.vmdk ]] && files+=(CybrexTech_Dev_Preview.vmdk)
    sha256sum "${files[@]}" >SHA256SUMS
)

log_info "Build complete"
log_info "Report: $REPORT_FILE"
log_info "SBOM: $SBOM_PATH"
log_info "Reproducibility: $REPRO_REPORT"
