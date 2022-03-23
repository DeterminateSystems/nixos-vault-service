{ nixpkgs, lib, ... }:
let
  testTools = import (nixpkgs + "/nixos/lib/testing-python.nix") { system = "x86_64-linux"; };
  mkTest = config: testScript:
    testTools.simpleTest {
      inherit testScript;
      machine = { pkgs, ... }: {
        imports = [
          ./implementation.nix
          config
        ];
      };
    };
in
{
  basicEnvironment = mkTest
    ({ pkgs, ... }: {
      environment.variables.VAULT_ADDR = "http://127.0.0.1:8200";

      systemd.services.vault = {
        wantedBy = [ "default.target" ];
        path = [ pkgs.glibc ];
        script = ''
          ${pkgs.vault}/bin/vault server -dev -dev-root-token-id=abc123
        '';
      };

      systemd.services.setup-vault = {
        wantedBy = [ "default.target" ];
        after = [ "vault.service" ];
        path = [
          (
            (pkgs.terraform_1.withPlugins (tf: [
              tf.local
              tf.vault
            ]))
          )
        ];

        unitConfig.Type = "oneshot";

        script = ''
          set -eux

          cd /
          mkdir -p terraform
          cd terraform

          cp -r ${../terraform}/* ./
          terraform init
          terraform apply -auto-approve

          ls /
        '';
      };

      detsys.systemd.services.example.vaultAgent = {
        extraConfig = {
          vault = [{ address = "http://127.0.0.1:8200"; }];
          auto_auth = [
            {
              method = [
                {
                  config = [
                    {
                      remove_secret_id_file_after_reading = false;
                      role_id_file_path = "/role_id";
                      secret_id_file_path = "/secret_id";
                    }
                  ];
                  type = "approle";
                }
              ];
            }
          ];
          template_config = [{
            static_secret_render_interval = "5s";
          }];
        };

        environment.template = ''
          {{ with secret "sys/tools/random/1" "format=base64" }}
          MY_SECRET={{ .Data.random_bytes }}
          {{ end }}
        '';
        secretFiles.files."example".template = "hello";
      };
      systemd.services.example = {
        script = ''
          echo My secret is $MY_SECRET
          sleep infinity
        '';
      };
    })
    ''
      machine.wait_for_job("setup-vault")
      print(machine.succeed("sleep 5; journalctl -u setup-vault"))
      machine.start_job("example")
      machine.wait_for_job("detsys-vaultAgent-example")
      print(machine.succeed("sleep 5; ls /run/keys"))
      print(machine.succeed("sleep 1; ls /run/keys/environment"))
      print(machine.succeed("sleep 1; cat /run/keys/environment/EnvFile"))
      print(machine.succeed("sleep 1; journalctl -u detsys-vaultAgent-example"))
      print(machine.succeed("sleep 30"))
    '';

  secretFile = mkTest
    ({ pkgs, ... }: {
      environment.variables.VAULT_ADDR = "http://127.0.0.1:8200";

      systemd.services.vault = {
        wantedBy = [ "default.target" ];
        path = [ pkgs.glibc ];
        script = ''
          ${pkgs.vault}/bin/vault server -dev -dev-root-token-id=abc123
        '';
      };

      systemd.services.setup-vault = {
        wantedBy = [ "default.target" ];
        after = [ "vault.service" ];
        path = [
          (
            (pkgs.terraform_1.withPlugins (tf: [
              tf.local
              tf.vault
            ]))
          )
        ];

        unitConfig.Type = "oneshot";

        script = ''
          set -eux

          cd /
          mkdir -p terraform
          cd terraform

          cp -r ${../terraform}/* ./
          terraform init
          terraform apply -auto-approve

          ls /
        '';
      };

      detsys.systemd.services.example.vaultAgent = {
        extraConfig = {
          vault = [{ address = "http://127.0.0.1:8200"; }];
          auto_auth = [
            {
              method = [
                {
                  config = [
                    {
                      remove_secret_id_file_after_reading = false;
                      role_id_file_path = "/role_id";
                      secret_id_file_path = "/secret_id";
                    }
                  ];
                  type = "approle";
                }
              ];
            }
          ];
          template_config = [{
            static_secret_render_interval = "5s";
          }];
        };

        secretFiles.files."rand_bytes".template = ''
          {{ with secret "sys/tools/random/3" "format=base64" }}
          Have THREE random bytes from a templated string! {{ .Data.random_bytes }}
          {{ end }}
        '';

        secretFiles.files."rand_bytes-v2".templateFile =
          let
            file = pkgs.writeText "rand_bytes-v2.tpl" ''
              {{ with secret "sys/tools/random/6" "format=base64" }}
              Have SIX random bytes, but from a template file! {{ .Data.random_bytes }}
              {{ end }}
            '';
          in
          file;
      };

      systemd.services.example = {
        script = ''
          cat /tmp/detsys-vault/rand_bytes
          cat /tmp/detsys-vault/rand_bytes-v2
          sleep infinity
        '';
      };
    })
    ''
      machine.wait_for_job("setup-vault")
      print(machine.succeed("sleep 5; journalctl -u setup-vault"))
      machine.start_job("example")
      machine.wait_for_job("detsys-vaultAgent-example")
      print(machine.succeed("sleep 5; ls /run/keys"))
      print(machine.succeed("sleep 1; ls /tmp"))
      print(machine.succeed("sleep 1; systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /tmp/detsys-vault/rand_bytes"))
      print(machine.succeed("sleep 1; systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /tmp/detsys-vault/rand_bytes-v2"))
      print(machine.succeed("sleep 1; journalctl -u detsys-vaultAgent-example"))
      print(machine.succeed("sleep 30"))
    '';

  secretFileSlow = mkTest
    ({ pkgs, ... }: {
      environment.variables.VAULT_ADDR = "http://127.0.0.1:8200";

      systemd.services.vault = {
        wantedBy = [ "default.target" ];
        path = [ pkgs.glibc ];
        script = ''
          ${pkgs.vault}/bin/vault server -dev -dev-root-token-id=abc123
        '';
      };

      systemd.services.setup-vault = {
        wantedBy = [ "default.target" ];
        after = [ "vault.service" ];
        path = [
          (
            (pkgs.terraform_1.withPlugins (tf: [
              tf.local
              tf.vault
            ]))
          )
        ];

        unitConfig.Type = "oneshot";

        script = ''
          set -eux

          cd /
          mkdir -p terraform
          cd terraform

          cp -r ${../terraform}/* ./
          terraform init
          terraform apply -auto-approve

          ls /
        '';
      };

      detsys.systemd.services.example.vaultAgent = {
        extraConfig = {
          vault = [{ address = "http://127.0.0.1:8200"; }];
          auto_auth = [
            {
              method = [
                {
                  config = [
                    {
                      remove_secret_id_file_after_reading = false;
                      role_id_file_path = "/role_id";
                      secret_id_file_path = "/secret_id";
                    }
                  ];
                  type = "approle";
                }
              ];
            }
          ];
          template_config = [{
            static_secret_render_interval = "5s";
          }];
        };

        secretFiles.files."slow" = {
          changeAction = "none";
          template = ''
            {{ with secret "sys/tools/random/3" "format=base64" }}
            Have THREE random bytes from a templated string! {{ .Data.random_bytes }}
            {{ end }}
          '';
        };
      };

      systemd.services.example = {
        script = ''
          while sleep 5
          do
            echo Reading a secret from a file that is constantly being overwritten:
            cat /tmp/detsys-vault/slow
          done

          sleep infinity
        '';
      };
    })
    ''
      machine.wait_for_job("setup-vault")
      print(machine.succeed("sleep 5; journalctl -u setup-vault"))
      machine.start_job("example")
      machine.wait_for_job("detsys-vaultAgent-example")
      print(machine.succeed("sleep 5; ls /run/keys"))
      print(machine.succeed("sleep 1; ls /tmp"))
      print(machine.succeed("sleep 1; systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /tmp/detsys-vault/slow"))
      print(machine.succeed("sleep 1; journalctl -u detsys-vaultAgent-example"))
      print(machine.succeed("sleep 30"))
    '';

  prometheus = mkTest
    ({ pkgs, ... }: {
      environment.variables.VAULT_ADDR = "http://127.0.0.1:8200";

      systemd.services.vault = {
        wantedBy = [ "default.target" ];
        path = [ pkgs.glibc ];
        script = ''
          ${pkgs.vault}/bin/vault server -dev -dev-root-token-id=abc123
        '';
      };

      systemd.services.setup-vault = {
        wantedBy = [ "default.target" ];
        after = [ "vault.service" ];
        path = [
          (pkgs.terraform_1.withPlugins (tf: [
            tf.local
            tf.vault
          ]))
        ];

        unitConfig.Type = "oneshot";

        script = ''
          set -eux

          cd /
          mkdir -p terraform
          cd terraform

          cp -r ${../terraform}/* ./
          terraform init
          terraform apply -auto-approve

          ls /
        '';
      };

      services.nginx = {
        enable = true;
        virtualHosts."localhost" = {
          basicAuthFile = "/tmp/detsys-vault/prometheus-basic-auth";
          root = pkgs.writeTextDir "index.html" "<h1>Hi</h1>";
        };
      };

      detsys.systemd.services.nginx.vaultAgent = {
        extraConfig = {
          vault = [{ address = "http://127.0.0.1:8200"; }];
          auto_auth = [
            {
              method = [
                {
                  config = [
                    {
                      remove_secret_id_file_after_reading = false;
                      role_id_file_path = "/role_id";
                      secret_id_file_path = "/secret_id";
                    }
                  ];
                  type = "approle";
                }
              ];
            }
          ];
          template_config = [{
            static_secret_render_interval = "5s";
          }];
        };

        secretFiles.files."prometheus-basic-auth" = {
          changeAction = "none";
          template = ''
            {{ with secret "internalservices/kv/monitoring/prometheus-basic-auth" }}
            {{ .Data.data.username }}:{{ .Data.data.htpasswd }}
            {{ end }}
          '';
        };
      };
    })
    ''
      machine.wait_for_job("setup-vault")
      machine.start_job("nginx")
      machine.wait_for_job("detsys-vaultAgent-nginx")
      machine.succeed("sleep 5")
      machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-nginx.service -p PrivateTmp=true cat /tmp/detsys-vault/prometheus-basic-auth")

      machine.wait_for_unit("nginx")
      machine.wait_for_open_port(80)
      print(machine.fail("curl --fail http://localhost"))
      print(machine.succeed("curl --fail http://test:test@localhost"))
    '';

  token = mkTest
    ({ pkgs, ... }: {
      environment.variables.VAULT_ADDR = "http://127.0.0.1:8200";
      environment.systemPackages = [ pkgs.vault pkgs.getent ];

      systemd.services.vault = {
        wantedBy = [ "default.target" ];
        path = [ pkgs.glibc ];
        script = ''
          ${pkgs.vault}/bin/vault server -dev -dev-root-token-id=abc123
        '';
      };

      systemd.services.setup-vault = {
        wantedBy = [ "default.target" ];
        after = [ "vault.service" ];
        path = [
          (pkgs.terraform_1.withPlugins (tf: [
            tf.local
            tf.vault
          ]))
        ];

        unitConfig.Type = "oneshot";

        script = ''
          set -eux

          cd /
          mkdir -p terraform
          cd terraform

          cp -r ${../terraform}/* ./
          terraform init
          terraform apply -auto-approve

          ls /
        '';
      };

      systemd.services.example.script = ''
        echo Vault token with special perms is:
        cat /tmp/detsys-vault/token
        sleep infinity
      '';

      detsys.systemd.services.example.vaultAgent = {
        extraConfig = {
          vault = [{ address = "http://127.0.0.1:8200"; }];
          auto_auth = [{
            method = [{
              config = [{
                remove_secret_id_file_after_reading = false;
                role_id_file_path = "/role_id";
                secret_id_file_path = "/secret_id";
              }];
              type = "approle";
            }];
          }];
        };

        secretFiles.files."token" = {
          changeAction = "none";
          template = ''
            {{ with secret "auth/token/create" "policies=token" "no_default_policy=true" }}{{ .Auth.ClientToken }}{{ end }}
          '';
        };
      };
    })
    ''
      machine.wait_for_job("setup-vault")
      machine.start_job("example")
      machine.wait_for_job("detsys-vaultAgent-example")
      machine.wait_for_open_port(8200)
      machine.succeed("sleep 5")

      # NOTE: it's necessary to cat the token to a more accessible location (for
      # this test) because `$(cat /token)` gets run by the calling shell and not
      # the systemd-run spawned shell -- /tmp/detsys-vault/token only exists for
      # the systemd-run spawned shell, and there's no easy way to tell the shell
      # "don't evaluate this, let the spawned shell evaluate it"
      machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /tmp/detsys-vault/token > /token")

      machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true -E VAULT_ADDR=http://127.0.0.1:8200/ -E VAULT_TOKEN=$(cat /token) -E PATH=$PATH -t -- vault kv get internalservices/kv/needs-token")
      machine.fail("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true -E VAULT_ADDR=http://127.0.0.1:8200/ -E VAULT_TOKEN=zzz -E PATH=$PATH -t -- vault kv get internalservices/kv/needs-token")
    '';

  perms = mkTest
    ({ pkgs, ... }: {
      environment.variables.VAULT_ADDR = "http://127.0.0.1:8200";

      systemd.services.vault = {
        wantedBy = [ "default.target" ];
        path = [ pkgs.glibc ];
        script = ''
          ${pkgs.vault}/bin/vault server -dev -dev-root-token-id=abc123
        '';
      };

      systemd.services.setup-vault = {
        wantedBy = [ "default.target" ];
        after = [ "vault.service" ];
        path = [
          (pkgs.terraform_1.withPlugins (tf: [
            tf.local
            tf.vault
          ]))
        ];

        unitConfig.Type = "oneshot";

        script = ''
          set -eux

          cd /
          mkdir -p terraform
          cd terraform

          cp -r ${../terraform}/* ./
          terraform init
          terraform apply -auto-approve

          ls /
        '';
      };

      detsys.systemd.services.example.vaultAgent = {
        extraConfig = {
          vault = [{ address = "http://127.0.0.1:8200"; }];
          auto_auth = [{
            method = [{
              type = "approle";
              config = [{
                remove_secret_id_file_after_reading = false;
                role_id_file_path = "/role_id";
                secret_id_file_path = "/secret_id";
              }];
            }];
          }];
        };

        environment.template = ''
          {{ with secret "sys/tools/random/9" "format=base64" }}
          NINE_BYTES={{ .Data.random_bytes }}
          {{ end }}
        '';

        secretFiles.files."rand_bytes" = {
          perms = "0642";
          template = ''
            {{ with secret "sys/tools/random/3" "format=base64" }}
            Have THREE random bytes from a templated string! {{ .Data.random_bytes }}
            {{ end }}
          '';
        };

        secretFiles.files."rand_bytes-v2" = {
          template = ''
            {{ with secret "sys/tools/random/6" "format=base64" }}
            Have SIX random bytes, also from a templated string! {{ .Data.random_bytes }}
            {{ end }}
          '';
        };
      };

      services.nginx.enable = true;

      systemd.services.example = {
        serviceConfig = {
          User = "nginx";
          Group = "nginx";
        };
        script = ''
          cat /tmp/detsys-vault/rand_bytes
          cat /tmp/detsys-vault/rand_bytes-v2
          echo Have NINE random bytes, from a templated EnvironmentFile! $NINE_BYTES
          sleep infinity
        '';
      };
    })
    ''
      machine.wait_for_file("/role_id")
      machine.start_job("example")
      machine.wait_for_job("detsys-vaultAgent-example")
      print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true stat /tmp/detsys-vault/rand_bytes"))
      print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true stat /tmp/detsys-vault/rand_bytes-v2"))
      machine.succeed("sleep 1")
      print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /tmp/detsys-vault/rand_bytes"))
      print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true stat /tmp/detsys-vault/rand_bytes"))
      print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /tmp/detsys-vault/rand_bytes-v2"))
      print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true stat /tmp/detsys-vault/rand_bytes-v2"))
      print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /run/keys/environment/EnvFile"))
      print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true stat /run/keys/environment/EnvFile"))
    '';
}
