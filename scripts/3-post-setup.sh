#!/usr/bin/env bash
#
# @file 3-post-setup.sh
# @brief Runs as root in chroot. Installs GRUB+theme, Plymouth, enables services,
#        sets up snapper for automatic snapshots, and finalizes sudo config.
#
echo -ne "
────────────────────────────────────────────
  Stage 3: Final Configuration
────────────────────────────────────────────
"
source "$HOME/ArchScript/configs/setup.conf"

# ─── GRUB + grub-btrfs ────────────────────────────────────────────────────────
echo "==> Installing GRUB, grub-btrfs, and inotify-tools..."
pacman -S --noconfirm --needed grub efibootmgr os-prober grub-btrfs inotify-tools

# grub-btrfs provides the grub-btrfs-overlayfs mkinitcpio hook.
# Now that the package is installed, add the hook and rebuild the initramfs.
# This hook lets you boot into a read-only snapper snapshot with an overlayfs
# write layer, so services requiring a writable /var (like SDDM) still start.
echo "==> Adding grub-btrfs-overlayfs hook to mkinitcpio and rebuilding..."
sed -i '/^HOOKS=/ s/fsck)/fsck grub-btrfs-overlayfs)/' /etc/mkinitcpio.conf
mkinitcpio -P

if [[ -d /sys/firmware/efi ]]; then
    grub-install --target=x86_64-efi \
                 --efi-directory=/boot/efi \
                 --bootloader-id=ARCH \
                 --recheck
fi

# ─── GRUB: kernel parameters ──────────────────────────────────────────────────
# rootflags=subvol=@ — ensures GRUB knows the BTRFS root subvolume name
# quiet splash      — clean boot with Plymouth splash
sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT=".*"|GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 audit=0 rootflags=subvol=@"|' \
    /etc/default/grub
# Enable os-prober for dual-boot detection
sed -i 's/#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' \
    /etc/default/grub

# ─── GRUB: hex-arch theme ─────────────────────────────────────────────────────
# Theme files expected at: configs/boot/grub/themes/hex-arch/
# Place all theme assets (background_arch.png, *.png, theme.txt, fonts/)
# in that directory within this repo before running the installer.
echo "==> Installing hex-arch GRUB theme..."
THEME_DIR="/boot/grub/themes"
THEME_NAME="hex-arch"
THEME_SRC="$HOME/ArchScript/configs/boot/grub/themes/$THEME_NAME"

if [[ -d "$THEME_SRC" ]]; then
    mkdir -p "${THEME_DIR}/${THEME_NAME}"
    cp -a "$THEME_SRC/." "${THEME_DIR}/${THEME_NAME}/"
    # Set theme in GRUB config
    grep -q "GRUB_THEME=" /etc/default/grub && \
        sed -i '/GRUB_THEME=/d' /etc/default/grub
    echo "GRUB_THEME=\"${THEME_DIR}/${THEME_NAME}/theme.txt\"" >> /etc/default/grub
    echo "hex-arch theme installed."
else
    echo "WARNING: Theme source not found at $THEME_SRC"
    echo "         Place hex-arch theme files in configs/boot/grub/themes/hex-arch/"
    echo "         GRUB will use the default theme."
fi

# ─── Plymouth ─────────────────────────────────────────────────────────────────
# Install Plymouth before grub-mkconfig so the splash hook is in the initramfs
# that GRUB points to, and the 'splash' kernel param is already set above.
echo "==> Installing Plymouth boot splash..."
pacman -S --noconfirm --needed plymouth

# Insert 'plymouth' after 'udev' in the HOOKS array.
# It must come before 'encrypt', 'block', and 'filesystems'.
sed -i 's/HOOKS=(base udev/HOOKS=(base udev plymouth/' /etc/mkinitcpio.conf

PLYMOUTH_THEMES_DIR="$HOME/ArchScript/configs/usr/share/plymouth/themes"
PLYMOUTH_THEME="arch-glow"

if [[ -d "${PLYMOUTH_THEMES_DIR}/${PLYMOUTH_THEME}" ]]; then
    mkdir -p /usr/share/plymouth/themes
    cp -rf "${PLYMOUTH_THEMES_DIR}/${PLYMOUTH_THEME}" /usr/share/plymouth/themes/
    # -R rebuilds the initramfs with the new theme — no separate mkinitcpio -P needed
    plymouth-set-default-theme -R "$PLYMOUTH_THEME"
    echo "Plymouth arch-glow theme installed."
else
    echo "WARNING: Plymouth theme not found at ${PLYMOUTH_THEMES_DIR}/${PLYMOUTH_THEME}"
    echo "         Place arch-glow theme in configs/usr/share/plymouth/themes/arch-glow/"
    echo "         Plymouth will use the default (text) theme until you add the files."
    mkinitcpio -P
fi

# ─── GRUB: generate config ────────────────────────────────────────────────────
# Run after Plymouth so initramfs already contains the plymouth hook.
grub-mkconfig -o /boot/grub/grub.cfg

# ─── SDDM (login manager) ─────────────────────────────────────────────────────
echo "==> Configuring SDDM..."
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/kde_settings.conf <<'EOF'
[Autologin]
Relogin=false

[General]
Numlock=on

