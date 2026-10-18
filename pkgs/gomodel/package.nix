{
  lib,
  stdenv,
  buildGo127Module,
  buildNpmPackage,
  fetchFromGitHub,
  go_1_27,
  makeWrapper,
  callPackage,
  # Build with `-tags swagger` so SWAGGER_ENABLED=true serves /swagger/index.html.
  # Upstream release binaries leave it out.
  withSwagger ? false,
  # Build with cgo so the gateway can load Go shared-object plugins
  # (upstream `make build-plugins`). The wrapper puts Go and a C compiler on
  # PATH for `gomodel plugin build`, which must use the same toolchain.
  withPlugins ? false,
}:

let
  sources = lib.importJSON ./sources.json;
  inherit (sources) version;

  src = fetchFromGitHub {
    owner = "ENTERPILOT";
    repo = "GoModel";
    tag = "v${version}";
    inherit (sources) hash;
  };

  dashboard = callPackage ./dashboard.nix {
    inherit buildNpmPackage src version;
    inherit (sources) npmDepsHash;
  };
in
buildGo127Module (finalAttrs: {
  pname = "gomodel" + lib.optionalString withPlugins "-plugins";
  inherit version src;
  inherit (sources) vendorHash;

  subPackages = [ "cmd/gomodel" ];

  env.CGO_ENABLED = if withPlugins then "1" else "0";

  tags = lib.optional withSwagger "swagger";

  ldflags = [
    "-s"
    "-w"
    "-X github.com/enterpilot/gomodel/internal/version.Version=${version}"
    "-X github.com/enterpilot/gomodel/internal/version.Commit=${sources.rev}"
    "-X github.com/enterpilot/gomodel/internal/version.Date=${sources.date}"
  ];

  nativeBuildInputs = lib.optional withPlugins makeWrapper;

  # postConfigure, not preBuild: buildGoModule copies preBuild into the
  # vendor derivation, and that derivation does not need the dashboard.
  postConfigure = ''
    dist=internal/admin/dashboard/static/dist
    rm -rf "$dist"
    cp -r ${dashboard} "$dist"
    chmod -R u+w "$dist"
  '';

  # Same package set as upstream `make test`. The default check phase only
  # tests subPackages, which here is the main package alone.
  checkPhase = ''
    runHook preCheck
    export GOFLAGS=''${GOFLAGS//-trimpath/}
    go test -p "$NIX_BUILD_CORES" ./cmd/... ./config/... ./ext/... ./internal/... ./run/...
    runHook postCheck
  '';

  # `gomodel plugin build` runs `go build -buildmode=plugin` with cgo.
  allowGoReference = withPlugins;
  postInstall = lib.optionalString withPlugins ''
    wrapProgram $out/bin/gomodel \
      --suffix PATH : ${
        lib.makeBinPath [
          go_1_27
          stdenv.cc
        ]
      } \
      --set-default GOTOOLCHAIN local
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/gomodel --version | grep -F "gomodel ${version}"
    runHook postInstallCheck
  '';

  passthru = {
    inherit dashboard;
    updateScript = ./update.sh;
  };

  meta = {
    description = "OpenAI-compatible AI gateway that routes requests to many LLM providers";
    longDescription = ''
      GoModel is a high-performance AI gateway written in Go. It exposes one
      OpenAI-compatible API in front of OpenAI, Anthropic, Gemini, Bedrock,
      Ollama and other providers, with audit logs, usage tracking, budgets,
      rate limits, response caching, guardrails, an MCP gateway and an
      embedded admin dashboard.
    '';
    homepage = "https://github.com/ENTERPILOT/GoModel";
    changelog = "https://github.com/ENTERPILOT/GoModel/releases/tag/v${version}";
    license = lib.licenses.mit;
    mainProgram = "gomodel";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
