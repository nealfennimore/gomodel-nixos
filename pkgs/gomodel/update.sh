#!/usr/bin/env bash
# Bump pkgs/gomodel/sources.json to the latest (or a given) GoModel release.
# Needs network access, nix, go, jq and prefetch-npm-deps (all in the dev
# shell). Afterwards, run `git diff sources.json` and `nix build .#gomodel`.
#
#   ./update.sh            # latest release
#   ./update.sh 0.1.103    # a specific version
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export NIX_CONFIG="${NIX_CONFIG:-}
experimental-features = nix-command flakes"

REPO="ENTERPILOT/GoModel"
VERSION="${1:-$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | jq -r .tag_name)}"
VERSION="${VERSION#v}"

echo "Prefetching GoModel v$VERSION ..." >&2
prefetch=$(nix flake prefetch --json "github:$REPO/v$VERSION")
hash=$(jq -r .hash <<<"$prefetch")
rev=$(jq -r .locked.rev <<<"$prefetch")
srcPath=$(jq -r .storePath <<<"$prefetch")
date=$(date -u -d "@$(jq -r .locked.lastModified <<<"$prefetch")" +%Y-%m-%dT%H:%M:%SZ)

echo "Computing npmDepsHash ..." >&2
npmDepsHash=$(prefetch-npm-deps "$srcPath/web/dashboard/package-lock.json")

echo "Computing vendorHash ..." >&2
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
cp -r "$srcPath" "$work/src"
chmod -R u+w "$work/src"
goVersion=$(sed -n 's/^go \([0-9.]*\)$/\1/p' "$work/src/go.mod")
(
  cd "$work/src"
  export GOPATH="$work/gopath" GOMODCACHE="$work/gopath/pkg/mod" GOCACHE="$work/gocache"
  export GOTOOLCHAIN="go$goVersion" GOFLAGS=-mod=mod
  go mod vendor
)
vendorHash=$(nix hash path "$work/src/vendor")

jq -n \
  --arg version "$VERSION" --arg rev "$rev" --arg date "$date" \
  --arg hash "$hash" --arg vendorHash "$vendorHash" --arg npmDepsHash "$npmDepsHash" \
  '{$version, $rev, $date, $hash, $vendorHash, $npmDepsHash}' >sources.json

echo "Updated sources.json -> $VERSION (go.mod requires Go $goVersion)" >&2
if ! grep -q "buildGo$(echo "$goVersion" | cut -d. -f1,2 | tr -d .)Module" package.nix; then
  echo "WARNING: package.nix does not use the Go $goVersion builder. Update buildGo*Module and go_*." >&2
fi
