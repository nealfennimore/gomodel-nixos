#!/usr/bin/env bash
# Pin Go in overlays/go/sources.json when GoModel needs a newer Go 1.27 patch
# release than nixpkgs has. If nixpkgs has the release, the script clears the
# pin. Needs network access, nix and jq.
#
#   ./update.sh           # the Go version from the go.mod of the packaged GoModel
#   ./update.sh 1.27.4    # a specific Go version
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export NIX_CONFIG="${NIX_CONFIG:-}
experimental-features = nix-command flakes"

if [ $# -ge 1 ]; then
  goVersion="$1"
else
  src=$(nix build --no-link --print-out-paths ../..#gomodel.src)
  goVersion=$(sed -n 's/^go \([0-9.]*\)$/\1/p' "$src/go.mod")
fi

nixpkgsGo=$(nix eval --raw --inputs-from ../.. nixpkgs#go_1_27.version)
minor() { cut -d. -f1,2 <<<"$1"; }

if [ "$(minor "$goVersion")" != "$(minor "$nixpkgsGo")" ]; then
  echo "WARNING: GoModel needs Go $goVersion, but this overlay overrides go_1_27 ($nixpkgsGo)." >&2
  echo "WARNING: Change buildGo*Module and go_* in pkgs/gomodel/package.nix and in overlay.nix." >&2
  exit 0
fi

if [ "$(printf '%s\n%s\n' "$nixpkgsGo" "$goVersion" | sort -V | tail -n1)" = "$nixpkgsGo" ]; then
  echo "nixpkgs has Go $nixpkgsGo. GoModel needs Go $goVersion. Clearing the pin." >&2
  echo '{}' >sources.json
  exit 0
fi

if [ "$(jq -r '.version // empty' sources.json 2>/dev/null)" = "$goVersion" ]; then
  echo "Go $goVersion is already pinned." >&2
  exit 0
fi

echo "nixpkgs has Go $nixpkgsGo. Pinning Go $goVersion ..." >&2
hash=$(nix store prefetch-file --json "https://go.dev/dl/go$goVersion.src.tar.gz" | jq -r .hash)
jq -n --arg version "$goVersion" --arg hash "$hash" '{$version, $hash}' >sources.json
echo "Updated sources.json -> Go $goVersion" >&2
