# Pins a newer Go 1.27 patch release than nixpkgs has. A GoModel release can
# need a Go patch release before that release reaches nixpkgs.
# overlays/go/update.sh writes sources.json. If sources.json is empty ({}),
# or if nixpkgs has the same or a newer release, this overlay changes nothing.
# flake.nix applies this overlay to gomodel only, not to the whole package set.
final: prev:
let
  inherit (prev) lib;
  sources = lib.importJSON ./sources.json;
in
{
  # The attribute is always set. A condition on the attribute names would
  # force prev.go_1_27 too early and cause infinite recursion.
  go_1_27 =
    if sources ? version && lib.versionOlder prev.go_1_27.version sources.version then
      prev.go_1_27.overrideAttrs {
        inherit (sources) version;
        src = final.fetchurl {
          url = "https://go.dev/dl/go${sources.version}.src.tar.gz";
          inherit (sources) hash;
        };
      }
    else
      prev.go_1_27;
}
