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
# Add it now and rebuild initramfs so snapshot boots get overlayfs write layer.
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
sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT=".*"|GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 audit=0 rootflags=subvol=@"|' \
    /etc/default/grub
sed -i 's/#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' \
    /etc/default/grub

# ─── GRUB: hex-arch theme ─────────────────────────────────────────────────────
echo "==> Installing hex-arch GRUB theme..."
THEME_DIR="/boot/grub/themes"
THEME_NAME="hex-arch"
THEME_SRC="$HOME/ArchScript/configs/boot/grub/themes/$THEME_NAME"

echo "    Looking for theme at: $THEME_SRC"
if [[ -d "$THEME_SRC" ]]; then
    mkdir -p "${THEME_DIR}/${THEME_NAME}"
    cp -a "$THEME_SRC/." "${THEME_DIR}/${THEME_NAME}/"
    grep -q "GRUB_THEME=" /etc/default/grub && \
        sed -i '/GRUB_THEME=/d' /etc/default/grub
    echo "GRUB_THEME=\"${THEME_DIR}/${THEME_NAME}/theme.txt\"" >> /etc/default/grub
    echo "    hex-arch theme installed."
else
    echo "    hex-arch not found — GRUB will use the default theme."
fi

# ─── Plymouth ─────────────────────────────────────────────────────────────────
echo "==> Installing Plymouth boot splash..."
pacman -S --noconfirm --needed plymouth

# Insert 'plymouth' hook after 'udev', before block/filesystems
sed -i 's/HOOKS=(base udev/HOOKS=(base udev plymouth/' /etc/mkinitcpio.conf

PLYMOUTH_THEMES_DIR="$HOME/ArchScript/configs/usr/share/plymouth/themes"
PLYMOUTH_THEME="arch-glow"

echo "    Looking for Plymouth theme at: ${PLYMOUTH_THEMES_DIR}/${PLYMOUTH_THEME}"
if [[ -d "${PLYMOUTH_THEMES_DIR}/${PLYMOUTH_THEME}" ]]; then
    mkdir -p /usr/share/plymouth/themes
    cp -rf "${PLYMOUTH_THEMES_DIR}/${PLYMOUTH_THEME}" /usr/share/plymouth/themes/
    # -R sets theme AND rebuilds initramfs
    plymouth-set-default-theme -R "$PLYMOUTH_THEME"
    echo "    arch-glow Plymouth theme installed."
else
    echo "    arch-glow not found — using default Plymouth theme."
    mkinitcpio -P
fi

# ─── GRUB: generate config ────────────────────────────────────────────────────
# Run after Plymouth so initramfs already contains the plymouth hook
grub-mkconfig -o /boot/grub/grub.cfg

# ─── SDDM ─────────────────────────────────────────────────────────────────────
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
echo "==> Setting up snapper for automatic snapshots..."
pacman -S --noconfirm --needed snapper snap-pac btrfs-assistant

# Snapper setup with pre-created @snapshots subvolume:
# 1. Unmount @snapshots — snapper's create-config needs /.snapshots to not exist
# 2. snapper create-config — creates /etc/snapper/configs/root and a nested subvol
# 3. Delete the nested subvolume snapper created (we already have @snapshots)
# 4. Remount our top-level @snapshots back onto /.snapshots
umount /.snapshots 2>/dev/null || true
rm -rf /.snapshots

# --no-dbus is REQUIRED in a chroot — there is no DBus session.
# Without it: "fatal library error, lookup self" / ServiceUnknown errors
# and the config file is never created, causing every subsequent sed to fail.
snapper --no-dbus -c root create-config /

btrfs subvolume delete /.snapshots

mkdir -p /.snapshots
mount /.snapshots

chmod 750 /.snapshots
chown :wheel /.snapshots

# TIMELINE_CREATE and TIMELINE_CLEANUP must both be "yes" or the
# snapper-timeline.timer runs but silently takes no snapshots.
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/'         /etc/snapper/configs/root
sed -i 's/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP="yes"/'        /etc/snapper/configs/root
sed -i 's/^TIMELINE_MIN_AGE=.*/TIMELINE_MIN_AGE="1800"/'       /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/'   /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/'     /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="2"/'   /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="1"/' /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/'   /etc/snapper/configs/root

sed -i "s/^ALLOW_USERS=.*/ALLOW_USERS=\"$USERNAME\"/" /etc/snapper/configs/root
sed -i "s/^ALLOW_GROUPS=.*/ALLOW_GROUPS=\"wheel\"/"   /etc/snapper/configs/root
sed -i 's/^SYNC_ACL=.*/SYNC_ACL="yes"/'               /etc/snapper/configs/root

systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer
systemctl enable grub-btrfsd

# Also needs --no-dbus in chroot
snapper --no-dbus -c root create --description "Base Install" --cleanup-algorithm number

# ─── Core services ────────────────────────────────────────────────────────────
echo "==> Enabling system services..."
systemctl enable avahi-daemon.service
systemctl enable fstrim.timer
systemctl enable reflector.timer 2>/dev/null || echo "  reflector.timer: not found, skipping"
systemctl disable dhcpcd.service 2>/dev/null || true

# FULL-only services — guard with || so MINIMAL installs don't abort
systemctl enable bluetooth    2>/dev/null || echo "  bluetooth: skipped (bluez not installed)"
systemctl enable cups.service 2>/dev/null || echo "  cups: skipped (cups not installed)"
systemctl enable cronie       2>/dev/null || echo "  cronie: skipped (cronie not installed)"
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
sed -i 's/^%wheel ALL=(ALL) NOPASSWD: ALL/# %wheel ALL=(ALL) NOPASSWD: ALL/'         /etc/sudoers
sed -i 's/^%wheel ALL=(ALL:ALL) NOPASSWD: ALL/# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/'         /etc/sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ─── Cleanup ──────────────────────────────────────────────────────────────────
echo "==> Cleaning up install scripts..."
rm -rf "$HOME/ArchScript"
rm -rf "/home/$USERNAME/ArchScript"

echo -ne "
────────────────────────────────────────────
  Stage 3 complete.
────────────────────────────────────────────
"
