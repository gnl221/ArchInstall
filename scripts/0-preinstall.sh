#!/usr/bin/env bash
#
# @file 0-preinstall.sh
# @brief Partitions disk, creates BTRFS subvolumes, runs pacstrap.
#
echo -ne "
────────────────────────────────────────────
  Stage 0: Disk Setup and Base Install
────────────────────────────────────────────
"
source "$CONFIGS_DIR/setup.conf"

# ─── Mirrors ──────────────────────────────────────────────────────────────────
echo "==> Updating keyring and mirrors..."
timedatectl set-ntp true
pacman -Sy --noconfirm archlinux-keyring
pacman -S --noconfirm --needed reflector rsync
reflector --country 'United States' --age 12 --protocol https \
    --sort rate --save /etc/pacman.d/mirrorlist
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

# ─── Partition device names ───────────────────────────────────────────────────
# Partition layout:
#   Part 1 — 1M    BIOS boot  (ef02) — required even on UEFI systems for safety
#   Part 2 — 512M  EFI System (ef00) — FAT32, /boot/efi
#   Part 3 — rest  Linux data (8300) — BTRFS, /
if [[ "$DISK" =~ nvme|mmcblk ]]; then
    PART1="${DISK}p1"
    PART2="${DISK}p2"
    PART3="${DISK}p3"
else
    PART1="${DISK}1"
    PART2="${DISK}2"
    PART3="${DISK}3"
fi

# ─── Partition ────────────────────────────────────────────────────────────────
echo "==> Partitioning $DISK..."
umount -A --recursive /mnt 2>/dev/null || true
sgdisk -Z "$DISK"
sgdisk -a 2048 -o "$DISK"
sgdisk -n 1::+1M   --typecode=1:ef02 --change-name=1:'BIOSBOOT' "$DISK"
sgdisk -n 2::+512M --typecode=2:ef00 --change-name=2:'EFIBOOT'  "$DISK"
sgdisk -n 3::-0    --typecode=3:8300 --change-name=3:'ROOT'     "$DISK"
# Set legacy BIOS boot flag on partition 1 for BIOS systems
if [[ ! -d /sys/firmware/efi ]]; then
    sgdisk -A 1:set:2 "$DISK"
fi
partprobe "$DISK"
sleep 2

# ─── Format ───────────────────────────────────────────────────────────────────
echo "==> Formatting partitions..."
mkfs.vfat -F32 -n "EFIBOOT" "$PART2"
mkfs.btrfs -L ROOT "$PART3" -f

# ─── BTRFS subvolumes ─────────────────────────────────────────────────────────
# Subvolume layout (all top-level for clean rollback):
#   @               → /                      (root, snapshotted)
#   @home           → /home                  (user data, excluded from root snapshots)
#   @snapshots      → /.snapshots            (snapper storage)
#   @var_log        → /var/log               (logs persist across rollbacks)
#   @var_cache_pacman → /var/cache/pacman/pkg (package cache excluded from snapshots)
echo "==> Creating BTRFS subvolumes..."
mount -t btrfs "$PART3" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_cache_pacman
umount /mnt

# ─── Mount subvolumes ─────────────────────────────────────────────────────────
echo "==> Mounting BTRFS subvolumes..."
mount -o "${MOUNT_OPTIONS},subvol=@"                   "$PART3" /mnt
mkdir -p /mnt/{home,.snapshots,var/log,var/cache/pacman/pkg,boot/efi}
mount -o "${MOUNT_OPTIONS},subvol=@home"               "$PART3" /mnt/home
mount -o "${MOUNT_OPTIONS},subvol=@snapshots"          "$PART3" /mnt/.snapshots
mount -o "${MOUNT_OPTIONS},subvol=@var_log"            "$PART3" /mnt/var/log
mount -o "${MOUNT_OPTIONS},subvol=@var_cache_pacman"   "$PART3" /mnt/var/cache/pacman/pkg
mount -t vfat "$PART2" /mnt/boot/efi

# Verify mounts
if ! grep -qs '/mnt' /proc/mounts; then
    echo "ERROR: /mnt is not mounted. Aborting."
    exit 1
fi

# ─── Pacstrap ─────────────────────────────────────────────────────────────────
echo "==> Running pacstrap..."
pacman -S --noconfirm --needed gptfdisk btrfs-progs
pacstrap -K /mnt \
    base base-devel linux linux-firmware linux-headers \
    btrfs-progs \
    git \
    vim nano sudo \
    archlinux-keyring wget \
    --noconfirm --needed

# ─── Fstab ────────────────────────────────────────────────────────────────────
echo "==> Generating /etc/fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
# Remove subvolid entries — these conflict with snapper snapshot rollbacks.
# Snapper relies on subvol= names, not subvolid numbers.
sed -i 's/subvolid=[0-9]*,//g' /mnt/etc/fstab
echo "Generated fstab:"
cat /mnt/etc/fstab

# ─── BIOS bootloader (pre-chroot) ─────────────────────────────────────────────
if [[ ! -d /sys/firmware/efi ]]; then
    pacstrap -K /mnt grub --noconfirm --needed
    grub-install --boot-directory=/mnt/boot "$DISK"
fi

# ─── Low memory: create swapfile ──────────────────────────────────────────────
# The swapfile MUST live in its own dedicated BTRFS subvolume, NOT inside @.
# BTRFS has a kernel-level hard restriction: you cannot snapshot a subvolume
# that contains an active swapfile. If the swapfile is inside @, snapper can
# never take a snapshot of / while the system is running.
TOTAL_MEM=$(grep MemTotal /proc/meminfo | grep -o '[0-9]*')
if [[ $TOTAL_MEM -lt 8000000 ]]; then
    echo "==> Low memory detected (<8G). Creating 2G swapfile on dedicated subvolume..."

    # Create a dedicated top-level subvolume for swap — excluded from snapshots
    mount -t btrfs -o subvolid=5 "$ROOT_PART" /mnt/mnt
    btrfs subvolume create /mnt/mnt/@swap
    umount /mnt/mnt

    # Mount the swap subvolume
    mkdir -p /mnt/swap
    mount -o "${MOUNT_OPTIONS},subvol=@swap" "$ROOT_PART" /mnt/swap

    # Create the swapfile — chattr +C disables COW (required for BTRFS swapfiles)
    chattr +C /mnt/swap
    dd if=/dev/zero of=/mnt/swap/swapfile bs=1M count=2048 status=progress
    chmod 600 /mnt/swap/swapfile
    chown root /mnt/swap/swapfile
    mkswap /mnt/swap/swapfile
    swapon /mnt/swap/swapfile

    # Add fstab entries for both the subvolume mount and the swapfile
    echo "" >> /mnt/etc/fstab
    echo "# Swap subvolume (own subvol so BTRFS can snapshot @ without conflict)" >> /mnt/etc/fstab
    echo "UUID=$(blkid -s UUID -o value "$ROOT_PART")  /swap  btrfs  ${MOUNT_OPTIONS},subvol=@swap  0 0" >> /mnt/etc/fstab
    echo "/swap/swapfile  none  swap  sw  0  0" >> /mnt/etc/fstab
fi

# ─── Copy scripts into new system ─────────────────────────────────────────────
echo "==> Copying install scripts into new system..."
cp -R "$SCRIPT_DIR" /mnt/root/ArchScript
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

echo -e "\n── Stage 0 complete. ──────────────────────────\n"
