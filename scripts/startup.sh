#!/usr/bin/env bash
#
# @file startup.sh
# @brief Collects user preferences and writes configs/setup.conf.
#        Prompts: username/password/hostname, disk, SSD, timezone,
#                 keymap, install type, ham radio, GPS.
#

CONFIG_FILE="$CONFIGS_DIR/setup.conf"
[[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"

# ─── Helpers ──────────────────────────────────────────────────────────────────
set_option() {
    grep -Eq "^${1}.*" "$CONFIG_FILE" && sed -i "/^${1}.*/d" "$CONFIG_FILE"
    echo "${1}=${2}" >> "$CONFIG_FILE"
}

set_password() {
    read -rs -p "Please enter password: " P1; echo
    read -rs -p "Please re-enter password: " P2; echo
    if [[ "$P1" == "$P2" ]]; then
        set_option "$1" "$P1"
    else
        echo "ERROR: Passwords do not match."
        set_password "$1"
    fi
}

background_checks() {
    [[ "$(id -u)" != "0" ]]     && echo "ERROR: Run as root." && exit 1
    [[ ! -e /etc/arch-release ]] && echo "ERROR: Not Arch Linux." && exit 1
    [[ -f /var/lib/pacman/db.lck ]] && echo "ERROR: Pacman locked. Remove /var/lib/pacman/db.lck." && exit 1
}

# ─── Arrow-key selection menu ─────────────────────────────────────────────────
select_option() {
    ESC=$(printf "\033")
    cursor_blink_on()  { printf "$ESC[?25h"; }
    cursor_blink_off() { printf "$ESC[?25l"; }
    cursor_to()        { printf "$ESC[$1;${2:-1}H"; }
    print_option()     { printf "$2   $1 "; }
    print_selected()   { printf "$2  $ESC[7m $1 $ESC[27m"; }
    get_cursor_row()   { IFS=';' read -sdR -p $'\E[6n' ROW COL; echo "${ROW#*[}"; }
    get_cursor_col()   { IFS=';' read -sdR -p $'\E[6n' ROW COL; echo "${COL#*[}"; }
    key_input() {
        local key
        IFS= read -rsn1 key 2>/dev/null >&2
        [[ $key == ""      ]] && echo enter
        [[ $key == $'\x20' ]] && echo space
        [[ $key == "k"     ]] && echo up
        [[ $key == "j"     ]] && echo down
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            [[ $key == "[A" ]] && echo up
            [[ $key == "[B" ]] && echo down
            [[ $key == "[C" ]] && echo right
            [[ $key == "[D" ]] && echo left
        fi
    }
    print_options_multicol() {
        local curr_col=$1 curr_row=$2 curr_idx idx=0 row col
        curr_idx=$(( curr_col + curr_row * colmax ))
        for option in "${options[@]}"; do
            row=$(( idx / colmax ))
            col=$(( idx - row * colmax ))
            cursor_to $(( startrow + row + 1 )) $(( offset * col + 1 ))
            [[ $idx -eq $curr_idx ]] && print_selected "$option" || print_option "$option"
            (( idx++ ))
        done
    }

    for opt; do printf "\n"; done
    local return_value=$1
    local lastrow; lastrow=$(get_cursor_row)
    local lastcol; lastcol=$(get_cursor_col)
    local startrow=$(( lastrow - $# ))
    local colmax=$2
    local cols; cols=$(tput cols)
    local offset=$(( cols / colmax ))
    shift 4

    trap "cursor_blink_on; stty echo; printf '\n'; exit" 2
    cursor_blink_off

    local active_row=0 active_col=0
    while true; do
        print_options_multicol "$active_col" "$active_row"
        case "$(key_input)" in
            enter) break ;;
            up)    (( active_row-- )); [[ $active_row -lt 0 ]] && active_row=0 ;;
            down)  (( active_row++ )); [[ $active_row -ge $(( ${#options[@]} / colmax )) ]] && active_row=$(( ${#options[@]} / colmax )) ;;
            left)  (( active_col-- )); [[ $active_col -lt 0 ]] && active_col=0 ;;
            right) (( active_col++ )); [[ $active_col -ge $colmax ]] && active_col=$(( colmax - 1 )) ;;
        esac
    done

    cursor_to "$lastrow"; printf "\n"; cursor_blink_on
    return $(( active_col + active_row * colmax ))
}

logo() {
echo -ne "
┌─────────────────────────────────────────┐
│         Arch Linux Installer            │
│    KDE · BTRFS · Wayland · Ham Radio    │
└─────────────────────────────────────────┘
"
}

# ─── Prompts ──────────────────────────────────────────────────────────────────
userinfo() {
    echo -e "\n── User Information ──────────────────────────"
    while true; do
        read -rp "Enter username: " username
        [[ "${username,,}" =~ ^[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\$)$ ]] && break
        echo "Invalid username. Use lowercase letters, numbers, hyphens, underscores."
    done
    set_option USERNAME "${username,,}"
    set_password PASSWORD
    read -rp "Enter hostname: " nameofmachine
    set_option NAME_OF_MACHINE "$nameofmachine"
}

diskpart() {
    echo -e "\n── Disk Selection ────────────────────────────"
    echo -e "WARNING: The selected disk will be completely erased.\n"
    PS3=$'\nSelect the disk to install on: '
    options=($(lsblk -n --output TYPE,KNAME,SIZE | awk '$1=="disk"{print "/dev/"$2"|"$3}'))
    select_option $? 1 "${options[@]}"
    local disk="${options[$?]%|*}"
    echo -e "\n${disk} selected"
    set_option DISK "${disk}"

    echo -e "\n── Drive Type ────────────────────────────────"
    echo "Is this an SSD or NVMe drive?"
    options=("Yes" "No")
    select_option $? 1 "${options[@]}"
    case "${options[$?]}" in
        Yes) set_option MOUNT_OPTIONS "noatime,compress=zstd,ssd,space_cache=v2,commit=120" ;;
        No)  set_option MOUNT_OPTIONS "noatime,compress=zstd,space_cache=v2,commit=120" ;;
    esac
}

timezone() {
    echo -e "\n── Timezone ──────────────────────────────────"
    local detected
    detected=$(curl -sf "https://ipapi.co/timezone") || detected="America/Detroit"
    echo "Detected timezone: $detected"
    echo "Is this correct?"
    options=("Yes" "No")
    select_option $? 1 "${options[@]}"
    case "${options[$?]}" in
        Yes) set_option TIMEZONE "$detected" ;;
        No)
            read -rp "Enter timezone (e.g. America/Detroit): " tz
            set_option TIMEZONE "$tz"
            ;;
    esac
}

