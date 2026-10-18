# NixOS VM test for services.gomodel.
#
#   nix build .#checks.x86_64-linux.nixos-test -L
#
# Node "sqlite" uses the defaults (SQLite in the state directory) and routes a
# chat completion to a mock OpenAI-compatible provider. Node "postgres" uses
# the local PostgreSQL database and Redis cache options.
{ pkgs, nixosModule }:

let
  mockPort = 9999;

  mockProvider = {
    systemd.services.mock-provider = {
      wantedBy = [ "multi-user.target" ];
      before = [ "gomodel.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 -I ${./mock-provider.py} ${toString mockPort}";
        DynamicUser = true;
      };
    };
  };

  common = {
    imports = [
      nixosModule
      mockProvider
    ];
    services.gomodel = {
      enable = true;
      openFirewall = true;
      environment.GOMODEL_OFFLINE = "true";
      environmentFiles = [ "/etc/gomodel-test.env" ];
      credentials.openai = "/etc/gomodel-test-openai-key";
      settings.providers.openai = {
        type = "openai";
        base_url = "http://127.0.0.1:${toString mockPort}/v1";
        api_key = "\${file:/run/credentials/gomodel.service/openai}";
      };
    };
    # Test secrets only. Real deployments use sops-nix, agenix or similar.
    environment.etc."gomodel-test.env".text = "GOMODEL_MASTER_KEY=test-master-key\n";
    environment.etc."gomodel-test-openai-key".text = "sk-test";
  };
in
pkgs.testers.runNixOSTest {
  name = "gomodel";

  nodes = {
    sqlite = {
      imports = [ common ];
      services.gomodel.metrics.enable = true;
    };

    postgres = {
      imports = [ common ];
      services.gomodel = {
        port = 8081;
        database.createLocally = true;
        redis.createLocally = true;
      };
    };

    client = { };
  };

  testScript = ''
    import json

    AUTH = "-H 'Authorization: Bearer test-master-key'"
    CHAT = (
      "-H 'Content-Type: application/json' "
      "-d '{\"model\":\"mock-model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
    )

    # Never pipe into `grep -q`: it exits at the first match, and the writer
    # then fails under pipefail (curl exits with code 23).
    def check_gateway(node, port):
        node.wait_for_unit("gomodel.service")
        node.wait_for_open_port(port)
        node.wait_until_succeeds(f"curl -sf http://127.0.0.1:{port}/health/ready")

        # Authentication is on: GOMODEL_MASTER_KEY comes from the environment file.
        node.succeed(f"test $(curl -s -o /dev/null -w '%{{http_code}}' http://127.0.0.1:{port}/v1/models) = 401")

        # The model list comes from the mock provider.
        node.wait_until_succeeds(f"curl -sf {AUTH} http://127.0.0.1:{port}/v1/models | grep mock-model > /dev/null")

        # A chat completion goes through to the provider, with the API key from LoadCredential.
        out = json.loads(node.succeed(f"curl -sf {AUTH} {CHAT} http://127.0.0.1:{port}/v1/chat/completions"))
        assert out["choices"][0]["message"]["content"] == "hello from mock", out
        node.succeed("journalctl -u mock-provider.service | grep 'auth=Bearer sk-test' > /dev/null")

        # The embedded dashboard is served.
        node.succeed(f"curl -sfL http://127.0.0.1:{port}/admin/dashboard | grep /admin/static/ > /dev/null")

        # SIGHUP reload keeps the same process.
        pid = node.succeed("systemctl show -P MainPID gomodel.service").strip()
        node.succeed("systemctl reload gomodel.service")
        node.wait_until_succeeds("journalctl -u gomodel.service | grep 'configuration reloaded' > /dev/null")
        assert node.succeed("systemctl show -P MainPID gomodel.service").strip() == pid

    start_all()

    with subtest("SQLite storage"):
        check_gateway(sqlite, 8080)
        sqlite.succeed("test -s /var/lib/gomodel/data/gomodel.db")
        sqlite.succeed("test -L /var/lib/gomodel/config/config.yaml")
        sqlite.succeed("gomodel --version | grep -F 'gomodel ${pkgs.gomodel.version}'")

    with subtest("Prometheus metrics"):
        # Metrics are public: no master key on this request.
        metrics = sqlite.succeed("curl -sf http://127.0.0.1:8080/metrics")
        assert any(line.startswith("gomodel_") for line in metrics.splitlines()), metrics[:2000]

    with subtest("PostgreSQL storage and Redis cache"):
        check_gateway(postgres, 8081)
        postgres.succeed("journalctl -u gomodel.service | grep 'storage configured' | grep postgresql > /dev/null")
        postgres.succeed("journalctl -u gomodel.service | grep 'using redis cache' > /dev/null")
        postgres.wait_until_succeeds(
            "sudo -u postgres psql -d gomodel -tAc \"select count(*) from information_schema.tables where table_schema = 'public'\" | grep -v '^0$' > /dev/null"
        )
        postgres.wait_until_succeeds("redis-cli -s /run/redis-gomodel/redis.sock --scan | grep . > /dev/null")
        postgres.fail("test -e /var/lib/gomodel/data/gomodel.db")

        # This node leaves metrics off. check_gateway waited for the port.
        metrics = postgres.succeed("curl -s http://127.0.0.1:8081/metrics")
        assert "gomodel_" not in metrics, metrics[:2000]

    with subtest("Firewall"):
        client.wait_until_succeeds("curl -sf http://sqlite:8080/health")
  '';
}
