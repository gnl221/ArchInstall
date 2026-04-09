# Arch Linux Installer
**KDE · BTRFS · Wayland · Ham Radio**

Automated Arch install. Fixed choices: KDE Plasma, BTRFS, paru, Wayland.
Optional: Ham Radio software, GPS support. Full vs Minimal install type.

---

## Usage

Boot the Arch ISO, connect to the internet, then:

```bash
pacman -Sy --noconfirm git
git clone https://github.com/YOUR_USER/ArchInstall
cd ArchScript
bash archinstall.sh
```

### WiFi on the live ISO
```bash
iwctl
  device list
  station wlan0 scan
  station wlan0 get-networks
  station wlan0 connect "SSID"
  exit
```

---

## Script flow

```
archinstall.sh
 │
 ├─ scripts/startup.sh        Prompts: user/host/disk/timezone/keymap/
 │                            install type/ham radio/GPS → writes configs/setup.conf
 │
 ├─ scripts/0-preinstall.sh   Partitions disk, creates BTRFS subvolumes,
 │                            runs pacstrap, generates fstab
 │
 ├─ scripts/1-setup.sh        (chroot, root) Locale, hostname, users,
 │                            microcode, GPU drivers, pacman-pkgs.txt, mkinitcpio
 │
 ├─ scripts/2-user.sh         (chroot, as user) KDE, paru, AUR packages,
 │                            themes, ham radio, GPS, .bashrc, shortcuts
 │
 └─ scripts/3-post-setup.sh   (chroot, root) GRUB + hex-arch theme, Plymouth,
                              SDDM, snapper auto-snapshots, services, sudo cleanup
```

---

## BTRFS subvolume layout

| Subvolume           | Mountpoint              | Purpose                              |
|---------------------|-------------------------|--------------------------------------|
| `@`                 | `/`                     | Root — snapshotted by snapper        |
| `@home`             | `/home`                 | User data — survives rollbacks       |
| `@snapshots`        | `/.snapshots`           | Snapper snapshot storage             |
| `@var_log`          | `/var/log`              | Logs persist across rollbacks        |
| `@var_cache_pacman` | `/var/cache/pacman/pkg` | Package cache excluded from snapshots|

Mount options (SSD): `noatime,compress=zstd,ssd,space_cache=v2,commit=120`
Mount options (HDD): `noatime,compress=zstd,space_cache=v2,commit=120`

---

## Required files — add these to the repo before installing

### GRUB theme (hex-arch)
Place all hex-arch theme assets here:
```
configs/boot/grub/themes/hex-arch/
  theme.txt
  background_arch.png
  select_*.png
  sb_thumb_*.png
  sb_frame_*.png
  progress_bar_*.png
  progress_highlight_*.png
  fonts/
```
The `theme.txt` you already have is included in this repo.

### Plymouth theme (arch-glow)
Place arch-glow theme assets here:
```
configs/usr/share/plymouth/themes/arch-glow/
  arch-glow.plymouth
  arch-glow.script
  (images/)
```

---

## Themes installed

| Theme        | Type         | Source     | Default? |
|--------------|--------------|------------|----------|
| Arc Dark     | KDE + GTK    | pacman/AUR | ✅ Yes   |
| KDE Sweet    | KDE + GTK    | AUR        | ❌ No    |

To apply Sweet KDE after install: System Settings → Appearance → Global Theme → Sweet.

Arc Dark packages: `arc-gtk-theme` (pacman) + `arc-kde` (AUR)
Sweet packages: `sweet-kde` + `sweet-theme-git` (both AUR)

---

## Ham radio packages (optional — selected during install)

| Package          | Source | Purpose                                   |
|------------------|--------|-------------------------------------------|
| `wsjtx-improved` | AUR    | FT8, FT4, MSK144, WSPR, Q65             |
| `js8call-improved`| AUR   | Active JS8Call development fork           |
| `chirp-next`     | AUR    | Radio programmer (AnyTone, Baofeng, etc.) |
| `pat-bin`        | AUR    | Winlink email over radio                  |
| `direwolf`       | pacman | Software TNC for APRS/VHF packet          |
| `fldigi`         | pacman | Multimode digital (PSK31, RTTY, etc.)     |
| `hamlib`         | pacman | CAT rig control library                   |

Your user is added to the `uucp` group for serial port access (CAT control, GPS).

---

## GPS packages (optional — shown only if Ham Radio = Yes)

| Package       | Purpose                              |
|---------------|--------------------------------------|
| `gpsd`        | GPS daemon, socket-activated         |
| `python-gps`  | Python bindings for gpsd             |
| `chrony`      | NTP with GPS SHM time source         |

A udev rule is installed to auto-link USB GPS devices to `/dev/gps0` and
auto-start gpsd. Covers u-blox (Prolific + native VID), FTDI, and Garmin GPS-18.

`/etc/chrony.conf` is pre-configured with SHM 0 (NMEA) and SHM 2 (PPS) refclocks.

---

## Snapper snapshot management

Automatic snapshots happen via `snap-pac` (pacman hooks) — every install/update
creates a pre/post snapshot pair. Timeline snapshots run hourly via systemd timer.

GRUB shows bootable snapshots via `grub-btrfsd` (watches `/.snapshots` with inotify).

GUI management: **btrfs-assistant** (installed in FULL mode).

Useful commands:
```bash
snapper list                         # list all snapshots
snapper -c root create --description "before big change"
snapper -c root status 5..6          # what changed between snapshots 5 and 6
snapper -c root undochange 5..6      # undo those changes
```

---

## pkg-files directory

| File              | Installed by  | Notes                              |
|-------------------|---------------|------------------------------------|
| `pacman-pkgs.txt` | 1-setup.sh    | Base system, apps, gaming, Wine    |
| `kde.txt`         | 2-user.sh     | KDE Plasma and applications        |
| `aur-pkgs.txt`    | 2-user.sh     | Themes, tools (paru handles these) |

Ham radio and GPS packages are not in these files — they're installed inline
in `2-user.sh` based on your startup choices.

---

## Keyboard shortcut

`Ctrl+Alt+T` → Konsole (set in `~/.config/kglobalshortcutsrc` at install).
