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
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        claudeCodeOverlay = final: prev: {
          claude-code = final.callPackage ./overlays/claude/overlay.nix { };
        };
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ claudeCodeOverlay ];
        };
        packages = [
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
          allowedDomains = box.agentDomains // {
            "crates.io" = "*";
            "index.crates.io" = "*";
            "static.crates.io" = "*";
            "enterpilot.io" = "*";
          };
        };
      in
      {
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