[Theme]
Current=breeze
EOF
systemctl enable sddm.service

# ─── Snapper: automatic BTRFS snapshots ───────────────────────────────────────
# snap-pac  — pre/post pacman snapshots (automatically when you install/update)
# grub-btrfs — detects new snapshots and adds them to GRUB menu
# btrfs-assistant — GUI for managing snapshots
echo "==> Setting up snapper for automatic snapshots..."
pacman -S --noconfirm --needed snapper snap-pac btrfs-assistant

# Snapper setup with pre-created @snapshots subvolume:
# 1. Unmount our @snapshots from /.snapshots (snapper needs to create the config)
# 2. Let snapper create-config (it tries to create /.snapshots subvolume)
# 3. Delete snapper's nested subvolume
# 4. Remount our top-level @snapshots subvolume
umount /.snapshots 2>/dev/null || true
rm -rf /.snapshots

snapper -c root create-config /

# Delete the nested subvolume snapper just created inside @
btrfs subvolume delete /.snapshots

# Recreate the mountpoint and mount our top-level @snapshots
mkdir -p /.snapshots
mount /.snapshots

# Permissions: allow wheel group to list/create snapshots without root
chmod 750 /.snapshots
chown :wheel /.snapshots

# Configure snapper limits (conservative — adjust to taste)
# TIMELINE_CREATE/CLEANUP must be "yes" for the scheduled timer to actually run.
# Keep: 5 hourly, 7 daily, 2 weekly, 1 monthly, 0 yearly
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/'         /etc/snapper/configs/root
sed -i 's/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP="yes"/'        /etc/snapper/configs/root
sed -i 's/^TIMELINE_MIN_AGE=.*/TIMELINE_MIN_AGE="1800"/'       /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/'   /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/'     /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="2"/'   /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="1"/' /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/'   /etc/snapper/configs/root

# Allow $USERNAME to use snapper without root
sed -i "s/^ALLOW_USERS=.*/ALLOW_USERS=\"$USERNAME\"/" /etc/snapper/configs/root
sed -i "s/^ALLOW_GROUPS=.*/ALLOW_GROUPS=\"wheel\"/"   /etc/snapper/configs/root
sed -i 's/^SYNC_ACL=.*/SYNC_ACL="yes"/'               /etc/snapper/configs/root

# Enable snapper timers (timeline + cleanup)
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer

# grub-btrfsd: watches for new snapper snapshots and updates GRUB automatically
# Requires inotify-tools (installed above with grub-btrfs)
systemctl enable grub-btrfsd

# Create initial snapshot labelled "Base Install"
snapper -c root create --description "Base Install" --cleanup-algorithm number

# ─── Core services ────────────────────────────────────────────────────────────
echo "==> Enabling system services..."
# Always-available services (packages installed in MINIMAL)
systemctl enable avahi-daemon.service      # mDNS/zeroconf — avahi in pacman-pkgs.txt
systemctl enable fstrim.timer              # periodic SSD/NVMe TRIM — util-linux always present
systemctl enable reflector.timer           # weekly mirrorlist refresh — reflector in pacman-pkgs.txt
systemctl disable dhcpcd.service 2>/dev/null || true

# FULL-install services — packages in FULL section of pacman-pkgs.txt
# Using || true so they don't abort the script on a MINIMAL install
systemctl enable bluetooth      2>/dev/null || echo "  bluetooth: skipped (bluez not installed)"
systemctl enable cups.service   2>/dev/null || echo "  cups: skipped (cups not installed)"
systemctl enable cronie         2>/dev/null || echo "  cronie: skipped (cronie not installed)"

# Virtualization — FULL only, package is qemu-full + libvirt
systemctl enable libvirtd.service 2>/dev/null || echo "  libvirtd: skipped (libvirt not installed)"

# ─── Reflector config ─────────────────────────────────────────────────────────
mkdir -p /etc/xdg/reflector
cat > /etc/xdg/reflector/reflector.conf <<'EOF'
--country 'United States'
--age 12
--protocol https
--sort rate
--number 20
--save /etc/pacman.d/mirrorlist
EOF

# ─── Restore sudo: require password ───────────────────────────────────────────
echo "==> Finalizing sudo configuration..."
sed -i 's/^%wheel ALL=(ALL) NOPASSWD: ALL/# %wheel ALL=(ALL) NOPASSWD: ALL/'     /etc/sudoers
sed -i 's/^%wheel ALL=(ALL:ALL) NOPASSWD: ALL/# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/'     /etc/sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ─── Cleanup ──────────────────────────────────────────────────────────────────
echo "==> Cleaning up install scripts..."
rm -rf "$HOME/ArchScript"
rm -rf "/home/$USERNAME/ArchScript"

echo -ne "
────────────────────────────────────────────
  Stage 3 complete.
  Post-install notes:
  • GRUB theme: place hex-arch files in
      configs/boot/grub/themes/hex-arch/
  • Plymouth theme: place arch-glow files in
      configs/usr/share/plymouth/themes/arch-glow/
  • Snapper: run 'snapper list' to verify.
  • btrfs-assistant: GUI for snapshot management.
  • Ctrl+Alt+T opens Konsole (set at first login).
────────────────────────────────────────────
"
