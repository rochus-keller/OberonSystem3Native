#!/bin/bash
# flash_sd.sh — Format an SD card for RPi 3B bare-metal Oberon boot
#
# Usage:  sudo bash flash_sd.sh
#
# Prerequisites (all in the current directory):
#   bootfiles/        — directory with RPi boot firmware:
#                        bootcode.bin, start.elf, fixup.dat
#                        (copy from a working RaspiOS SD card)
#   image.bin          — Oberon kernel image (from multibootlinker)
#   drive.img          — AosFS filesystem image (from aosfstool)
#   cmdline.txt        — boot configuration string (optional, created if missing)
#
# Creates two partitions on the target device:
#   Partition 1: FAT16 (~32 MB, boot flag) — RPi boot files + kernel
#   Partition 2: raw AosFS (type 0x4F)     — drive.img written directly
#
# The EMMCDisks driver scans the MBR for the first non-FAT partition
# and uses its LBA offset to access the AosFS filesystem.

set -e

DEVICE="${DEVICE:-/dev/sde}" #/dev/sda
FAT_SIZE_MB="${FAT_SIZE_MB:-16}"
DRIVE_IMG="${DRIVE_IMG:-../output/drive.img}"
KERNEL_IMG="${KERNEL_IMG:-../output/image.bin}"
KERNEL_ADDR="${KERNEL_ADDR:-0x10000}"
BOOT_FILES="${BOOT_FILES:-/output/bootfiles}"
CMDLINE="${CMDLINE:-cmdline.txt}"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (sudo)"
    exit 1
fi

if [ ! -b "$DEVICE" ]; then
    echo "ERROR: $DEVICE is not a block device"
    exit 1
fi

if [ ! -f "$DRIVE_IMG" ]; then
    echo "ERROR: $DRIVE_IMG not found in current directory"
    exit 1
fi

if [ ! -f "$KERNEL_IMG" ]; then
    echo "ERROR: $KERNEL_IMG not found in current directory"
    echo "  Build it first with multibootlinker, e.g.:"
    echo "  ./multibootlinker --arch arm32 --base $KERNEL_ADDR --multiboot \\"
    echo "    --enable-stack --stack-size 131072 --autofix \\"
    echo "    --hyp-to-svc --core-parking -o image.bin Kernel ..."
    exit 1
fi

# Check boot firmware files
for f in bootcode.bin start.elf fixup.dat; do
    if [ ! -f "$BOOT_FILES/$f" ]; then
        echo "ERROR: $BOOT_FILES/$f not found"
        echo "  Copy bootcode.bin, start.elf, fixup.dat from a working"
        echo "  RaspiOS SD card into the $BOOT_FILES/ directory."
        exit 1
    fi
done

if [ ! -f "$CMDLINE" ]; then
    echo "NOTE: $CMDLINE not found, creating default..."
    printf ';;BootVol=SYS AosFS SD0#0;AosFS=OFSDiskVolumes.New OFSAosFiles.NewFS;MT=;MP=;MB=-3;DMASize=14800H;TraceModules=1;Display=;DDriver=DisplayLinear;DMode=*;TracePort=1;\n' > "$CMDLINE"
    echo "  Created $CMDLINE"
fi

DEVSIZE=$(blockdev --getsize64 "$DEVICE" 2>/dev/null || echo "0")
DRVSIZE=$(stat -c%s "$DRIVE_IMG" 2>/dev/null || echo "0")
echo ""
echo "  Target device:  $DEVICE ($((DEVSIZE / 1048576)) MB)"
echo "  FAT partition:  ${FAT_SIZE_MB} MB (FAT16, boot flag)"
echo "  Kernel image:   $KERNEL_IMG (loaded at $KERNEL_ADDR)"
echo "  AosFS image:    $DRIVE_IMG ($((DRVSIZE / 1024)) KB)"
echo "  Boot firmware:  $BOOT_FILES/"
echo "  Config string:  $CMDLINE"
echo ""
echo "  WARNING: ALL DATA ON $DEVICE WILL BE DESTROYED!"
echo ""
read -p "  Continue? [y/N] " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "  Unmounting $DEVICE partitions"
for part in "${DEVICE}"*; do
    if mountpoint -q "$part" 2>/dev/null || mount | grep -q "^$part "; then
        umount "$part" 2>/dev/null && echo "  Unmounted $part" || true
    fi
