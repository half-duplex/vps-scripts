#!/bin/bash -e

# Debian Installer for VPSes
# Sets up some stuff including FDE with remote unlock
# Run this from an ARCH livecd
# mal <mal@sec.gd>
# EUPL-1.2

# Instructions:
#  Configure the script below
#  Create a VPS (tested with vultr only - https://sec.gd/ref/vultr pls)
#  Get to console
#  If your v6 is broken, sysctl -w net.ipv6.conf.all.disable_ipv6=1
#  Run: # curl https://sec.gd/di | bash
#   Or: # wget https://sec.gd/di -O di ; bash -ex di

hostname="eris.sec.gd"
searchdomain="sec.gd"
username="mal"
temppass="ctrl-alt-destroy" # Not used for signin, only sudo. Change on first signin.
locale="en_US.UTF-8"
packages=""
keys="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKEmS7fFrQlGbF0Kbhj+hZtThT0GwWh3smpQc6MaCZVD me@luca"
keys="$keys\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDAVo8djwW1GJ7WY/3RVUZIz9dxfFpfpwx9mePXhZenuq3LLiZxBqbV6k94GS02h3bU9Bo9wVTkMT5nIMRk4NMBkmIAZ+/IYvuOl0fIdjRz+GjIzR6XJry4cfFCcA8EkLRC3KLJT2OJh1pio7CfGlTUEHaoJOVN5xjosGtE9ot9DxX82y5ZNngRxB/jhS1bR4GF1PEVCUqHsB+nj7dENqq0DbUMuv4UuxgIvP3Bc0/ABtOSVNWyFdCGVxFWk59xpGjpcB3d/hoqwe97ywkaLLXJboxawnsnaCeNVmhggKcOGmLlZSzkqRmViV7w148pkBCCGZoDfvHTL+YjpK/7VsOT me@luca"
netmask="255.255.255.0"
netmask_cidr="24"

# Configure if needed

swapsize="2G"
bootsize="128M"
target="/mnt"
fdepassphrase="`tr -cd '[:alnum:]' < /dev/urandom | fold -w32 | head -n1`"

# Get device that looks like a drive
# 9 = md*, 8,65-71,128-135 = scsi disk = sd*, 202=xvd*, 254==vd*
# https://www.kernel.org/doc/Documentation/devices.txt
targetdev="`lsblk -dnp --include 9,8,65,66,202,254 --output NAME | head -n 1`"

# Grab first interface with a public v4
interface="`ip -4 a show scope global | head -n 1 | sed -re 's/[^ ]* ([a-z0-9]+).*/\1/'`"

# Stop configuring here



function getuuid (){
    blkid $1 -o value -s UUID
}

export PATH="/sbin:/usr/sbin:/bin:/usr/bin"

#packages="$packages,tmux,less,iproute,iputils-ping,net-tools,rsync,dnsutils,iptables"
packages="$packages,linux-image-amd64,systemd,sudo,grub2,locales,iptables,iputils-ping,net-tools,kmod,dialog,apt-utils"
packages="$packages,dropbear,iptables-persistent,cryptsetup,kbd,console-setup,systemd-sysv,iproute2,python,python3"
packages="$packages,openssh-server,curl,net-tools,man-db,netcat,tcpdump,lsof,strace,bash-completion,gnupg,dbus"
packages="$packages,less,vim,nano,rsync,dnsutils,htop,mosh,tmux,git,bc,libpam-systemd"

# Linode v6 autoconf requires PE off, etc
#sysctl -w net.ipv6.conf.all.use_tempaddr=0
#sysctl -w net.ipv6.conf.all.disable_ipv6=1

