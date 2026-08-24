#!/bin/bash
# install_cybrex.sh: bare-metal installer preflight.
# DESTRUCTIVE INSTALLATION IS INTENTIONALLY DISABLED until the installer has a
# qualified VM + bare-metal test matrix. This script currently validates a target
# and prints the intended plan only.
set -Eeuo pipefail

DISK=""
CONFIRM_WIPE=""
EXECUTE=0
ACK_UNQUALIFIED=0

fail() { echo "[installer] ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
CybrexOS bare-metal installer (UNQUALIFIED / fail-closed)

Usage:
  sudo build_scripts/install_cybrex.sh --disk /dev/DEVICE [--dry-run]
  sudo build_scripts/install_cybrex.sh --disk /dev/DEVICE --execute \
       --ack-unqualified --confirm-wipe /dev/DEVICE

Options:
  --disk DEVICE          Explicit whole-disk target. There is no default disk.
  --dry-run              Validate and print the plan. This is the default behavior.
  --execute              Request the destructive phase.
  --ack-unqualified      Acknowledge that bare-metal install is not qualified.
  --confirm-wipe DEVICE  Must exactly match the canonical --disk path.

Safety state:
  Even with --execute and all acknowledgements, destructive installation remains
  disabled in this release-engineering pass. This prevents publishing the previous
  hardcoded-disk installer as though it were qualified.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk)
            [[ $# -ge 2 ]] || fail "--disk requires a value"
            DISK="$2"; shift 2 ;;
        --confirm-wipe)
            [[ $# -ge 2 ]] || fail "--confirm-wipe requires a value"
            CONFIRM_WIPE="$2"; shift 2 ;;
        --execute) EXECUTE=1; shift ;;
        --ack-unqualified) ACK_UNQUALIFIED=1; shift ;;
        --dry-run) EXECUTE=0; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
done

[[ -n "$DISK" ]] || { usage >&2; fail "--disk is required"; }
command -v readlink >/dev/null 2>&1 || fail "readlink is required"
command -v lsblk >/dev/null 2>&1 || fail "lsblk is required"
command -v findmnt >/dev/null 2>&1 || fail "findmnt is required"

DISK="$(readlink -f "$DISK")"
[[ -b "$DISK" ]] || fail "not a block device: $DISK"
[[ "$(lsblk -dnro TYPE "$DISK" 2>/dev/null)" == "disk" ]] || fail "target must be a whole disk"

# Refuse the disk that backs the currently running root filesystem.
ROOT_SOURCE="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
ROOT_DISK=""
if [[ -n "$ROOT_SOURCE" && -b "$ROOT_SOURCE" ]]; then
    ROOT_PKNAME="$(lsblk -nro PKNAME "$ROOT_SOURCE" 2>/dev/null | head -n1 || true)"
    if [[ -n "$ROOT_PKNAME" ]]; then
        ROOT_DISK="/dev/$ROOT_PKNAME"
    elif [[ "$(lsblk -dnro TYPE "$ROOT_SOURCE" 2>/dev/null || true)" == "disk" ]]; then
        ROOT_DISK="$(readlink -f "$ROOT_SOURCE")"
    fi
fi
[[ -z "$ROOT_DISK" || "$DISK" != "$ROOT_DISK" ]] || fail "refusing to target the running root disk: $DISK"

# Refuse any target with mounted descendants. Users must explicitly unmount media
# before installation; the installer does not auto-unmount unrelated filesystems.
MOUNTED="$(lsblk -nrpo NAME,MOUNTPOINT "$DISK" | awk 'NF >= 2 && $2 != "" {print $1 " -> " $2}')"
[[ -z "$MOUNTED" ]] || fail "target has mounted filesystems:\n$MOUNTED"

cat <<EOF
CybrexOS installer preflight: PASS
Target disk: $DISK
Qualification: UNQUALIFIED
Planned layout (not executed):
  - GPT
  - 512 MiB EFI System Partition
  - LUKS2 root container
  - Btrfs root with subvolumes
  - Debian bookworm + GRUB EFI

No disk changes have been made.
EOF

if [[ "$EXECUTE" != "1" ]]; then
    exit 0
fi

[[ $EUID -eq 0 ]] || fail "--execute requires root"
[[ "$ACK_UNQUALIFIED" == "1" ]] || fail "--execute requires --ack-unqualified"
[[ -n "$CONFIRM_WIPE" ]] || fail "--execute requires --confirm-wipe $DISK"
CONFIRM_WIPE="$(readlink -f "$CONFIRM_WIPE")"
[[ "$CONFIRM_WIPE" == "$DISK" ]] || fail "--confirm-wipe must exactly match $DISK"

fail "destructive installer phase is intentionally disabled pending bare-metal qualification; see docs/BARE_METAL.md"
