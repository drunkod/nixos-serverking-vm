{ modulesPath, ... }:
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  networking.hostName = "nixos-minimal";
  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network.enable = true;
  systemd.network.networks."10-wan" = {
    matchConfig.Name = "en*";
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
  };

  boot.loader.systemd-boot.enable = false;
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  boot.loader.efi.canTouchEfiVariables = false;

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOx0gh97TL223tNL4ofhucMsnxs06/ID/ZRaNv82A1vM nixos-minimal@77.91.91.46"
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  system.stateVersion = "26.05";
}
