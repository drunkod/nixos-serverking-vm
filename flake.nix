{
  description = "ServerKing Cozystack NixOS VM and reusable golden image";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, disko, ... }:
    let
      system = "x86_64-linux";

      installedSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          disko.nixosModules.disko
          ./disko.nix
          ./configuration.nix
        ];
      };

      imageSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./image.nix
        ];
      };
    in
    {
      nixosConfigurations.nixos-minimal = installedSystem;
      nixosConfigurations.serverking-image = imageSystem;

      packages.${system} = {
        serverking-image = imageSystem.config.system.build.serverkingImage;
        default = imageSystem.config.system.build.serverkingImage;
      };
    };
}
