{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.gomodel;
  settingsFormat = pkgs.formats.yaml { };

  stateDir = "/var/lib/gomodel";
  cacheDir = "/var/cache/gomodel";
  runtimeDir = "/run/gomodel";
  redisName = "gomodel";
  redisSocket = config.services.redis.servers.${redisName}.unixSocket;

  generatedConfig = settingsFormat.generate "gomodel-config.yaml" cfg.settings;
  useSettings = cfg.configFile == null && cfg.settings != { };
  hasConfigFile = cfg.configFile != null || useSettings;

  # config/config.yaml in the state directory links here.
  configLink = if cfg.configFile != null then cfg.configFile else "/etc/gomodel/config.yaml";
in
{
  options.services.gomodel = {
    enable = lib.mkEnableOption "GoModel, an OpenAI-compatible AI gateway";

    package = lib.mkPackageOption pkgs "gomodel" { };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        TCP port for the gateway. GoModel listens on all interfaces. Use
        {option}`services.gomodel.openFirewall` or a reverse proxy to control access.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open {option}`services.gomodel.port` in the firewall.";
    };

    settings = lib.mkOption {
      type = settingsFormat.type;
      default = { };
      example = lib.literalExpression ''
        {
          server.base_path = "/gateway";
          providers.openai = {
            type = "openai";
            api_key = "''${OPENAI_API_KEY}";
          };
          logging.retention_days = 30;
        }
      '';
      description = ''
        GoModel configuration, written to {file}`config/config.yaml` in the
        state directory. See
        <https://github.com/ENTERPILOT/GoModel/blob/main/config/config.example.yaml>.

        The file is in the Nix store and is readable by all users. Do not put
        secrets here. Write `''${NAME}` instead, and set `NAME` in
        {option}`services.gomodel.environmentFiles`. GoModel expands the
        reference at startup. Environment variables override this file.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/etc/gomodel/config.yaml";
      description = ''
        Path to a GoModel `config.yaml`. If set, {option}`services.gomodel.settings`
        is ignored. A path outside the Nix store must be readable by the
        `gomodel` service user.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        LOG_LEVEL = "debug";
        METRICS_ENABLED = "true";
        GUARDRAILS_ENABLED = "true";
      };
      description = ''
        Environment variables for the gateway. See
        <https://github.com/ENTERPILOT/GoModel/blob/main/.env.template> for
        all names. Do not put secrets here: the values are in the Nix store.
      '';
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      example = [ "/run/secrets/gomodel.env" ];
      description = ''
        Files with `NAME=value` lines, loaded by systemd. Use them for
        secrets such as `GOMODEL_MASTER_KEY`, `GOMODEL_ENCRYPTION_KEY` and
        provider API keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, ...).
      '';
    };

    credentials = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = {
        openai = "/run/secrets/openai-api-key";
      };
      description = ''
        Secret files for systemd `LoadCredential`. Each file is readable only
        by the service, at {file}`/run/credentials/gomodel.service/<name>`.
        Use the path in {option}`services.gomodel.settings` with a GoModel
        file reference, for example
        `api_key = "''${file:/run/credentials/gomodel.service/openai}"`.
        Use a string path, not a Nix path literal: Nix copies a path literal
        into the world-readable store.
      '';
    };

    database.createLocally = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Create a local PostgreSQL database `gomodel`, owned by the system user
        `gomodel`. GoModel connects through the Unix socket and stores audit
        logs, usage and its other data there instead of SQLite.
      '';
    };

    redis.createLocally = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run a local Redis instance (`redis-gomodel`) on a Unix socket and
        use it as the model registry cache (`REDIS_URL`). To use it for
        response caching too, set `cache.response.simple.redis.url` in
        {option}`services.gomodel.settings` to `''${REDIS_URL}`.
      '';
    };

    disableVersionCheck = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Disable the daily update check against gomodel.enterpilot.io. Nix
        manages updates, so the check is off by default.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.gomodel.environment = lib.mkMerge [
      {
        PORT = toString cfg.port;
        HOME = stateDir;
        # Model catalog cache. The default is $XDG_CACHE_HOME/gomodel.
        XDG_CACHE_HOME = "/var/cache";
        GOMODEL_CACHE_DIR = cacheDir;
        PID_FILE = "${runtimeDir}/gomodel.pid";
      }
      (lib.mkIf cfg.disableVersionCheck {
        GOMODEL_VERSION_CHECK_ENABLED = lib.mkDefault "false";
      })
      (lib.mkIf cfg.database.createLocally {
        STORAGE_TYPE = lib.mkDefault "postgresql";
        POSTGRES_URL = lib.mkDefault "postgres:///gomodel?host=/run/postgresql&user=gomodel";
      })
      (lib.mkIf cfg.redis.createLocally {
        REDIS_URL = lib.mkDefault "unix://${redisSocket}";
      })
    ];

    services.postgresql = lib.mkIf cfg.database.createLocally {
      enable = true;
      ensureDatabases = [ "gomodel" ];
      ensureUsers = [
        {
          name = "gomodel";
          ensureDBOwnership = true;
        }
      ];
    };

    services.redis.servers.${redisName} = lib.mkIf cfg.redis.createLocally {
      enable = true;
      port = 0;
    };

    # For `gomodel --version`, `gomodel migrate` and `gomodel secrets`.
    environment.systemPackages = [ cfg.package ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    environment.etc."gomodel/config.yaml" = lib.mkIf useSettings { source = generatedConfig; };

    systemd.services.gomodel = {
      description = "GoModel AI gateway";
      documentation = [ "https://github.com/ENTERPILOT/GoModel" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
      ]
      ++ lib.optional cfg.database.createLocally "postgresql.target"
      ++ lib.optional cfg.redis.createLocally "redis-${redisName}.service";
      requires =
        lib.optional cfg.database.createLocally "postgresql.target"
        ++ lib.optional cfg.redis.createLocally "redis-${redisName}.service";

      inherit (cfg) environment;

      # GoModel re-reads config.yaml on SIGHUP. The state directory links to
      # /etc/gomodel/config.yaml, and activation updates /etc before the reload.
      reloadTriggers = lib.optional useSettings generatedConfig;

      # GoModel reads config/config.yaml relative to its working directory, and
      # keeps its data (SQLite database, media, install identity) in ./data
      # when that directory exists.
      preStart = ''
        mkdir -p data config
        ${if hasConfigFile then "ln -sfn ${configLink} config/config.yaml" else "rm -f config/config.yaml"}
      '';

      serviceConfig = {
        Type = "exec";
        ExecStart = lib.getExe cfg.package;
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 60;

        DynamicUser = true;
        User = "gomodel";
        Group = "gomodel";
        SupplementaryGroups =
          lib.optional cfg.redis.createLocally
            config.services.redis.servers.${redisName}.group;
        EnvironmentFile = cfg.environmentFiles;
        LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") cfg.credentials;

        StateDirectory = "gomodel";
        StateDirectoryMode = "0750";
        CacheDirectory = "gomodel";
        RuntimeDirectory = "gomodel";
        WorkingDirectory = stateDir;
        UMask = "0077";

        AmbientCapabilities = lib.optional (cfg.port < 1024) "CAP_NET_BIND_SERVICE";
        # An empty list renders nothing, so "" clears the bounding set explicitly.
        CapabilityBoundingSet = if cfg.port < 1024 then [ "CAP_NET_BIND_SERVICE" ] else [ "" ];
        NoNewPrivileges = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
      };
    };
  };

  meta.maintainers = [ ];
}
