{ ... }:
{
  imports = [
    ./common.nix
  ];

  networking.hostName = "nixos-minimal";

  boot.loader.systemd-boot.enable = false;
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  boot.loader.efi.canTouchEfiVariables = false;

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOx0gh97TL223tNL4ofhucMsnxs06/ID/ZRaNv82A1vM nixos-minimal@77.91.91.46"
  ];
}
