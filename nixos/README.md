# vps-scripts — nixos

Replaces a running Linux install with NixOS. Written for use with Ubuntu, may
work with other distros.

## Building
1. Install qemu-user-static, qemu-user-static-binfmt, and qemu-system-aarch64,
   then restart systemd-binfmt.service
2. Update the variables in flake.nix (SSH key) and stage2.sh to suit your needs
3. Build the iso: `nix build . --system aarch64-linux`
4. Make the iso (in `result/`) accessible over https, or plan to scp it to your
   home directory on the target system

## Installing
1. Run stage1.sh from the target, omitting ISO=... if you scp'd it.
   `curl https://github.com/half-duplex/vps-scripts/raw/main/install.sh \
       | sudo ISO="https://example.com/nixos.iso" bash`
2. Wait for the final NixOS system to come up, and grab your secrets from the
   drop box! You can watch `journalctl -f` on the running iso if you like, but
   it'll probably print secrets there.

## Local Testing of Stage 2
```bash
qemu-img convert -f raw -O qcow2 "$iso" "$qcow"
qemu-img resize "$qcow" 10G
dd if=/dev/zero of=flash0.img bs=1M count=64
dd if=/usr/share/edk2-armvirt/aarch64/QEMU_EFI.fd of=flash0.img conv=notrunc
dd if=/dev/zero of=flash1.img bs=1M count=64
qemu-system-aarch64 -cpu max -M virt -smp 2 -m 4096 \
    -drive if=virtio,format=qcow2,file="$qcow" \
    -drive if=pflash,format=raw,file=flash0.img,readonly=on \
    -drive if=pflash,format=raw,file=flash1.img \
    -machine virtualization=true -machine virt,gic-version=3 -serial mon:stdio
```
