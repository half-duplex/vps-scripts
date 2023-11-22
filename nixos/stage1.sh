#!/bin/bash
set -euo pipefail
set -x

iso_url="${ISO:-https://sec.gd/files/f/nixos-auto-aarch64.iso}"

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
