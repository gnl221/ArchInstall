#!/bin/bash
#
# @file archinstall.sh
# @brief Entry point. Launches child scripts for each phase of installation.
#
set -a
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
CONFIGS_DIR="$SCRIPT_DIR/configs"
set +a

echo -ne "
┌─────────────────────────────────────────┐
│         Arch Linux Installer            │
│    KDE · BTRFS · Wayland · Ham Radio    │
└─────────────────────────────────────────┘
"

# ── Stage 0: Gather user preferences ──────────────────────────────────────────
(bash "$SCRIPTS_DIR/startup.sh") |& tee startup.log
source "$CONFIGS_DIR/setup.conf"

# ── Stage 1: Partition, format, pacstrap ──────────────────────────────────────
(bash "$SCRIPTS_DIR/0-preinstall.sh") |& tee 0-preinstall.log

# ── Stage 2: Chroot system configuration ──────────────────────────────────────
(arch-chroot /mnt bash /root/ArchScript/scripts/1-setup.sh) |& tee 1-setup.log

# ── Stage 3: User packages and AUR ────────────────────────────────────────────
(arch-chroot /mnt /usr/bin/runuser -u "$USERNAME" -- \
    bash "/home/$USERNAME/ArchScript/scripts/2-user.sh") |& tee 2-user.log

# ── Stage 4: Final configuration ──────────────────────────────────────────────
(arch-chroot /mnt bash /root/ArchScript/scripts/3-post-setup.sh) |& tee 3-post-setup.log

# ── Copy logs to new system ───────────────────────────────────────────────────
cp -v ./*.log "/mnt/home/$USERNAME/"

echo -ne "
┌─────────────────────────────────────────┐
│           Installation Complete!        │
│    Eject install media and reboot.      │
└─────────────────────────────────────────┘
"
