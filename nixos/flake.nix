# Build:
#  Change the ssh key, hostname, username, temppass, flakesource, drop-box, etc below
#  $ nix build . --system aarch64-linux
#
# Test:
#  $ qemu-img convert -f raw -O qcow2 "$iso" "$qcow"
#  $ qemu-img resize "$qcow" 10G
#  $ dd if=/dev/zero of=flash0.img bs=1M count=64
#  $ dd if=/usr/share/edk2-armvirt/aarch64/QEMU_EFI.fd of=flash0.img conv=notrunc
#  $ dd if=/dev/zero of=flash1.img bs=1M count=64
#  $ qemu-system-aarch64 -cpu max -M virt -smp 2 -m 4096 -drive if=virtio,format=qcow2,file="$qcow" -drive if=pflash,format=raw,file=flash0.img,readonly=on -drive if=pflash,format=raw,file=flash1.img -machine virtualization=true -machine virt,gic-version=3 -serial stdio

{
  inputs.nixpkgs.url = "nixpkgs/nixos-21.11";
  outputs = { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib outPath;
      system = "aarch64-linux";
      modules = [
        "${outPath}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
        ( { pkgs, config, ... }: {
          boot.kernelParams = [ "copytoram" ];

          nix = {
            package = pkgs.nixFlakes;
            extraOptions = "experimental-features = nix-command flakes";
          };
          environment.systemPackages = with pkgs; [ openssl git ];

          users.users.root.openssh.authorizedKeys.keys = [
            # Only used for the ISO
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILEIHPFhrmKl7KPP9MLC7EyXPWW/9OShgxrVd7ioKdNO mal@luca:oraclecloud"
          ];
          systemd.services.sshd.wantedBy = pkgs.lib.mkForce [ "multi-user.target" ];
          systemd.services.install = {
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" "polkit.service" ];
            path = [ "/run/current-system/sw/" ];
            environment = config.nix.envVars // {
              inherit (config.environment.sessionVariables) NIX_PATH;
              HOME = "/root";
            };
            serviceConfig.Type = "oneshot";
            script = ''
              set -eux

              # Configure me
              hostname="oc"
              username="mal"
              temppass="ctrl-alt-destroy"
              flakesource="https://github.com/half-duplex/nixos-config.git?ref=main"
              infofile="/tmp/info"

              target="/mnt" # changing requires a nix-build flag
              disk="/dev/"$(lsblk -ln | grep disk | cut -d' ' -f1 | head -n1)

              # partition
              echo "Setting up $disk"
              parted="parted -ms -a optimal $disk"
              $parted mklabel gpt
              $parted mkpart "_esp" fat32 0% 256MB
              $parted set 1 esp on
              $parted mkpart "_luks" ext4 256MB 100%

              # format
              mkfs.fat -F32 -n ESP "$disk"1
              fdepassphrase="$(tr -cd '[:alnum:]' < /dev/urandom | dd bs=32 count=1)"
              echo "FDE PASSPHRASE: $fdepassphrase" >>"$infofile"
              echo -n "$fdepassphrase" | cryptsetup luksFormat --sector-size 4096 "$disk"2 -
              echo -n "$fdepassphrase" | cryptsetup \
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
              nixos-install --no-root-passwd --flake "git+$flakesource#$hostname"

              # home dir
              mkdir -p "$target/persist/home/$username"

              # user password
              mkdir -p "$target/persist/shadow"
              echo "$temppass" | openssl passwd -6 -stdin > "$target/persist/shadow/$username"
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
            '';
          };
        })
      ];
    in
    {
      defaultPackage.${system} = (lib.nixosSystem { inherit modules system; }).config.system.build.isoImage;
    };
}
