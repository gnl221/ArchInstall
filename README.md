# Arch Linux Installer
**KDE · BTRFS · Wayland · Ham Radio**

Automated Arch install. Fixed choices: KDE Plasma, BTRFS, paru, Wayland.
Optional: Ham Radio software, GPS support. Full vs Minimal install type.

---

## Usage

Boot the Arch ISO, connect to the internet, then:

```bash
pacman -Sy --noconfirm git
git clone https://github.com/gnl221/ArchInstall
cd ArchInstall
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

## Required repo structure

```
archinstall.sh
configs/
  _bashrc
  boot/grub/themes/hex-arch/     ← add theme files here
    theme.txt
    background_arch.png
    fonts/
    *.png
  usr/share/plymouth/themes/arch-glow/  ← add theme files here
    arch-glow.plymouth
    arch-glow.script
pkg-files/
  pacman-pkgs.txt
  kde.txt
  aur-pkgs.txt
scripts/
  startup.sh
  0-preinstall.sh
  1-setup.sh
  2-user.sh
  3-post-setup.sh
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

Mount options (SSD/NVMe): `noatime,compress=zstd,ssd,space_cache=v2,commit=120`
Mount options (HDD):      `noatime,compress=zstd,space_cache=v2,commit=120`

---

## Themes installed

| Theme       | Source | Default? | Notes                          |
|-------------|--------|----------|--------------------------------|
| Breeze Dark | KDE    | ✅ Yes   | Built into KDE, no package needed |
| KDE Sweet   | AUR    | ❌ No    | Installed, apply via System Settings |

To apply Sweet KDE: System Settings → Appearance → Global Theme → Sweet

---

## Ham radio packages (optional — selected during install)

| Package           | Source | Purpose                                    |
|-------------------|--------|--------------------------------------------|
| `wsjtx-improved`  | AUR    | FT8, FT4, MSK144, WSPR, Q65              |
| `js8call-improved`| AUR    | Active JS8Call development fork            |
| `chirp-next`      | AUR    | Radio programmer (AnyTone, Baofeng, etc.)  |
| `pat-bin`         | AUR    | Winlink email over radio                   |
| `direwolf`        | pacman | Software TNC for APRS/VHF packet           |
| `fldigi`          | pacman | Multimode digital (PSK31, RTTY, etc.)      |
| `hamlib`          | pacman | CAT rig control library                    |

Your user is added to `uucp` (serial ports) and `plugdev` (USB devices) groups.

---

## GPS packages (optional — shown only if Ham Radio = Yes)

| Package      | Purpose                              |
|--------------|--------------------------------------|
| `gpsd`       | GPS daemon, socket-activated         |
| `python-gps` | Python bindings for gpsd             |
| `chrony`     | NTP with GPS SHM time source         |

`/etc/chrony.conf` is pre-configured with SHM 0 (NMEA) and SHM 2 (PPS) refclocks.
A udev rule auto-links USB GPS devices to `/dev/gps0` and auto-starts gpsd.
Covers: u-blox (Prolific + native VID), FTDI, Garmin GPS-18.

---

## Snapper snapshot management

Snapshots are created automatically by `snap-pac` on every pacman install/update
(pre + post pairs). Timeline snapshots run hourly via `snapper-timeline.timer`.
GRUB shows bootable snapshots via `grub-btrfsd`.

GUI: **btrfs-assistant** (installed in FULL mode).

```bash
snapper list                               # list all snapshots
snapper -c root create --description "before big change"
snapper -c root status 5..6               # what changed
snapper -c root undochange 5..6           # roll back changes
```

---

## Keyboard shortcut

`Ctrl+Alt+T` → Konsole

---

## Browsers installed

- **Firefox** — pacman (FULL install)
- **Google Chrome** — AUR (FULL install)
