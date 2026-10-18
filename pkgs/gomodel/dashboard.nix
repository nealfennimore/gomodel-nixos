# The Svelte admin dashboard. Upstream does not commit the built bundle: the
# Go binary embeds internal/admin/dashboard/static/dist, so this derivation
# builds that directory and package.nix copies it into the Go source tree.
{
  lib,
  buildNpmPackage,
  src,
  version,
  npmDepsHash,
}:

buildNpmPackage {
  pname = "gomodel-dashboard";
  inherit version src npmDepsHash;

  sourceRoot = "${src.name}/web/dashboard";

  # Upstream runs `npm ci --ignore-scripts`: no dependency needs its
  # lifecycle scripts, and the native bundler bindings ship prebuilt.
  npmRebuildFlags = [ "--ignore-scripts" ];

  # vite.config.js writes to ../../internal/admin/dashboard/static/dist.
  # Keep the output inside the source root instead.
  npmBuildFlags = [
    "--"
    "--outDir"
    "dist"
  ];

  installPhase = ''
    runHook preInstall
    cp -r dist "$out"
    runHook postInstall
  '';

  meta = {
    description = "Admin dashboard for the GoModel AI gateway";
    homepage = "https://github.com/ENTERPILOT/GoModel";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