# Prep live ssh signin
usermod -L -s /bin/bash root
install -d -m 700 -o root -g root /root/.ssh
echo -e "$keys" >/root/.ssh/authorized_keys
# Gen live ssh host keys
[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -f /etc/ssh/ssh_host_ed25519_key -N '' -t ed25519
[ -f /etc/ssh/ssh_host_rsa_key ] || ssh-keygen -f /etc/ssh/ssh_host_rsa_key -N '' -t rsa -b 4096
#systemctl start sshd

echo -e "\n\n\nTarget device: $targetdev"
echo "Primary interface: $interface"
echo -e "About to erase $targetdev, Ctrl-C now if that's wrong!\n"
sleep 5

# Unmount everything
echo "Attempting to unmount stuff in case you're re-running this"
umount ${targetdev}1 || true
umount /dev/mapper/root || true
cryptsetup close root || true
echo "Unmounts done"

# Partition everything
dd if=/dev/zero of=$targetdev bs=3M count=1
pa="-ms -a optimal $targetdev"
parted $pa mklabel msdos
parted $pa mkpart p ext4 0% $bootsize
parted $pa mkpart p ext4 $bootsize 100%

# Format everything
mkfs.ext4 -q -L boot ${targetdev}1
echo -n "$fdepassphrase" | cryptsetup luksFormat ${targetdev}2 -
echo -n "$fdepassphrase" | cryptsetup open ${targetdev}2 root -
mkfs.ext4 -q -L system /dev/mapper/root

# Mount everything
mount /dev/mapper/root "$target"
mkdir "$target/boot"
mount ${targetdev}1 "$target/boot"

# Set time and hwclock
ntpdate pool.ntp.org
hwclock -uw

pacman-key --populate
pacman -Sy debootstrap debian-archive-keyring --noconfirm

# Install time
time debootstrap --variant=minbase --include="$packages" stable "$target" 'https://mirror.us.leaseweb.net/debian/'

# Locale
sed -i $target/etc/locale.gen -e "s/#\s*$locale/$locale/"
echo "LANG=$locale" >$target/etc/default/locale
arch-chroot $target locale-gen

# Hostname
echo "$hostname" >$target/etc/hostname
#sed -i $target/etc/hosts -e "s/localhost$/localhost $hostname/g"
echo "127.0.0.1 $hostname localhost.localdomain localhost"  >$target/etc/hosts
echo "::1       $hostname localhost.localdomain localhost" >>$target/etc/hosts

# User account
arch-chroot $target useradd -U -s /bin/bash -m -G sudo $username
echo -e "$temppass\n$temppass" | arch-chroot $target passwd $username
arch-chroot $target usermod -L root

# Set up SSH
sed -re 's/^#?(PasswordAuthentication) .*$/\1 no/' -i $target/etc/ssh/sshd_config
echo 'HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com,ssh-rsa-cert-v01@openssh.com,ssh-ed25519,ssh-rsa' >>$target/etc/ssh/sshd_config
#arch-chroot $target systemctl enable sshd # already done? aoeu
install -d -m 700 -o 1000 -g 1000 "$target/home/$username/.ssh"
install    -m 700 -o 1000 -g 1000 <(echo -e "$keys") $target/home/$username/.ssh/authorized_keys

# Generate SSH keys
sshfp_ed="`ssh-keygen -l -N '' -C 'root@localhost' -f $target/etc/ssh/ssh_host_ed25519_key.pub`"
sshfp_rsa="`ssh-keygen -l -N '' -C 'root@localhost' -f $target/etc/ssh/ssh_host_rsa_key.pub`"

# Set up dropbear
echo -e "$keys" >$target/etc/dropbear-initramfs/authorized_keys
# I trust openssh's key gen more than dropbear's
ssh-keygen -f $target/etc/dropbear-initramfs/ssh_host_rsa_key -N '' -t rsa -b 4096 -C "root@localhost"
arch-chroot $target /usr/lib/dropbear/dropbearconvert openssh dropbear \
    /etc/dropbear-initramfs/ssh_host_rsa_key /etc/dropbear-initramfs/dropbear_rsa_host_key
dbfp="`ssh-keygen -l -f $target/etc/dropbear-initramfs/ssh_host_rsa_key`"

# swap
fallocate -l "$swapsize" "$target/swap"
chmod 600 "$target/swap"
mkswap "$target/swap"

# fstab
cat >"$target/etc/fstab" <<EOF
# ${targetdev}1 LABEL=boot
UUID=`getuuid ${targetdev}1   `    /boot   ext4    rw,noatime,data=ordered,discard    0 2
UUID=`getuuid /dev/mapper/root`    /       ext4    rw,noatime,data=ordered,discard    0 1
/swap                                        swap    swap    defaults                           0 0
EOF

# crypttab
cat >>"$target/etc/crypttab" <<EOF
root    UUID=`getuuid ${targetdev}2`    none    luks
EOF

# Regen initrd w/ dropbear and keys and fstab and crypttab
arch-chroot $target update-initramfs -u

# Grub config
arch-chroot $target grub-install $targetdev
## Use eth0 here, not nice interface name, because this is before udev runs
#cat >$target/boot/grub/grub.cfg <<EOF
#set timeout=0
#menuentry "primary" {
#    linux /vmlinuz-linux-hardened root=UUID=`getuuid /dev/mapper/root` cryptdevice=UUID=`getuuid ${targetdev}2`:root:allow-discards rootflags=noatime,discard rw quiet init=/usr/lib/systemd/systemd ip=$ip::$gateway:$netmask::eth0:none
#    initrd /initramfs-linux-hardened.img
#}
#EOF
#sed -re "s/(GRUB_CMDLINE_LINUX=\")/\1ip=dhcp cryptdevice=UUID=`getuuid ${targetdev}2`:root:allow-discards rootflags=noatime,discard rootwait /" -i "$target/etc/default/grub"
#sed -re "s/(GRUB_CMDLINE_LINUX=\")/\1rootwait /" -i "$target/etc/default/grub"
arch-chroot $target update-grub

# Networking
arch-chroot $target systemctl enable systemd-networkd systemd-resolved
ln -fs /run/systemd/resolve/resolv.conf $target/etc/resolv.conf
ip="`ip -4 a show scope global dev $interface | grep inet | sed -re 's/.*inet ([^/ ]+).*/\1/'`"
gateway="`ip -4 r | grep default | cut -d' ' -f3`"
#ip6="`ip -6 a show dev $interface scope global | grep inet6 | sed -re 's/.*inet6 ([^/ ]+).*/\1/'`"
#[ "$searchdomain" == "" ] && searchdomainline="" || searchdomainline="Domains=$searchdomain" # Needed?
cat >$target/etc/systemd/network/public.network <<EOF
[Match]
Name=$interface

[Network]
DHCP=none
DNS=8.8.8.8
DNS=8.8.4.4
DNS=2001:4860:4860::8888
DNS=2001:4860:4860::8844
Domains=$searchdomain

[Address]
Address=$ip/$netmask_cidr

[Route]
Gateway=$gateway

#[Address]
#Address=$ip6/64
EOF

echo -n >"$target/etc/motd"


umount "$target/boot"
umount /dev/mapper/root
cryptsetup close root
sync

echo "FDE PASSPHRASE: $fdepassphrase" >/tmp/info # Don't show sensitive info to VNC
echo "Dropbear key FP: $dbfp" | tee --append /tmp/info
echo -e "Regular key FPs:\n$sshfp_ed\n$sshfp_rsa" | tee --append /tmp/info

echo "Uploading"
curl https://sec.gd/escrow.php -F "key=V4SoT2otC0RctNo4YyYUdTsy73AQrtYZ" -F "type=info" -F "file=@/tmp/info"

echo "LiveCD host keys:"
for x in dsa rsa ecdsa ed25519 ; do
    pubf="/etc/ssh/ssh_host_${x}_key.pub"
    [ -f "$pubf" ] && ssh-keygen -l -f "$pubf" || true
done

echo "Done"