done

echo ""
echo "  Partitioning $DEVICE"

# Wipe first MB to remove any stale partition/filesystem signatures
dd if=/dev/zero of="$DEVICE" bs=1M count=1 status=none

FAT_SECTORS=$((FAT_SIZE_MB * 2048))  # 2048 sectors per MB (512-byte sectors)
P1_START=2048

# Use sfdisk: partition 1 = FAT LBA (0x0C) with boot flag,
#             partition 2 = QNX (0x4F) = non-FAT so EMMCDisks finds it
sfdisk "$DEVICE" << EOF
label: dos
unit: sectors

${DEVICE}1 : start=$P1_START, size=$FAT_SECTORS, type=e, bootable
${DEVICE}2 : start=$((P1_START + FAT_SECTORS)), type=4f
EOF

echo "  Partitioned: P1=FAT (${FAT_SIZE_MB}MB, boot), P2=AosFS (rest)"

# Wait for kernel to re-read partition table
sleep 1
partprobe "$DEVICE" 2>/dev/null || true
sleep 1

# Determine partition device names
if [ -b "${DEVICE}1" ]; then
    P1="${DEVICE}1"
    P2="${DEVICE}2"
elif [ -b "${DEVICE}p1" ]; then
    P1="${DEVICE}p1"
    P2="${DEVICE}p2"
else
    echo "ERROR: cannot find partition devices for $DEVICE"
    echo "  Expected ${DEVICE}1 or ${DEVICE}p1"
    exit 1
fi

echo ""
echo "  Formatting $P1 as FAT16"
mkfs.vfat -F 16 -n "RPIBOOT" "$P1"
echo "  Formatted $P1"

echo ""
echo "  Creating config.txt"
CONFIGTXT=$(mktemp)
cat > "$CONFIGTXT" << CFGEOF
# RPi 3B bare-metal Oberon boot configuration
kernel=kernel7.img
kernel_address=$KERNEL_ADDR
arm_64bit=0
enable_jtag_gpio=1
device_tree=
gpu_mem=32
enable_uart=1
core_freq=250
disable_overscan=1
CFGEOF
echo "  Created config.txt"
# gpu_mem=32 16 doesn't work!

echo ""
echo "  Copying boot files to FAT partition"
MOUNTPOINT=$(mktemp -d)
mount "$P1" "$MOUNTPOINT"

cp "$BOOT_FILES/bootcode.bin" "$MOUNTPOINT/"
cp "$BOOT_FILES/start.elf"    "$MOUNTPOINT/"
cp "$BOOT_FILES/fixup.dat"    "$MOUNTPOINT/"
cp "$CONFIGTXT"               "$MOUNTPOINT/config.txt"
cp "$KERNEL_IMG"              "$MOUNTPOINT/kernel7.img"
cp "$CMDLINE"                 "$MOUNTPOINT/cmdline.txt"

echo "  Copied:"
ls -la "$MOUNTPOINT/"
echo ""

sync
umount "$MOUNTPOINT"
rmdir "$MOUNTPOINT"
rm -f "$CONFIGTXT"
echo "  FAT partition ready"

echo ""
echo "  Writing $DRIVE_IMG to $P2"
dd if="$DRIVE_IMG" of="$P2" bs=512 conv=notrunc status=progress
sync
echo "  Written $DRVSIZE bytes to $P2"

echo ""

# Show partition 2 LBA (what EMMCDisks will see)
P2_LBA=$((P1_START + FAT_SECTORS))
echo "  Partition 2 starts at LBA $P2_LBA (sector)"
echo "  EMMCDisks should print: AOS partition at LBA $P2_LBA"
echo ""
echo "  Partition layout:"
sfdisk -l "$DEVICE" 2>/dev/null | tail -8
echo ""

echo "  SD card ready"
echo ""

