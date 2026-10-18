{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agentbox.url = "github:nealfennimore/agent-sandbox";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      agentbox,
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
            claudeCodeOverlay = final: prev: {
              claude-code = final.callPackage ./overlays/claude/overlay.nix { };
            };
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
              overlays = [
                claudeCodeOverlay
                gomodelOverlay
              ];
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
            box = agentbox.lib.${system};
            claude = box.mkClaudeSandbox {
              pkg = pkgs.claude-code;
              extraPackages = [
                pkgs.ripgrep
                pkgs.jq
                pkgs.curl
              ]
              ++ packages;
              allowedHostPorts = [
                8080
              ];
              extraEnv = {
                ANTHROPIC_BASE_URL = "http://localhost:8080";
                ANTHROPIC_AUTH_TOKEN = "1";
                CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = "1";
              };
              allowedDomains = box.agentDomains // {
                "crates.io" = "*";
                "index.crates.io" = "*";
                "static.crates.io" = "*";
                "enterpilot.io" = "*";
                "proxy.golang.org" = "*";
                "sum.golang.org" = "*";
                "storage.googleapis.com" = "*";
                "registry.npmjs.org" = "*";
                "codeload.github.com" = "*";
                "objects.githubusercontent.com" = "*";
                "cache.nixos.org" = "*";
                "channels.nixos.org" = "*";
              };
            };
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
              packages = [
                claude
              ]
              ++ packages;

              shellHook = "";
            };
          }
        );
}
