#!/bin/bash
set -euo pipefail
set -x

# Configure this section before building the iso flake
flakesource="https://github.com/half-duplex/nixos-config.git?ref=main"
# hostname must match your flake's config (nixos-install --flake ...#$hostname)
hostname="oc"
username="mal"

# shouldn't need to configure these
disk="/dev/"$(lsblk -ln | grep disk | cut -d' ' -f1 | head -n1)
target="/mnt"  # others untested
infofile="/tmp/info"
set +o pipefail
userpass="$(tr -cd '[:alnum:]' < /dev/urandom | dd bs=32 count=1)"
fdepass="$(tr -cd '[:alnum:]' < /dev/urandom | dd bs=32 count=1)"
set -o pipefail

# partition
echo "Setting up $disk"
parted="parted -ms -a optimal $disk"
$parted mklabel gpt
$parted mkpart "_esp" fat32 0% 256MB
$parted set 1 esp on
$parted mkpart "_luks" ext4 256MB 100%

# format
mkfs.fat -F32 -n ESP "$disk"1
echo "FDE passphrase: $fdepass" >>"$infofile"
echo -n "$fdepass" | cryptsetup luksFormat --sector-size 4096 "$disk"2 -
echo -n "$fdepass" | cryptsetup \
    --allow-discards \
    --perf-no_read_workqueue \
    --perf-no_write_workqueue \
    --persistent \
    open "$disk"2 cryptroot -
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

# mount
mount -t tmpfs tmpfs "$target"
mkdir -p "$target"/{boot,nix,persist}
mount "$disk"1 "$target/boot"
mount -t zfs tank/persist "$target/persist"
mount -t zfs tank/nix "$target/nix"

# install
nixos-install --no-root-passwd --root "$target" --flake "git+$flakesource#$hostname"

# home dir
mkdir -p "$target/persist/home/$username"

# user password
echo "Passphrase for $username: $userpass" >>"$infofile"
mkdir -p "$target/persist/shadow"
echo "$userpass" | openssl passwd -6 -stdin >"$target/persist/shadow/$username"
chmod go= "$target/persist/shadow" -R

# ssh host keys
ssh-keygen -f "$target/persist/etc/ssh/ssh_host_rsa_key" -N "" -t rsa -b 4096 -C "root@$hostname"
ssh-keygen -f "$target/persist/etc/ssh/ssh_host_ed25519_key" -N "" -t ed25519 -C "root@$hostname"
ssh-keygen -f "$target/persist/etc/ssh/ssh_host_ed25519_key_initrd" -N "" -t ed25519 -C "root@$hostname"
echo "SSH host key fingerprints:" >>"$infofile"
echo "- rsa:" $(ssh-keygen -l -f "$target/persist/etc/ssh/ssh_host_rsa_key") >>"$infofile"
echo "- ed25519:" $(ssh-keygen -l -f "$target/persist/etc/ssh/ssh_host_ed25519_key") >>"$infofile"
echo "- initrd ed25519:" $(ssh-keygen -l -f "$target/persist/etc/ssh/ssh_host_ed25519_key_initrd") >>"$infofile"

# unmount
zpool export tank
cryptsetup close cryptroot
umount "$target/boot"
umount "$target"

# report
curl https://sec.gd/escrow.php \
    -F "key=V4SoT2otC0RctNo4YyYUdTsy73AQrtYZ" \
    -F "type=info" \
    -F "file=@$infofile" || true
echo "Passphrases and info in $infofile and (probably) sent to drop box."

echo "All done, rebooting!"
sleep 5
reboot
