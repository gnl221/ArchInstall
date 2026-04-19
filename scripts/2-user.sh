#!/usr/bin/env bash
#
# @file 2-user.sh
# @brief Runs as the unprivileged user inside chroot.
#        Installs KDE packages, builds paru, installs AUR packages,
#        ham radio/GPS software (if selected), themes, and user config.
#
echo -ne "
────────────────────────────────────────────
  Stage 2: User Packages and Configuration
────────────────────────────────────────────
"

# Safety check: this script must run as the target user, not root.
# If it's running as root it means Stage 1 failed to create the user account.
if [[ "$(id -u)" == "0" ]]; then
    echo "ERROR: Stage 2 is running as root — the user account was not created in Stage 1."
    echo "       Check 1-setup.log for 'useradd' errors. Aborting."
    exit 1
fi

source "$HOME/ArchScript/configs/setup.conf"
export PATH="$PATH:$HOME/.local/bin"

mkdir -p "$HOME/.cache" "$HOME/.config"

# ─── KDE packages ─────────────────────────────────────────────────────────────
echo "==> Installing KDE packages..."
if [[ "$INSTALL_TYPE" == "MINIMAL" ]]; then
    KDE_CONTENT=$(sed -n '/--END OF MINIMAL INSTALL--/q;p' \
        "$HOME/ArchScript/pkg-files/kde.txt")
else
    KDE_CONTENT=$(cat "$HOME/ArchScript/pkg-files/kde.txt")
fi

