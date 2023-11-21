#!/bin/bash
set -euo pipefail

# Lift an existing Ubuntu install to tmpfs and use it to install NixOS to disk.
# This isn't how I do it anymore, because I'd rather format the disk with a
# current kernel instead of the one the VPS host deploys.
# E.g. This does not run on Ubuntu 20.04 because its zfs is too old for zstd.

flakesource="https://github.com/half-duplex/nixos-configs.git?ref=main"
username="mal"
temppass="ctrl-alt-destroy" # only for sudo. change immediately.

target="/target"
infofile="/tmp/info"

scare() {
    echo -e "THIS SCRIPT WILL DESTROY THIS SYSTEM.\n" \
        "If you do not intend to permanently erase all attached storage" \
        "devices, press Ctrl+c NOW"
    sleep 1
}

prepare() {
    apt update
    apt upgrade -y
    apt install gnupg2 zfsutils-linux
}

clean_disk() {
    apt purge -y snapd linux-oracle*
    dpkg --get-selections linux-modules-extra-* | \
        grep -qs install && apt purge -y linux-modules-extra-*
    oldkernels=$(dpkg --get-selections | grep -E '^linux-image-[0-9]' | sort -h | head -n -1 | cut -f1)
    for oldkernel in $oldkernels ; do
        okver=${oldkernel##linux-image-}
        echo $oldkernel \
            linux-image-unsigned-$okver \
            linux-modules-$okver \
            linux-modules-extra-$okver
    done | xargs -r apt purge -y
    apt autoremove --purge -y
    rm -rf /var/log/* /var/lib/apt/lists/* /var/cache/*
}

clean_procs() {
    echo "nameserver 8.8.8.8" >/etc/resolv.conf
    systemctl list-units --state=running | grep running | awk '{print $1}' | \
        grep -vE '^(.*\.(scope|target|mount)|dbus\..*|(ssh)\.service)$' | \
        xargs -r systemctl stop
}

setup_pivot() {
    echo "Preparing pivot..."
    memkb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    memfreekb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    diskkb=$(df -k / | tail -n1 | awk '{print $3}')

    if [ "$memfreekb" -lt "$diskkb" ] ; then
        echo -e "You have less free ram than used space on / !\n" \
            "A higher-effort version of this script could make this work," \
            "but I cannot.\nYour largest packages:"
        dpkg-query -Wf '${Installed-Size}\t${Package}\n' | sort -nr | head -n10
        exit 1
    fi

    if mount | grep -qs ' /new_root ' ; then
        echo "Warning: Re-using new_root tmpfs"
    else
        mkdir -p /new_root
        mount -t tmpfs -o size="${memkb}K" tmpfs /new_root
    fi
}

copy_old() {
    echo "Copying system to ram..."
    if grep -sq ' /tmp ' /etc/mtab ; then
        echo "/tmp is a mount! Add it to two places in copy_old!"
        exit 1
    fi
    rsync -axSHA --info=progress2 / /new_root/ \
        --exclude=/{new_root,proc,dev,run,sys,boot}/"*"
    for x in sys proc dev dev/pts run ; do
        mkdir -p /new_root/$x
        mount -o bind /$x /new_root/$x
    done
}

pivot() {
    echo "Performing pivot..."
    cd /new_root
    mkdir -p old_root
    mount --make-rprivate /
    pivot_root . old_root
    systemctl daemon-reexec
    systemctl list-units --state=running | grep running | awk '{print $1}' | \
        grep -vE '^(.*\.(scope|target|mount|socket)|dbus\.service)$' | \
        xargs -r systemctl restart
    killall dbus-daemon # dbus.service has ExecStop=/bin/true...

    # change hostname for confusion avoidance
    oldhost="$(hostname)"
    newhost="ramdisk"
    echo "127.0.1.2 $newhost" >>/etc/hosts
    hostname $newhost

    echo "Pivot started. Reconnect your SSH session and run stage 2."
}

finish_pivot() {
    grep -sq /old_root /etc/mtab || return 0
    grep -sq /old_root/proc/sys/fs/binfmt_misc /etc/mtab && \
        umount -f /old_root/proc/sys/fs/binfmt_misc # idk. locks up w/o -f
    for x in `seq 5` ; do
        grep '/old_root/' /etc/mtab | cut -d' ' -f2 | xargs -r umount || true
    done
    # sigh, systemd... -l is okayish here since these are devfs/tmpfs
    umount -l /old_root/{dev,run}
    umount /old_root
    if grep -sqE '^/dev/' /etc/mtab ; then
        echo "Real storage may still be mounted!"
        exit 1
    fi

}

install_nix() {
    nixinstaller="https://nixos.org/nix/install"
    realurl="$(curl -w "%{url_effective}\n" -I -L -s -S $nixinstaller -o /dev/null)"
    curl -o install-nix.sh "$realurl"
    curl -o install-nix.sh.asc "${realurl}.asc"
    nixkey=B541D55301270E0BCF15CA5D8170B4726D7198DE
    gpg2 --list-key $nixkey >/dev/null || \
        gpg2 --keyserver pgp.mit.edu --recv-keys $nixkey
    gpgv --keyring ~/.gnupg/pubring.kbx install-nix.sh.asc install-nix.sh

    build=nixbld
    getent group $build >/dev/null || groupadd -r $build
    getent passwd ${build}1 >/dev/null || useradd -r -G $build -s /bin/bash ${build}1
    #usermod -a -G $build $build

    sh install-nix.sh
}

scare_more() {
    delay=1
    echo -e "ABOUT TO ERASE EVERYTHING.\n" \
        "You have $delay seconds to press Ctrl+c"
    sleep $delay
}

choose_disk() {
    echo "/dev/"$(lsblk -ln | grep disk | cut -d' ' -f1)
}

setup_disk() {
    # partition and format disk
    disk="$1"
    echo "Setting up $disk"
    parted="parted -ms -a optimal $disk"
    $parted mklabel gpt
    $parted mkpart "_esp" fat32 0% 256MB
    $parted set 1 esp on
    mkfs.fat -F32 -n ESP "${disk}1"
    $parted mkpart "_luks" ext4 256MB 100%
    fdepassphrase="`tr -cd '[:alnum:]' < /dev/urandom | fold -w32 | head -n1`"
    echo "FDE PASSPHRASE: $fdepassphrase" >>"$infofile"
    echo -n "$fdepassphrase" | cryptsetup luksFormat --sector-size 4096 ${disk}2 -
    cscmd="cryptsetup --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue --persistent open ${disk}2 cryptroot -"
    echo -n "$fdepassphrase" | nix-shell -p cryptsetup --run "$cscmd"
    zpool create \
        -o ashift=12 \
        -o autotrim=on \
        -O compression=zstd-1 \
        -O acltype=posixacl \
        -O xattr=sa \
        -O atime=off \
        -O mountpoint=legacy \
        tank /dev/mapper/cryptroot
    zfs create tank/persist
    zfs create tank/nix
}

setup_mount() {
    # mounts
    disk="$1"
    rm -rf "$target"
    mkdir "$target"
    mount -t tmpfs tmpfs "$target"
    mkdir -p "$target"/{boot,nix,persist}
    mount "${disk}1" "$target/boot"
    mount -t zfs tank/persist "$target/persist"
    mount -t zfs tank/nix "$target/nix"
}

setup_os() {
    hostname="$1"
    flakesource="$2"

    # install
    instcmd="nixos-install --root "$target" --no-root-passwd --flake \"git+$flakesource#$hostname\""
    nix-shell -p nixFlakes --run "$instcmd"
}

personalize() {
    hostname="$1"
    # user password
    mkdir -p "$target/persist/shadow"
    chmod go= "$target/persist/shadow" -R
    userpassword="`tr -cd '[:alnum:]' < /dev/urandom | fold -w16 | head -n1`"
    echo "$userpassword" | openssl passwd -6 -stdin > "$target/persist/shadow/$username"
    ls -la "$target/persist/shadow"

    # ssh host keys
    ssh-keygen -f "$target/persist/etc/ssh/ssh_host_rsa_key" -N '' -t rsa -b 4096 -C "root@$hostname"
    ssh-keygen -f "$target/persist/etc/ssh/ssh_host_ed25519_key" -N '' -t ed25519 -C "root@$hostname"
    ssh-keygen -f "$target/persist/etc/ssh/ssh_host_ed25519_key_initrd" -N '' -t ed25519 -C "root@$hostname"
    echo "SSH host key fingerprints:" >>"$infofile"
    echo "- rsa:" $(ssh-keygen -l -f "$target/persist/etc/ssh/ssh_host_rsa_key") >>"$infofile"
    echo "- ed25519:" $(ssh-keygen -l -f "$target/persist/etc/ssh/ssh_host_ed25519_key") >>"$infofile"
    echo "- initrd ed25519:" $(ssh-keygen -l -f "$target/persist/etc/ssh/ssh_host_ed25519_key_initrd") >>"$infofile"
}

bye() {
    zpool export tank
    nix-shell -p cryptsetup --run "cryptsetup close cryptroot"
    umount "$target/boot"
    umount "$target"

    curl https://sec.gd/escrow.php -F "key=V4SoT2otC0RctNo4YyYUdTsy73AQrtYZ" -F "type=info" -F "file=@/tmp/info"

    echo "All done, reboot me!"
}


if [ "$#" -lt 1 ] ; then
    echo -e "Usage: None. Do not use this script."
    exit 1
fi

if [ "$1" == "1" ] ; then
    if grep -sq '^tmpfs / ' /etc/mtab ; then
        echo "https://youtu.be/OHQh-xtWcAw"
        exit 1
    fi
    scare
    echo -n >"$infofile"
    prepare
    clean_disk
    clean_procs
    setup_pivot
    copy_old
    pivot
    exit 0
fi

hostname="$1"

finish_pivot
install_nix
. /root/.nix-profile/etc/profile.d/nix.sh
scare_more
disk=$(choose_disk)
setup_disk $disk
setup_mount $disk
setup_os $hostname $flakesource
personalize $hostname
bye
