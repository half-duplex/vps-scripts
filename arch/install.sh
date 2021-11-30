#!/bin/bash -ex

# Arch Installer for VPSes
# Sets up some stuff including FDE with remote unlock
# mal <mal@sec.gd>
# EUPL-1.2

# Instructions:
#  Edit the config below
#  Create a VPS (tested with vultr only - https://sec.gd/ref/vultr pls)
#  Get to console
#  # curl https://sec.gd/ai | bash

hostname="nova.sec.gd"
searchdomain="sec.gd"
username="myusername"
temppass="ctrl-alt-destroy" # Not used for signin, only sudo. Change on first signin.
locale="en_US.UTF-8"
packages=""
keys="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKEmS7fFrQlGbF0Kbhj+hZtThT0GwWh3smpQc6MaCZVD me@luca"
keys="$keys\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDAVo8djwW1GJ7WY/3RVUZIz9dxfFpfpwx9mePXhZenuq3LLiZxBqbV6k94GS02h3bU9Bo9wVTkMT5nIMRk4NMBkmIAZ+/IYvuOl0fIdjRz+GjIzR6XJry4cfFCcA8EkLRC3KLJT2OJh1pio7CfGlTUEHaoJOVN5xjosGtE9ot9DxX82y5ZNngRxB/jhS1bR4GF1PEVCUqHsB+nj7dENqq0DbUMuv4UuxgIvP3Bc0/ABtOSVNWyFdCGVxFWk59xpGjpcB3d/hoqwe97ywkaLLXJboxawnsnaCeNVmhggKcOGmLlZSzkqRmViV7w148pkBCCGZoDfvHTL+YjpK/7VsOT me@luca"
netmask="255.255.254.0"
netmask_cidr="23"
mypackages=""

# Configure if needed

mirror='http://mirrors.rit.edu/archlinux/$repo/os/$arch'
bootsize="100M"
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

packages="$packages linux-hardened base base-devel yajl mkinitcpio-nfs-utils dropbear vim sudo grub-bios wget ntp openssh"
packages="$packages rxvt-unicode-terminfo rsync bridge-utils net-tools dnsutils htop strace lsof git mtr whois"
packages="$packages nmap tmux expac" # expac for cower

# Prep live ssh signin
usermod -L -s /bin/bash root
install -d -m 700 -o root -g root /root/.ssh
echo -e "$keys" >/root/.ssh/authorized_keys

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

# Set live mirror
echo "Server = $mirror" >/etc/pacman.d/mirrorlist

# Prepare for installation
pacman-key --populate
#pacman -Sy reflector --noconfirm
#reflector -c "United States" -p https -p http -f 10 -a 5 --save /etc/pacman.d/mirrorlist

# Install time
pacstrap $target $packages
arch-chroot $target pacman -R linux --noconfirm
rm $target/boot/initramfs-linux-hardened-fallback.img

# Locale
sed -i $target/etc/locale.gen -e "s/#$locale/$locale/"
echo "LANG=$locale" >$target/etc/locale.conf
arch-chroot $target locale-gen

# Time zone
ln -fs /usr/share/zoneinfo/UTC $target/etc/localtime

# Hostname
echo "$hostname" >$target/etc/hostname
sed -i $target/etc/hosts -e "s/localhost$/localhost $hostname/g"

# Sudo
sed -i $target/etc/sudoers -e "s/^# \%sudo.ALL/\%sudo ALL/"
arch-chroot $target groupadd sudo -r # -r for system group

# User account
arch-chroot $target useradd -U -s /bin/bash -m -G wheel,sudo $username
echo -e "$temppass\n$temppass" | arch-chroot $target passwd $username
arch-chroot $target usermod -L root

# Set up SSH
sed -re 's/^#?(PasswordAuthentication) .*$/\1 no/' -i $target/etc/ssh/sshd_config
sed -re 's/^#?(HostKey \/etc\/ssh\/ssh_host_(rsa|ed25519)_key)$/\1_nodropbear/' -i $target/etc/ssh/sshd_config
echo 'HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com,ssh-rsa-cert-v01@openssh.com,ssh-ed25519,ssh-rsa' >>$target/etc/ssh/sshd_config
arch-chroot $target systemctl enable sshd
install -D -m 700 -o 1000 -g 1000 <(echo -e "$keys") $target/home/$username/.ssh/authorized_keys