echo "$KDE_CONTENT" | while read -r line; do
    [[ -z "$line" || "$line" =~ ^# || "$line" == '--END OF MINIMAL INSTALL--' ]] && continue
    echo "Installing: $line"
    sudo pacman -S --noconfirm --needed "$line"
done

# ─── Build and install paru from source ──────────────────────────────────────
# We do NOT use paru-bin. paru-bin is a pre-compiled binary linked against a
# specific libalpm soname. When pacman updates and bumps the libalpm major
# version, paru-bin breaks with "libalpm.so.XX: cannot open shared object file".
# Building from source compiles against the locally installed libalpm so it
# always matches. The rust toolchain is removed after the build to save ~1.5GB.
echo "==> Installing rust toolchain for paru build..."
sudo pacman -S --noconfirm --needed rust

echo "==> Building paru from source..."
cd /tmp
git clone --depth=1 https://aur.archlinux.org/paru.git paru-src
cd paru-src
makepkg -si --noconfirm
cd ~
rm -rf /tmp/paru-src

echo "==> Removing rust toolchain (no longer needed)..."
sudo pacman -Rns --noconfirm rust 2>/dev/null || true

# Configure paru
mkdir -p "$HOME/.config/paru"
cat > "$HOME/.config/paru/paru.conf" <<'EOF'
[options]
BottomUp
SudoLoop
NewsOnUpgrade
CleanAfter
EOF

# ─── AUR packages ─────────────────────────────────────────────────────────────
echo "==> Installing AUR packages..."
if [[ "$INSTALL_TYPE" == "MINIMAL" ]]; then
    AUR_CONTENT=$(sed -n '/--END OF MINIMAL INSTALL--/q;p' \
        "$HOME/ArchScript/pkg-files/aur-pkgs.txt")
else
    AUR_CONTENT=$(cat "$HOME/ArchScript/pkg-files/aur-pkgs.txt")
fi

echo "$AUR_CONTENT" | while read -r line; do
    [[ -z "$line" || "$line" =~ ^# || "$line" == '--END OF MINIMAL INSTALL--' ]] && continue
    echo "Installing (AUR): $line"
    paru -S --noconfirm --needed "$line"
done

# ─── Ham radio software ───────────────────────────────────────────────────────
if [[ "$HAM_RADIO" == "YES" ]]; then
    echo "==> Installing ham radio software (pacman)..."
    sudo pacman -S --noconfirm --needed \
        hamlib \
        direwolf \
        fldigi \
        python-pyserial \
        python-requests \
        python-pip

    echo "==> Installing ham radio software (AUR)..."
    # wsjtx-improved: FT8, FT4, MSK144, WSPR, Q65
    # Note: wsjtx-improved-al-qt6 is the Qt6 build — swap if preferred
    paru -S --noconfirm --needed wsjtx-improved

    # js8call-improved: active fork of JS8Call
    paru -S --noconfirm --needed js8call-improved

    # chirp-next: radio programmer (AnyTone AT-778UV, Baofeng, etc.)
    paru -S --noconfirm --needed chirp-next

    # pat: Winlink email over radio (uses Direwolf for VHF packet)
    paru -S --noconfirm --needed pat-bin

    # TrustedQSL: ARRL logginf software
    paru -S --noconfirm --needed TrustedQSL

    # gridtracker2: Tracking and logging helper for wsjt-x
    paru -S --noconfirm --needed gridtracker2-bin
fi

# ─── GPS support ──────────────────────────────────────────────────────────────
if [[ "${USE_GPS:-NO}" == "YES" ]]; then
    echo "==> Installing GPS support..."
    sudo pacman -S --noconfirm --needed gpsd chrony

    # chrony.conf: GPS SHM refclock (NMEA on SHM 0, PPS on SHM 2)
    # Requires gpsd running. Adjust offset/delay per your GPS puck.
    sudo tee /etc/chrony.conf > /dev/null <<'EOF'
# chrony.conf — GPS SHM time source + NTP fallback
# SHM 0 = NMEA data from gpsd (~100ms accuracy)
# SHM 2 = PPS signal if your GPS outputs it (sub-ms accuracy)
refclock SHM 0 refid GPS  precision 1e-1 offset 0.0 delay 0.2
refclock SHM 2 refid PPS  precision 1e-9 prefer

server 0.arch.pool.ntp.org iburst
server 1.arch.pool.ntp.org iburst
server 2.arch.pool.ntp.org iburst
server 3.arch.pool.ntp.org iburst

# Uncomment to serve time to local network devices (e.g. other shack gear)
# allow 192.168.0.0/16

makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
EOF

    # udev rules: auto-link USB GPS devices to /dev/gps0 and auto-start gpsd
    sudo tee /etc/udev/rules.d/99-usb-gps.rules > /dev/null <<'EOF'
# u-blox GPS (Prolific USB-Serial, covers many GPS pucks)
SUBSYSTEM=="tty", ATTRS{idVendor}=="067b", ATTRS{idProduct}=="2303", \
    SYMLINK+="gps0", TAG+="systemd", ENV{SYSTEMD_WANTS}="gpsd@%k.service"

# u-blox native VID (ZED-F9P, NEO-M8, etc.)
SUBSYSTEM=="tty", ATTRS{idVendor}=="1546", \
    SYMLINK+="gps0", TAG+="systemd", ENV{SYSTEMD_WANTS}="gpsd@%k.service"

# Generic FTDI USB-Serial (many GPS modules, Digirig, etc.)
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", \
    SYMLINK+="gps1", TAG+="systemd", ENV{SYSTEMD_WANTS}="gpsd@%k.service"

# Garmin GPS-18 USB
SUBSYSTEM=="tty", ATTRS{idVendor}=="091e", ATTRS{idProduct}=="0003", \
    SYMLINK+="gps0", TAG+="systemd", ENV{SYSTEMD_WANTS}="gpsd@%k.service"
EOF

    sudo systemctl enable gpsd.socket
    sudo systemctl enable chronyd
fi

# ─── Themes ───────────────────────────────────────────────────────────────────
echo "==> Installing themes..."

# KDE Sweet — available as an alternative, not set as default.
# Apply via: System Settings → Appearance → Global Theme → Sweet
paru -S --noconfirm --needed sweet-kde sweet-theme-git || \
    echo "WARNING: Sweet theme AUR build failed — install manually from https://store.kde.org/p/1294174"

# ─── Apply Breeze Dark theme (built into KDE, no extra packages needed) ────────
echo "==> Applying Breeze Dark theme..."

kwriteconfig6 --file plasmarc   --group Theme --key name "breeze-dark"
kwriteconfig6 --file kdeglobals --group General --key ColorScheme "BreezeDark"
kwriteconfig6 --file kdeglobals --group KDE --key widgetStyle "Breeze"
kwriteconfig6 --file kdeglobals --group Icons --key Theme "breeze-dark"
kwriteconfig6 --file kwinrc --group "org.kde.kdecoration2" \
    --key library "org.kde.breeze"
kwriteconfig6 --file kwinrc --group "org.kde.kdecoration2" \
    --key theme "Breeze"

# GTK 3/4 — Breeze-Dark ships with plasma-meta via breeze-gtk
mkdir -p "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"
cat > "$HOME/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=Breeze-Dark
gtk-icon-theme-name=breeze-dark
gtk-cursor-theme-name=breeze_cursors
gtk-font-name=Noto Sans 10
EOF
cp "$HOME/.config/gtk-3.0/settings.ini" "$HOME/.config/gtk-4.0/settings.ini"

# GTK 2 (correct path: ~/.gtkrc-2.0)
cat > "$HOME/.gtkrc-2.0" <<'EOF'
gtk-theme-name="Breeze-Dark"
gtk-icon-theme-name="breeze-dark"
gtk-font-name="Noto Sans 10"
gtk-cursor-theme-name="breeze_cursors"
EOF

# ─── Konsole shortcut: Ctrl+Alt+T ─────────────────────────────────────────────
echo "==> Setting Ctrl+Alt+T shortcut for Konsole..."
mkdir -p "$HOME/.config"
# Append to kglobalshortcutsrc — creates the section if it doesn't exist
if ! grep -q "\[org.kde.konsole.desktop\]" "$HOME/.config/kglobalshortcutsrc" 2>/dev/null; then
    cat >> "$HOME/.config/kglobalshortcutsrc" <<'EOF'

[org.kde.konsole.desktop]
_launch=Ctrl+Alt+T,none,Konsole
EOF
fi

# ─── .bashrc ──────────────────────────────────────────────────────────────────
echo "==> Installing .bashrc..."
cp "$HOME/ArchScript/configs/_bashrc" "$HOME/.bashrc"
# Also copy root's bashrc
sudo cp "$HOME/ArchScript/configs/_bashrc" /root/.bashrc

# ─── XDG user directories ─────────────────────────────────────────────────────
xdg-user-dirs-update

echo -e "\n── Stage 2 complete. ──────────────────────────\n"
