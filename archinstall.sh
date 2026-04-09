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

# Verify user was actually created before attempting Stage 3.
# If useradd failed in Stage 1, runuser would silently fail and Stage 3
# would install nothing, leaving a broken system.
if ! arch-chroot /mnt id "$USERNAME" &>/dev/null; then
    echo ""
    echo "══════════════════════════════════════════════"
    echo " FATAL: User '$USERNAME' was not created."
    echo " Stage 1 failed at useradd. Check 1-setup.log"
    echo " for the error. Aborting — system not usable."
    echo "══════════════════════════════════════════════"
    cp -v ./*.log /mnt/root/
    exit 1
fi

# ── Stage 3: User packages and AUR ────────────────────────────────────────────
(arch-chroot /mnt /usr/bin/runuser -u "$USERNAME" -- \
    bash "/home/$USERNAME/ArchScript/scripts/2-user.sh") |& tee 2-user.log

# ── Stage 4: Final configuration ──────────────────────────────────────────────
(arch-chroot /mnt bash /root/ArchScript/scripts/3-post-setup.sh) |& tee 3-post-setup.log

# ── Copy logs to new system ───────────────────────────────────────────────────
# Also copy to /mnt/root as fallback in case the home directory is missing
cp -v ./*.log "/mnt/home/$USERNAME/" 2>/dev/null || true
cp -v ./*.log /mnt/root/

echo -ne "
┌─────────────────────────────────────────┐
│           Installation Complete!        │
│    Eject install media and reboot.      │
└─────────────────────────────────────────┘
"
