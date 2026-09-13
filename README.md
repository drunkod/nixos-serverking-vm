# nixos-serverking-vm

Draft reproducible NixOS configuration for the ServerKing/Cozystack VM `nixos-minimal`.

## Target

- x86_64 Linux VM
- Disk: `/dev/vda`
- GPT + 512 MiB EFI System Partition + ext4 root
- NixOS 26.05
- QEMU/KVM guest profile
- DHCP via systemd-networkd
- OpenSSH on TCP/22
- Root SSH is public-key only; password and keyboard-interactive SSH are disabled

## Reinstall

From the MacBook with Nix installed:

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake github:drunkod/nixos-serverking-vm#nixos-minimal \
  -i ~/.ssh/id_ed25519_nixos_minimal \
  --target-host nixos-minimal
```

**Warning:** this destroys and recreates `/dev/vda`.
