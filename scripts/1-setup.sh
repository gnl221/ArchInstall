#!/usr/bin/env bash
#
# @file 1-setup.sh
# @brief Runs inside chroot. Configures locale, users, microcode, GPU drivers,
#        installs pacman packages, and sets up mkinitcpio.
#
echo -ne "
────────────────────────────────────────────
  Stage 1: System Configuration (chroot)
────────────────────────────────────────────
"
source "$HOME/ArchScript/configs/setup.conf"

# ─── Network ──────────────────────────────────────────────────────────────────
echo "==> Setting up NetworkManager..."
pacman -S --noconfirm --needed networkmanager dhclient
systemctl enable NetworkManager

# ─── Pacman config ────────────────────────────────────────────────────────────
echo "==> Configuring pacman..."
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
# Enable multilib for 32-bit (wine, steam, lutris)
sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm --needed

# ─── Makeflags: use all CPU cores ─────────────────────────────────────────────
NC=$(nproc)
TOTAL_MEM=$(grep MemTotal /proc/meminfo | grep -o '[0-9]*')
if [[ $TOTAL_MEM -gt 8000000 ]]; then
    echo "==> Setting makeflags to -j$NC for parallel compilation..."
    sed -i "s/#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j$NC\"/" /etc/makepkg.conf
    sed -i "s/COMPRESSXZ=(xz -c -z -)/COMPRESSXZ=(xz -c -T $NC -z -)/" /etc/makepkg.conf
fi

# ─── Locale and timezone ──────────────────────────────────────────────────────
echo "==> Configuring locale and timezone..."
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
localectl --no-ask-password set-locale LANG="en_US.UTF-8" LC_TIME="en_US.UTF-8"
echo "LANG=en_US.UTF-8" > /etc/locale.conf

timedatectl --no-ask-password set-timezone "$TIMEZONE"
timedatectl --no-ask-password set-ntp 1
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

localectl --no-ask-password set-keymap "$KEYMAP"
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# ─── Hostname ─────────────────────────────────────────────────────────────────
echo "==> Setting hostname: $NAME_OF_MACHINE"
echo "$NAME_OF_MACHINE" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $NAME_OF_MACHINE.localdomain $NAME_OF_MACHINE
EOF

# ─── Sudo: NOPASSWD for install (removed at end of Stage 3) ──────────────────
sed -i 's/^# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

# ─── User account ─────────────────────────────────────────────────────────────
echo "==> Creating user: $USERNAME"
# Groups:
#   wheel   — sudo access
#   audio   — audio devices (ALSA, PipeWire)
#   video   — video/GPU devices
#   storage — storage devices
#   optical — optical drives
#   uucp    — serial ports (CAT radio control, GPS NMEA, Digirig)
#   plugdev — USB device access (CHIRP, USB GPS)
#   libvirt — virtualization management
groupadd -f libvirt
useradd -m -G wheel,audio,video,storage,optical,uucp,plugdev,libvirt \
    -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
echo "root:$PASSWORD" | chpasswd

# Copy install scripts to user home (needed for Stage 2 running as user)
cp -R "$HOME/ArchScript" "/home/$USERNAME/ArchScript"
chown -R "$USERNAME:" "/home/$USERNAME/ArchScript"

# ─── Microcode ────────────────────────────────────────────────────────────────
echo "==> Detecting CPU and installing microcode..."
proc_type=$(lscpu)
if grep -qE "GenuineIntel" <<< "$proc_type"; then
    echo "Intel CPU detected."
    pacman -S --noconfirm --needed intel-ucode
elif grep -qE "AuthenticAMD" <<< "$proc_type"; then
    echo "AMD CPU detected."
    pacman -S --noconfirm --needed amd-ucode
fi

# ─── GPU drivers ──────────────────────────────────────────────────────────────
echo "==> Detecting GPU and installing drivers..."
gpu_type=$(lspci)
if grep -qE "NVIDIA|GeForce" <<< "$gpu_type"; then
    echo "NVIDIA GPU detected."
    pacman -S --noconfirm --needed \
        nvidia-dkms nvidia-utils lib32-nvidia-utils \
        nvidia-settings vulkan-icd-loader lib32-vulkan-icd-loader
elif lspci | grep 'VGA' | grep -qE "Radeon|AMD"; then
    echo "AMD GPU detected."
    pacman -S --noconfirm --needed \
        xf86-video-amdgpu \
        lib32-mesa vulkan-radeon lib32-vulkan-radeon \
        vulkan-icd-loader lib32-vulkan-icd-loader
elif grep -qE "Intel Corporation UHD|Integrated Graphics Controller" <<< "$gpu_type"; then
    echo "Intel GPU detected."
    pacman -S --noconfirm --needed \
        libva-intel-driver libvdpau-va-gl \
        lib32-vulkan-intel vulkan-intel \
        libva-utils lib32-mesa \
        vulkan-icd-loader lib32-vulkan-icd-loader
fi

# ─── Base system packages ─────────────────────────────────────────────────────
echo "==> Installing base system packages..."
# Installs everything up to (and optionally including) --END OF MINIMAL INSTALL--
# When INSTALL_TYPE=FULL, reads the entire file; MINIMAL stops at the marker.
sed -n "/${INSTALL_TYPE}/q;p" "$HOME/ArchScript/pkg-files/pacman-pkgs.txt" | \
while read -r line; do
    [[ "$line" == '--END OF MINIMAL INSTALL--' ]] && continue
    [[ -z "$line" || "$line" =~ ^# ]]             && continue
    echo "Installing: $line"
    pacman -S --noconfirm --needed "$line"
done

# ─── mkinitcpio ───────────────────────────────────────────────────────────────
echo "==> Configuring mkinitcpio..."
# Add btrfs to MODULES for early boot BTRFS support
sed -i 's/^MODULES=(/MODULES=(btrfs /' /etc/mkinitcpio.conf
# NOTE: grub-btrfs-overlayfs hook is added in 3-post-setup.sh after grub-btrfs
# is installed. mkinitcpio is run again there to pick it up.
mkinitcpio -P

echo -e "\n── Stage 1 complete. ──────────────────────────\n"
