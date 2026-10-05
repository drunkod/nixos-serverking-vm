{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [
    ./common.nix
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  boot.growPartition = true;
  boot.kernelParams = [ "console=ttyS0" ];

  boot.loader.systemd-boot.enable = false;
  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.timeout = 0;

  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  networking.hostName = lib.mkDefault "nixos";

  system.build.serverkingImage = import "${modulesPath}/../lib/make-disk-image.nix" {
    inherit config lib pkgs;
    diskSize = 10240;
    bootSize = "512M";
    format = "qcow2";
    partitionTableType = "efi";
    copyChannel = false;
    name = "nixos-serverking-image";
    baseName = "nixos-serverking";
  };
}