# Generate SSH keys
ssh-keygen -f $target/etc/ssh/ssh_host_ed25519_key_nodropbear -N '' -t ed25519 -C "root@$hostname"
ssh-keygen -f $target/etc/ssh/ssh_host_rsa_key_nodropbear -N '' -t rsa -b 4096 -C "root@$hostname"
sshfp_ed="`ssh-keygen -l -f $target/etc/ssh/ssh_host_ed25519_key_nodropbear.pub`"
sshfp_rsa="`ssh-keygen -l -f $target/etc/ssh/ssh_host_rsa_key_nodropbear.pub`"

function chroot-yaourt (){
    mkdir $target/aur
    curl "https://aur.archlinux.org/cgit/aur.git/snapshot/${1}.tar.gz" | tar zxv -C $target/aur/
    chmod -R a+rwx $target/aur
    arch-chroot $target sudo -u $username bash -c 'cd /aur/*;makepkg'
    arch-chroot $target find /aur -name '*.tar.xz' -exec pacman --noconfirm -U {} \;
    rm -r $target/aur
}

# Install AUR stuff
arch-chroot $target sudo -u $username gpg2 --keyserver pgp.mit.edu --recv-keys 487EACC08557AD082088DABA1EB2638FF56C0C53
chroot-yaourt cower
chroot-yaourt pacaur
chroot-yaourt mkinitcpio-netconf
chroot-yaourt mkinitcpio-dropbear
chroot-yaourt mkinitcpio-utils

# Disable fallback initrd
sed -re "s/(PRESETS=\('default')(.*)/\1) #/" -i $target/etc/mkinitcpio.d/linux-hardened.preset

# Set up dropbear
mkdir $target/etc/dropbear
echo -e "$keys" >$target/etc/dropbear/root_key
sed -re 's/^(HOOKS=\(.*) (filesystems.*)$/\1 net dropbear encryptssh \2/' -i $target/etc/mkinitcpio.conf
# I trust openssh's key gen more than dropbear's
ssh-keygen -f $target/etc/ssh/ssh_host_rsa_key -N '' -t rsa -b 4096 -C "root@$hostname"
# Regen initrd w/ dropbear and keys
arch-chroot $target mkinitcpio -p linux-hardened
dbfp="`ssh-keygen -l -f $target/etc/ssh/ssh_host_rsa_key`"

# Grub config
arch-chroot $target grub-install $targetdev
ip="`ip -4 a show dev $interface | grep inet | sed -re 's/.*inet ([^/ ]+).*/\1/'`"
gateway="`ip -4 r | grep default | cut -d' ' -f3`"
# Use eth0 here, not nice interface name, because this is before udev runs
cat >$target/boot/grub/grub.cfg <<EOF
set timeout=0
menuentry "primary" {
    linux /vmlinuz-linux-hardened root=UUID=`getuuid /dev/mapper/root` cryptdevice=UUID=`getuuid ${targetdev}2`:root:allow-discards rootflags=noatime,discard rw quiet init=/usr/lib/systemd/systemd ip=$ip::$gateway:$netmask::eth0:none
    initrd /initramfs-linux-hardened.img
}
EOF

# fstab
cat >$target/etc/fstab <<EOF
# ${targetdev}1 LABEL=boot
UUID=`getuuid ${targetdev}1`    /boot   ext4    rw,noatime,data=ordered    0 2
EOF

# Networking
arch-chroot $target systemctl enable systemd-networkd systemd-resolved
ln -fs /run/systemd/resolve/resolv.conf $target/etc/resolv.conf
ip6="`ip -6 a show dev $interface scope global | grep inet6 | sed -re 's/.*inet6 ([^/ ]+).*/\1/'`"
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

[Address]
Address=$ip6/64
EOF



umount "$target/boot"
umount /dev/mapper/root
cryptsetup close root
sync

# Gen livecd ssh host keys
[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -f /etc/ssh/ssh_host_ed25519_key -N '' -t ed25519
[ -f /etc/ssh/ssh_host_rsa_key ] || ssh-keygen -f /etc/ssh/ssh_host_rsa_key -N '' -t rsa -b 4096
systemctl start sshd

echo "FDE PASSPHRASE WRITTEN TO /tmp/info"
echo "FDE PASSPHRASE: $fdepassphrase" >/tmp/info # Don't show sensitive info to VNC
echo "Dropbear key FP: $dbfp" | tee --append /tmp/info
echo -e "Regular key FPs:\n$sshfp_ed\n$sshfp_rsa" | tee --append /tmp/info

echo "SSH running, grab the file"
echo "LiveCD host keys:"
for x in dsa rsa ecdsa ed25519 ; do
    ssh-keygen -l -f /etc/ssh/ssh_host_${x}_key.pub
done

echo "Done"