keymap() {
    echo -e "\n── Keyboard Layout ───────────────────────────"
    options=(us by ca cf cz de dk es et fa fi fr gr hu il it lt lv mk nl no pl ro ru sg ua uk)
    select_option $? 4 "${options[@]}"
    set_option KEYMAP "${options[$?]}"
    echo "Keymap set to: ${options[$?]}"
}

installtype() {
    echo -e "\n── Installation Type ─────────────────────────"
    echo "FULL    — Complete desktop with apps, themes, gaming, and virtualization tools."
    echo "MINIMAL — Core KDE desktop and essential utilities only."
    options=(FULL MINIMAL)
    select_option $? 2 "${options[@]}"
    set_option INSTALL_TYPE "${options[$?]}"
}

ham_radio() {
    echo -e "\n── Ham Radio Software ────────────────────────"
    echo "Install ham radio software?"
    echo "(WSJT-X Improved, JS8Call Improved, CHIRP, Direwolf, Fldigi, Hamlib, Pat/Winlink)"
    options=("Yes" "No")
    select_option $? 1 "${options[@]}"
    case "${options[$?]}" in
        Yes) set_option HAM_RADIO "YES" ;;
        No)  set_option HAM_RADIO "NO" ;;
    esac
}

use_gps() {
    echo -e "\n── GPS Support ───────────────────────────────"
    echo "Install GPS support? (gpsd, chrony with GPS SHM, udev rules)"
    options=("Yes" "No")
    select_option $? 1 "${options[@]}"
    case "${options[$?]}" in
        Yes) set_option USE_GPS "YES" ;;
        No)  set_option USE_GPS "NO" ;;
    esac
}

# ─── Run ──────────────────────────────────────────────────────────────────────
background_checks
clear; logo; userinfo
clear; logo; diskpart
clear; logo; timezone
clear; logo; keymap
clear; logo; installtype
clear; logo; ham_radio
source "$CONFIG_FILE"
if [[ "$HAM_RADIO" == "YES" ]]; then
    clear; logo; use_gps
fi

echo -e "\n── Summary ───────────────────────────────────"
source "$CONFIG_FILE"
echo "  Username  : $USERNAME"
echo "  Hostname  : $NAME_OF_MACHINE"
echo "  Disk      : $DISK"
echo "  Timezone  : $TIMEZONE"
echo "  Keymap    : $KEYMAP"
echo "  Install   : $INSTALL_TYPE"
echo "  Ham Radio : $HAM_RADIO"
echo "  GPS       : ${USE_GPS:-NO}"
echo -e "─────────────────────────────────────────────\n"
