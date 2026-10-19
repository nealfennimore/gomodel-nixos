{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      gomodelOverlay = final: prev: {
        gomodel = final.callPackage ./pkgs/gomodel/package.nix { };
        gomodel-plugins = final.gomodel.override { withPlugins = true; };
      };
    in
    {
      overlays.default = gomodelOverlay;

      # services.gomodel. The package defaults to this flake's build, so the
      # module works without the overlay.
      nixosModules.default = self.nixosModules.gomodel;
      nixosModules.gomodel =
        { lib, pkgs, ... }:
        {
          imports = [ ./nixos/module.nix ];
          services.gomodel.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.gomodel;
        };
    }
    //
      flake-utils.lib.eachSystem
        [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ]
        (
          system:
          let
            pkgs = import nixpkgs {
              inherit system;
              overlays = [ gomodelOverlay ];
            };
            packages = [
              pkgs.go
              pkgs.gnumake
              pkgs.gnutar
              pkgs.gzip
              pkgs.nodejs
              pkgs.prefetch-npm-deps
              pkgs.nix
              pkgs.nixfmt-rfc-style
              pkgs.python3
            ];
          in
          {
            packages = {
              default = pkgs.gomodel;
              inherit (pkgs) gomodel gomodel-plugins;
              gomodel-swagger = pkgs.gomodel.override { withSwagger = true; };
              gomodel-dashboard = pkgs.gomodel.dashboard;
            };

            checks = {
              inherit (pkgs) gomodel;
            }
            // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
              nixos-test = import ./nixos/tests/gomodel.nix {
                inherit pkgs;
                nixosModule = ./nixos/module.nix;
              };
            };

            formatter = pkgs.nixfmt-rfc-style;

            devShells.default = pkgs.mkShell {
              inherit packages;

              shellHook = "";
            };
          }
        );
}
