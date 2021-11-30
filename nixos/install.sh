#!/bin/bash

# Nix Install
# Replace a running system with nixos
# mal@sec.gd
# EUPL-1.2

# Instructions:
#  If you're not me, update the iso/flake below
#  Update the ISO link in the script or manually transfer it to the vps' ~/
#  $ curl https://github.com/half-duplex/vps-scripts/raw/main/install.sh | sudo bash
#  Wait (watch `journalctl -f` if you like, but it'll probably print secrets)

iso_url="https://objectstorage.ca-toronto-1.oraclecloud.com/p/ggJUW4nxP230gCMstJaHe2okXOH90fntwk-m2y1cEusmWwAUIbKHf_sOLc37Ph4D/n/yzmxptpvbzez/b/images/o/nixos-21.11pre330734.5cb226a06c4-aarch64-linux.iso"
flakesource="https://github.com/half-duplex/nixos-config.git?ref=main"

###

target="/mnt" # nixos-install needs another flag if you change this
infofile="/tmp/info"

###

set -euo pipefail
#set -x

choose_disk() {
    # Grab the first disk we see and assume it's right
    echo "/dev/"$(lsblk -ln | grep disk | cut -d' ' -f1 | head -n1)
}

scare() {
    echo -e "THIS SCRIPT WILL DESTROY THIS SYSTEM.\n" \
        "If you do not intend to permanently erase all attached storage" \
        "devices, press Ctrl+c NOW"
    sleep 5
}

get_iso() {
    # Skip if manually loaded
    [ ! -f *.iso ] || return 0

    echo "Fetching ISO..."
    wget "$iso_url"
}

clean_procs() {
    # can't be relying on systemd-resolved
    echo "nameserver 8.8.8.8" >/etc/resolv.conf
    systemctl list-units --state=running | grep running | awk '{print $1}' | \
        grep -vE '^(.*\.(scope|target|mount)|dbus\..*|(ssh)\.service)$' | \
        xargs -r systemctl stop
}

write_iso() {
    mount -o remount,ro /boot/efi
    mount -o remount,ro /

    echo "Writing iso..."
    iso="$(ls *.iso | tail -n1)"
    dd if="$iso" of="$disk" bs=4M conv=fsync status=progress

    # reboot with extreme prejudice
    echo b >/proc/sysrq-trigger
}


disk="$(choose_disk)"
echo "Installing to $disk"

scare
get_iso
clean_procs
write_iso "$disk"
