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

## ServerKing SSH bootstrap

The provider LoadBalancer currently stalls the native macOS OpenSSH socket before the SSH banner. Routing SSH through `nc` works reliably.

Before reinstalling, install the dedicated key into the existing VM once:

```sh
ssh-copy-id -o 'ProxyCommand=nc %h %p' \
  -i ~/.ssh/id_ed25519_nixos_minimal.pub nixos-minimal
```

Enter the current VM root password when prompted, then verify:

```sh
ssh -o 'ProxyCommand=nc %h %p' -o BatchMode=yes nixos-minimal 'echo KEY_OK'
```

## Reinstall

From the MacBook with Nix installed:

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake github:drunkod/nixos-serverking-vm#nixos-minimal \
  -i ~/.ssh/id_ed25519_nixos_minimal \
  --ssh-option 'ProxyCommand=nc %h %p' \
  --target-host nixos-minimal
```

**Warning:** this destroys and recreates `/dev/vda`.
