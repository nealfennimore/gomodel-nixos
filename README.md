# GoModel for Nix and NixOS

This flake packages [GoModel](https://github.com/ENTERPILOT/GoModel), an OpenAI-compatible AI gateway, for Nix. It also gives a NixOS module, `services.gomodel`, and a NixOS VM test.

The packaged version is 0.1.103. The pins are in `pkgs/gomodel/sources.json`.

## Contents

| Path | Purpose |
| --- | --- |
| `pkgs/gomodel/package.nix` | The `gomodel` binary, built with Go 1.27, with the dashboard embedded. |
| `pkgs/gomodel/dashboard.nix` | The Svelte admin dashboard, built with `buildNpmPackage`. |
| `pkgs/gomodel/sources.json` | The version, commit, and hashes. |
| `pkgs/gomodel/update.sh` | The script that bumps `sources.json` to a new release. |
| `nixos/module.nix` | The `services.gomodel` NixOS module. |
| `nixos/tests/gomodel.nix` | The NixOS VM test. |

## Flake outputs

| Output | Description |
| --- | --- |
| `packages.<system>.gomodel` | The static binary, the same as the upstream release build. This is also `default`. |
| `packages.<system>.gomodel-swagger` | The binary with `-tags swagger`. Set `SWAGGER_ENABLED=true` to serve `/swagger/index.html`. |
| `packages.<system>.gomodel-plugins` | The cgo binary for Go shared-object plugins. |
| `packages.<system>.gomodel-dashboard` | The built dashboard bundle alone. |
| `overlays.default` | Adds `gomodel` and `gomodel-plugins` to `pkgs`. |
| `nixosModules.default` | The `services.gomodel` module. |
| `checks.<system>.gomodel` | The package build. The build runs the upstream unit tests. |
| `checks.x86_64-linux.nixos-test` | The VM test. |

## Build and run the package

```sh
nix build .#gomodel
./result/bin/gomodel --version
OPENAI_API_KEY=sk-... nix run .#gomodel
```

The gateway listens on port 8080. Open `http://localhost:8080/admin/dashboard` for the dashboard.

## Use the NixOS module

Add this flake as an input, and import the module:

```nix
{
  inputs.gomodel.url = "path:/home/neal/Documents/gomodel";

  outputs = { nixpkgs, gomodel, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        gomodel.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

Then configure the service:

```nix
{
  services.gomodel = {
    enable = true;
    port = 8080;
    openFirewall = true;

    # Secrets: GOMODEL_MASTER_KEY=..., ANTHROPIC_API_KEY=...
    environmentFiles = [ "/run/secrets/gomodel.env" ];

    # Secret files. The service reads them from /run/credentials/gomodel.service/.
    credentials.openai = "/run/secrets/openai-api-key";

    settings = {
      providers.openai = {
        type = "openai";
        api_key = "\${file:/run/credentials/gomodel.service/openai}";
      };
      providers.anthropic = {
        type = "anthropic";
        api_key = "\${ANTHROPIC_API_KEY}";
      };
    };

    environment = {
      LOG_LEVEL = "info";
      METRICS_ENABLED = "true";
    };
  };
}
```

### Module options

| Option | Default | Description |
| --- | --- | --- |
| `enable` | `false` | Enables the service. |
| `package` | this flake's `gomodel` | The package to run. Set it to `gomodel-plugins` for plugin support. |
| `port` | `8080` | The TCP port. It sets `PORT`. |
| `openFirewall` | `false` | Opens the port in the firewall. |
| `settings` | `{ }` | The content of `config.yaml`, as Nix attributes. |
| `configFile` | `null` | A `config.yaml` file. If you set it, the module ignores `settings`. |
| `environment` | `{ }` | Environment variables. See the upstream `.env.template` for the names. |
| `environmentFiles` | `[ ]` | systemd environment files, for secrets. |
| `credentials` | `{ }` | Secret files for systemd `LoadCredential`. |
| `database.createLocally` | `false` | Creates a local PostgreSQL database and sets `STORAGE_TYPE=postgresql`. |
| `redis.createLocally` | `false` | Starts a local Redis on a Unix socket and sets `REDIS_URL`. |
| `disableVersionCheck` | `true` | Sets `GOMODEL_VERSION_CHECK_ENABLED=false`. Nix controls the updates. |

### Secrets

Do not put secrets in `settings` or `environment`. Nix writes these values to the Nix store, and all users can read the store.

Use one of these two methods:

1. Put `NAME=value` lines in a file, and add the file to `environmentFiles`. Write `${NAME}` in `settings`, or use a variable that GoModel reads directly, for example `GOMODEL_MASTER_KEY`.
2. Add a secret file to `credentials`. Write `${file:/run/credentials/gomodel.service/<name>}` in `settings`.

In a Nix string, write `\${` to get a literal `${`.

### Files and directories

| Path | Content |
| --- | --- |
| `/var/lib/gomodel/data/` | The SQLite database, media files, and the install identity. |
| `/var/lib/gomodel/config/config.yaml` | A link to `/etc/gomodel/config.yaml`, or to `configFile`. |
| `/var/cache/gomodel/` | The model catalog cache. |
| `/run/gomodel/gomodel.pid` | The PID file. |

The service runs as a dynamic user with the name `gomodel`.

### Reload

GoModel reads its configuration again when it gets `SIGHUP`. If only `settings` changes, `nixos-rebuild switch` reloads the service and does not restart it. A change to `environment`, `port`, or the package restarts the service.

To reload manually, run this command:

```sh
systemctl reload gomodel
```

### Local PostgreSQL and Redis

```nix
{
  services.gomodel = {
    enable = true;
    database.createLocally = true;
    redis.createLocally = true;
  };
}
```

GoModel connects to PostgreSQL through `/run/postgresql` with peer authentication. Redis listens on `/run/redis-gomodel/redis.sock`. The local Redis instance holds the model registry cache. To use it for the response cache too, set `cache.response.simple.redis.url = "\${REDIS_URL}"` in `settings`.

### Network exposure

GoModel listens on all network interfaces. It has no option for a bind address. Keep `openFirewall = false` if a reverse proxy on the same host is the only client. If the proxy sends `X-Forwarded-For`, set `SERVER_TRUSTED_PROXIES` in `environment`.

## Plugins

The `gomodel-plugins` package builds with cgo. Its wrapper adds Go 1.27 and a C compiler to `PATH`, so `gomodel plugin build` uses the same toolchain as the gateway. A plugin must use the same toolchain and build flags as the gateway that loads it.

```sh
nix shell .#gomodel-plugins -c gomodel plugin build -o myplugin.so ./myplugin
```

Then set `PLUGINS_ENABLED = "true"` and the plugin settings in the module.

## Update to a new release

Run the update script on a machine with network access. The dev shell contains all the tools that the script uses.

```sh
nix develop
./pkgs/gomodel/update.sh            # latest release
./pkgs/gomodel/update.sh 0.1.104    # a specific release
nix build .#gomodel -L
nix build .#checks.x86_64-linux.nixos-test -L
```

If a new release needs a newer Go version, the script shows a warning. Then change `buildGo127Module` and `go_1_27` in `package.nix`.

## Run the tests

```sh
nix flake check -L
```

The VM test starts two machines and a client:

- `sqlite` uses the default SQLite storage.
- `postgres` uses `database.createLocally` and `redis.createLocally`.

On each machine, the test makes sure that:

- The health endpoints return success.
- A request without the master key gets HTTP 401.
- A chat completion goes through to a mock provider, with the API key from `credentials`.
- The dashboard loads.
- `systemctl reload` keeps the same process.

The client connects through the firewall.
