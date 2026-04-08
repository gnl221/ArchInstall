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
source "$HOME/ArchScript/configs/setup.conf"
export PATH="$PATH:$HOME/.local/bin"

mkdir -p "$HOME/.cache" "$HOME/.config"

# ─── KDE packages ─────────────────────────────────────────────────────────────
echo "==> Installing KDE packages..."
sed -n "/${INSTALL_TYPE}/q;p" "$HOME/ArchScript/pkg-files/kde.txt" | \
while read -r line; do
    [[ "$line" == '--END OF MINIMAL INSTALL--' ]] && continue
    [[ -z "$line" || "$line" =~ ^# ]]             && continue
    echo "Installing: $line"
    sudo pacman -S --noconfirm --needed "$line"
done

# ─── Build and install paru ───────────────────────────────────────────────────
echo "==> Building paru AUR helper..."
cd ~
git clone --depth=1 https://aur.archlinux.org/paru-bin.git
cd paru-bin
makepkg -si --noconfirm
cd ~
rm -rf paru-bin

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
sed -n "/${INSTALL_TYPE}/q;p" "$HOME/ArchScript/pkg-files/aur-pkgs.txt" | \
while read -r line; do
    [[ "$line" == '--END OF MINIMAL INSTALL--' ]] && continue
    [[ -z "$line" || "$line" =~ ^# ]]             && continue
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
        python-pip \
        jdk-openjdk

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
fi

# ─── GPS support ──────────────────────────────────────────────────────────────
if [[ "${USE_GPS:-NO}" == "YES" ]]; then
    echo "==> Installing GPS support..."
    sudo pacman -S --noconfirm --needed gpsd python-gps chrony

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

# Arc Dark — default theme (KDE Plasma + GTK)
sudo pacman -S --noconfirm --needed arc-gtk-theme
# arc-kde provides the KDE Plasma theme + window decorations
paru -S --noconfirm --needed arc-kde

# KDE Sweet — installed as an option but NOT set as default.
# If AUR build fails, install manually from https://store.kde.org/p/1294174
# sweet-kde     = Plasma theme
# sweet-theme-git = GTK theme (more stable than sweet-gtk-theme)
paru -S --noconfirm --needed sweet-kde sweet-theme-git || \
    echo "WARNING: Sweet theme AUR build failed — install manually from KDE Store."

# ─── Apply Arc Dark theme (takes effect at first login) ───────────────────────
# Plasma color scheme
kwriteconfig6 --file kdeglobals --group General    --key ColorScheme     "ArcDark"
kwriteconfig6 --file kdeglobals --group KDE        --key widgetStyle     "kvantum"
# Plasma shell theme
kwriteconfig6 --file plasmarc   --group Theme      --key name            "arc-dark"
# Window decoration (Aurorae SVG theme from arc-kde package)
kwriteconfig6 --file kwinrc     --group "org.kde.kdecoration2" \
    --key library "org.kde.kwin.aurorae"
kwriteconfig6 --file kwinrc     --group "org.kde.kdecoration2" \
    --key theme   "__aurorae__svg__Arc-Dark"
# Icon theme (breeze-dark default icons, dark variant)
kwriteconfig6 --file kdeglobals --group Icons      --key Theme           "breeze-dark"

# Kvantum: set Arc Dark Qt theme engine theme
mkdir -p "$HOME/.config/Kvantum"
cat > "$HOME/.config/Kvantum/kvantum.kvconfig" <<'EOF'
[General]
theme=KvArcDark
EOF

# GTK 3/4 theme for GTK apps inside Plasma
mkdir -p "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"
cat > "$HOME/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=Arc-Dark
gtk-icon-theme-name=breeze-dark
gtk-cursor-theme-name=breeze_cursors
gtk-font-name=Noto Sans 10
EOF
cp "$HOME/.config/gtk-3.0/settings.ini" "$HOME/.config/gtk-4.0/settings.ini"

# GTK 2 theme (correct location is ~/.gtkrc-2.0, not ~/.config/gtkrc-2.0)
cat > "$HOME/.gtkrc-2.0" <<'EOF'
gtk-theme-name="Arc-Dark"
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
