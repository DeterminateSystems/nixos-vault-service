{ nixpkgs, self, lib, ... }:
let
  testTools = import (nixpkgs + "/nixos/lib/testing-python.nix") { system = "x86_64-linux"; };
  mkTest = name: config: testScript:
    testTools.simpleTest {
      inherit name testScript;
      nodes.machine = { pkgs, ... }: {
        imports = [
          self.nixosModule
          config
        ];

        nixpkgs.config.allowUnfree = true;

        environment.variables.VAULT_ADDR = "http://127.0.0.1:8200";
        environment.systemPackages = [ pkgs.vault pkgs.getent ];

        systemd.services.vault = {
          wantedBy = [ "default.target" ];
          path = [ pkgs.getent ];
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

          serviceConfig.Type = "oneshot";

          script = ''
            set -eux

            cd /
            mkdir -p terraform
            cd terraform

            cp -r ${../terraform}/* ./
            terraform init
            terraform apply -auto-approve
          '';
        };
      };
    };

  tests = [
    (mkTest "basicEnvironment"
      ({ pkgs, ... }: {
        detsys.vaultAgent.systemd.services.example = {
          agentConfig = {
            vault = { address = "http://127.0.0.1:8200"; };
            auto_auth = {
              method = [{
                config = {
                  remove_secret_id_file_after_reading = false;
                  role_id_file_path = "/role_id";
                  secret_id_file_path = "/secret_id";
                };
                type = "approle";
              }];
            };
            template_config = {
              static_secret_render_interval = "5s";
            };
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
        machine.wait_for_file("/secret_id")
        machine.start_job("example")
        machine.wait_for_job("detsys-vaultAgent-example")
        print(machine.succeed("cat /run/keys/environment/example/EnvFile"))
      '')

    (mkTest "secretFile"
      ({ pkgs, ... }: {
        detsys.vaultAgent.systemd.services.example = {
          agentConfig = {
            vault = { address = "http://127.0.0.1:8200"; };
            auto_auth = {
              method = [{
                config = {
                  remove_secret_id_file_after_reading = false;
                  role_id_file_path = "/role_id";
                  secret_id_file_path = "/secret_id";
                };
                type = "approle";
              }];
            };
            template_config = {
              static_secret_render_interval = "5s";
            };
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
        print(machine.succeed("sleep 5; journalctl -u setup-vault"))
        machine.start_job("example")
        machine.wait_for_job("detsys-vaultAgent-example")
        print(machine.succeed("sleep 5; ls /run/keys"))
        print(machine.succeed("sleep 1; ls /tmp"))
        print(machine.succeed("sleep 1; systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /tmp/detsys-vault/rand_bytes"))
        print(machine.succeed("sleep 1; systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /tmp/detsys-vault/rand_bytes-v2"))
        print(machine.succeed("sleep 1; journalctl -u detsys-vaultAgent-example"))
      '')

    (mkTest "secretFileSlow"
      ({ pkgs, ... }: {
        detsys.vaultAgent.systemd.services.example = {
          agentConfig = {
            vault = { address = "http://127.0.0.1:8200"; };
            auto_auth = {
              method = [{
                config = {
                  remove_secret_id_file_after_reading = false;
                  role_id_file_path = "/role_id";
                  secret_id_file_path = "/secret_id";
                };
                type = "approle";
              }];
            };
            template_config = {
              static_secret_render_interval = "5s";
            };
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
        print(machine.succeed("sleep 5; journalctl -u setup-vault"))
        machine.start_job("example")
        machine.wait_for_job("detsys-vaultAgent-example")
        print(machine.succeed("sleep 5; ls /run/keys"))
        print(machine.succeed("sleep 1; ls /tmp"))
        print(machine.succeed("sleep 1; systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /tmp/detsys-vault/slow"))
        print(machine.succeed("sleep 1; journalctl -u detsys-vaultAgent-example"))
      '')

    (mkTest "prometheus"
      ({ pkgs, ... }: {
        services.nginx = {
          enable = true;
          virtualHosts."localhost" = {
            basicAuthFile = "/tmp/detsys-vault/prometheus-basic-auth";
            root = pkgs.writeTextDir "index.html" "<h1>Hi</h1>";
          };
        };

        detsys.vaultAgent.systemd.services.nginx = {
          agentConfig = {
            vault = { address = "http://127.0.0.1:8200"; };
            auto_auth = {
              method = [{
                config = {
                  remove_secret_id_file_after_reading = false;
                  role_id_file_path = "/role_id";
                  secret_id_file_path = "/secret_id";
                };
                type = "approle";
              }];
            };
            template_config = {
              static_secret_render_interval = "5s";
            };
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
        machine.start_job("nginx")
        machine.wait_for_job("detsys-vaultAgent-nginx")
        machine.succeed("sleep 5")
        machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-nginx.service -p PrivateTmp=true cat /tmp/detsys-vault/prometheus-basic-auth")

        machine.wait_for_unit("nginx")
        machine.wait_for_open_port(80)
        print(machine.fail("curl --fail http://localhost"))
        print(machine.succeed("curl --fail http://test:test@localhost"))
      '')

    (mkTest "token"
      ({ pkgs, ... }: {
        systemd.services.example.script = ''
          echo Vault token with special perms is:
          cat /tmp/detsys-vault/token
          sleep infinity
        '';

        detsys.vaultAgent.systemd.services.example = {
          agentConfig = {
            vault = { address = "http://127.0.0.1:8200"; };
            auto_auth = {
              method = [{
                config = {
                  remove_secret_id_file_after_reading = false;
                  role_id_file_path = "/role_id";
                  secret_id_file_path = "/secret_id";
                };
                type = "approle";
              }];
            };
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
        machine.start_job("example")
        machine.wait_for_job("detsys-vaultAgent-example")
        machine.wait_for_open_port(8200)
        machine.succeed("sleep 5")

        # NOTE: it's necessary to cat the token to a more accessible location (for
        # this test) because `$(cat /token)` gets run by the calling shell and not
        # the systemd-run spawned shell -- /tmp/detsys-vault/token only exists for
        # the systemd-run spawned shell, and there') no easy way to tell the shell
        # "don't evaluate this, let the spawned shell evaluate it"
        machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /tmp/detsys-vault/token > /token")

        machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true -E VAULT_ADDR=http://127.0.0.1:8200/ -E VAULT_TOKEN=$(cat /token) -E PATH=$PATH -t -- vault kv get internalservices/kv/needs-token")
        machine.fail("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true -E VAULT_ADDR=http://127.0.0.1:8200/ -E VAULT_TOKEN=zzz -E PATH=$PATH -t -- vault kv get internalservices/kv/needs-token")
      '')

    (mkTest "perms"
      ({ pkgs, ... }: {
        detsys.vaultAgent.systemd.services.example = {
          agentConfig = {
            vault = { address = "http://127.0.0.1:8200"; };
            auto_auth = {
              method = [{
                type = "approle";
                config = {
                  remove_secret_id_file_after_reading = false;
                  role_id_file_path = "/role_id";
                  secret_id_file_path = "/secret_id";
                };
              }];
            };
          };

          environment.template = ''
            {{ with secret "sys/tools/random/9" "format=base64" }}
            NINE_BYTES={{ .Data.random_bytes }}
            {{ end }}
          '';

          secretFiles.files."rand_bytes" = {
            perms = "642";
            template = ''
              {{ with secret "sys/tools/random/3" "format=base64" }}
              Have THREE random bytes from a templated string! {{ .Data.random_bytes }}
              {{ end }}
            '';
          };

          secretFiles.files."rand_bytes-v2" = {
            perms = "400";
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
        print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /run/keys/environment/example/EnvFile"))
        print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true stat /run/keys/environment/example/EnvFile"))
      '')

    (mkTest "multiEnvironment"
      ({ pkgs, ... }: {
        detsys.vaultAgent.systemd.services.example = {
          agentConfig = {
            vault = { address = "http://127.0.0.1:8200"; };
            auto_auth = {
              method = [{
                config = {
                  remove_secret_id_file_after_reading = false;
                  role_id_file_path = "/role_id";
                  secret_id_file_path = "/secret_id";
                };
                type = "approle";
              }];
            };
            template_config = {
              static_secret_render_interval = "5s";
            };
          };

          environment.template = ''
            {{ with secret "sys/tools/random/1" "format=base64" }}
            MY_SECRET_0={{ .Data.random_bytes }}
            {{ end }}
          '';
          environment.templateFiles = {
            "a".file = pkgs.writeText "a" ''
              {{ with secret "sys/tools/random/2" "format=base64" }}
              MY_SECRET_A={{ .Data.random_bytes }}
              {{ end }}
            '';
            "b".file = pkgs.writeText "b" ''
              {{ with secret "sys/tools/random/3" "format=base64" }}
              MY_SECRET_B={{ .Data.random_bytes }}
              {{ end }}
            '';
          };
        };
        systemd.services.example = {
          script = ''
            echo My 0 secret is $MY_SECRET_0
            echo My a secret is $MY_SECRET_A
            echo My b secret is $MY_SECRET_B
            sleep infinity
          '';
        };
      })
      ''
        machine.wait_for_file("/role_id")
        machine.start_job("example")
        machine.wait_for_job("detsys-vaultAgent-example")
        print(machine.succeed("cat /run/keys/environment/example/EnvFile"))
        print(machine.succeed("cat /run/keys/environment/example/a.EnvFile"))
        print(machine.succeed("cat /run/keys/environment/example/b.EnvFile"))
      '')

    (mkTest "delayedVault"
      ({ pkgs, lib, ... }: {
        systemd.services.vault.wantedBy = lib.mkForce [ ];
        systemd.services.setup-vault.wantedBy = lib.mkForce [ ];

        detsys.vaultAgent.systemd.services.example = {
          agentConfig = {
            vault = {
              address = "http://127.0.0.1:8200";
            };
            auto_auth = {
              method = [{
                type = "approle";
                config = {
                  remove_secret_id_file_after_reading = false;
                  role_id_file_path = "/role_id";
                  secret_id_file_path = "/secret_id";
                };
              }];
            };
            template_config = {
              static_secret_render_interval = "5s";
            };
          };

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

        systemd.services.example = {
          script = ''
            cat /tmp/detsys-vault/rand_bytes
            cat /tmp/detsys-vault/rand_bytes-v2
            sleep infinity
          '';
        };
      })
      ''
        # NOTE: starting example will block until detsys-vaultAgent-example
        # succeeds, which won't happen until all the secret files exist (which
        # obviously won') happen until after vault is available)
        machine.systemctl("start --no-block example")
        machine.succeed("sleep 3")
        machine.succeed("pkill -f messenger")
        machine.start_job("vault")
        machine.start_job("setup-vault")
        machine.wait_for_file("/secret_id")
        machine.start_job("example")
        machine.wait_for_job("detsys-vaultAgent-example")
        print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /tmp/detsys-vault/rand_bytes"))
        print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true stat /tmp/detsys-vault/rand_bytes"))
        print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /tmp/detsys-vault/rand_bytes-v2"))
        print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true stat /tmp/detsys-vault/rand_bytes-v2"))
      '')

    (mkTest "failedSidecar"
      ({ pkgs, ... }: {
        detsys.vaultAgent.systemd.services.example = {
          agentConfig = {
            vault = {
              address = "http://127.0.0.1:8200";
              retry.num_retries = 1;
            };
            auto_auth = {
              method = [{
                config = {
                  remove_secret_id_file_after_reading = false;
                  role_id_file_path = "/role_id";
                  secret_id_file_path = "/secret_id";
                };
                type = "approle";
              }];
            };
            template_config = {
              static_secret_render_interval = "5s";
            };
          };

          environment.template = ''
            {{ with secret "sys/tools/random/3" "format=base64" }}
            MY_SECRET={{ .Data.non-existent-with-hyphen }}
            {{ end }}
          '';
        };
        systemd.services.example = {
          script = ''
            echo My secret is $MY_SECRET
            sleep infinity
          '';
        };
      })
      ''
        machine.wait_for_file("/secret_id")
        machine.systemctl("start --no-block example")
        machine.succeed("sleep 3")
        print(machine.fail("systemctl status detsys-vaultAgent-example"))
        substate=machine.succeed("systemctl show -p SubState --value example")
        if "dead" not in substate:
            raise Exception(f"unit shouldn't have even started if the sidecar unit failed, but had substate {substate}")
      '')

    (mkTest "defaultConfig"
      ({ pkgs, ... }: {
        detsys.vaultAgent.defaultAgentConfig = {
          vault = { address = "http://127.0.0.1:8200"; };
          auto_auth = {
            method = [{
              config = {
                remove_secret_id_file_after_reading = false;
                role_id_file_path = "/role_id";
                secret_id_file_path = "/secret_id";
              };
              type = "approle";
            }];
          };
          template_config = {
            static_secret_render_interval = "5s";
          };
        };

        detsys.vaultAgent.systemd.services.example = {
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

        detsys.vaultAgent.systemd.services.example2 = {
          secretFiles.files."rand_bytes".template = ''
            {{ with secret "sys/tools/random/3" "format=base64" }}
            Have THREE random bytes from a templated string! {{ .Data.random_bytes }}
            {{ end }}
          '';
        };

        detsys.vaultAgent.systemd.services.example3 = {
          agentConfig = {
            vault = { address = "http://127.0.0.1:8200"; };
            auto_auth = {
              method = [{
                config = {
                  remove_secret_id_file_after_reading = false;
                  role_id_file_path = "/role_id";
                  secret_id_file_path = "/secret_id";
                };
                type = "approle";
              }];
            };
            template_config = {
              static_secret_render_interval = "1s";
            };
          };

          secretFiles.files."rand_bytes".template = ''
            {{ with secret "sys/tools/random/3" "format=base64" }}
            Have THREE random bytes from a templated string! {{ .Data.random_bytes }}
            {{ end }}
          '';
        };

        systemd.services.example = {
          script = ''
            cat /tmp/detsys-vault/rand_bytes
            cat /tmp/detsys-vault/rand_bytes-v2
            sleep infinity
          '';
        };

        systemd.services.example2 = {
          script = ''
            cat /tmp/detsys-vault/rand_bytes
            sleep infinity
          '';
        };

        systemd.services.example3 = {
          script = ''
            cat /tmp/detsys-vault/rand_bytes
            sleep infinity
          '';
        };
      })
      ''
        machine.wait_for_file("/secret_id")
        machine.start_job("example")
        machine.wait_for_job("detsys-vaultAgent-example")
        print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /tmp/detsys-vault/rand_bytes"))
        print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat /tmp/detsys-vault/rand_bytes-v2"))
        machine.start_job("example2")
        machine.wait_for_job("detsys-vaultAgent-example2")
        print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example2.service -p PrivateTmp=true cat /tmp/detsys-vault/rand_bytes"))
        machine.start_job("example3")
        machine.wait_for_job("detsys-vaultAgent-example3")
        print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example3.service -p PrivateTmp=true cat /tmp/detsys-vault/rand_bytes"))
        machine.succeed("sleep 2")
        print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example3.service -p PrivateTmp=true cat /tmp/detsys-vault/rand_bytes"))
      '')

    (mkTest "pathToSecret"
      ({ config, pkgs, ... }: {
        detsys.vaultAgent.defaultAgentConfig = {
          vault = { address = "http://127.0.0.1:8200"; };
          auto_auth = {
            method = [{
              config = {
                remove_secret_id_file_after_reading = false;
                role_id_file_path = "/role_id";
                secret_id_file_path = "/secret_id";
              };
              type = "approle";
            }];
          };
          template_config = {
            static_secret_render_interval = "5s";
          };
        };

        detsys.vaultAgent.systemd.services.example = {
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

        environment.etc."rand_bytes-path".text = config.detsys.vaultAgent.systemd.services.example.secretFiles.files."rand_bytes".path;
        environment.etc."rand_bytes-v2-path".text = config.detsys.vaultAgent.systemd.services.example.secretFiles.files."rand_bytes-v2".path;
      })
      ''
        machine.wait_for_file("/secret_id")
        machine.start_job("example")
        machine.wait_for_job("detsys-vaultAgent-example")
        print(machine.succeed("cat /etc/rand_bytes-path"))
        print(machine.succeed("cat /etc/rand_bytes-v2-path"))
        print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat $(cat /etc/rand_bytes-path)"))
        print(machine.succeed("systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-example.service -p PrivateTmp=true cat $(cat /etc/rand_bytes-v2-path)"))
      '')

    (mkTest "failAfterRetries"
      ({ pkgs, ... }: {
        detsys.vaultAgent.systemd.services.example = {
          agentConfig = {
            vault = {
              address = "http://127.0.0.1:8200";
              retry.num_retries = 3;
            };
            auto_auth = {
              method = [{
                config = {
                  remove_secret_id_file_after_reading = false;
                  role_id_file_path = "/role_id";
                  secret_id_file_path = "/secret_id";
                };
                type = "approle";
              }];
            };
            template_config = {
              static_secret_render_interval = "5s";
            };
          };

          environment.template = ''
            {{ with secret "sys/tools/randomzzz" "format=base64" }}
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
        machine.wait_for_file("/secret_id")
        machine.start_job("example")
        machine.succeed("sleep 10")
        print(machine.fail("systemctl status detsys-vaultAgent-example"))
        print(machine.fail("systemctl status example"))
      '')

    (mkTest "failOnStartup"
      ({ pkgs, ... }: {
        detsys.vaultAgent.systemd.services.example = {
          agentConfig = {
            vault = {
              address = "http://127.0.0.1:8200";
              retry.num_retries = 3;
            };
            auto_auth = {
              method = [{
                config = {
                  remove_secret_id_file_after_reading = false;
                  role_id_file_path = "/role_id";
                  secret_id_file_path = "/secret_id";
                };
                type = "approle";
              }];
            };
            template_config = {
              static_secret_render_interval = "5s";
            };
          };

          environment.template = ''
            {{ with secret "sys/tools/random/1" "format=base64" }}
            MY_SECRET={{ .Data.random_bytes }}
            {{ end }}
          '';
        };
        systemd.services.example = {
          script = ''
            echo My secret is $MY_SECRET
            sleep infinity
          '';
        };
      })
      ''
        machine.wait_for_file("/secret_id")
        machine.systemctl("start --no-block example")
        machine.execute("while ! pkill -f messenger; do sleep 0.1; done")
        print(machine.fail("systemctl status example"))
        print(machine.fail("systemctl status detsys-vaultAgent-example"))
        machine.succeed("sleep 3")
        print(machine.succeed("systemctl status example"))
        print(machine.succeed("systemctl status detsys-vaultAgent-example"))
      '')

    (mkTest "unitsStopEachOther"
      ({ pkgs, ... }: {
        detsys.vaultAgent.defaultAgentConfig = {
          vault = { address = "http://127.0.0.1:8200"; };
          auto_auth = {
            method = [{
              config = {
                remove_secret_id_file_after_reading = false;
                role_id_file_path = "/role_id";
                secret_id_file_path = "/secret_id";
              };
              type = "approle";
            }];
          };
          template_config = {
            static_secret_render_interval = "5s";
          };
        };

        detsys.vaultAgent.systemd.services.example = {
          secretFiles.files."rand_bytes".template = ''
            {{ with secret "sys/tools/random/3" "format=base64" }}
            Have THREE random bytes from a templated string! {{ .Data.random_bytes }}
            {{ end }}
          '';
        };

        detsys.vaultAgent.systemd.services.example2 = {
          secretFiles.files."rand_bytes-v2".template = ''
            {{ with secret "sys/tools/random/6" "format=base64" }}
            Have SIX random bytes from a template string! {{ .Data.random_bytes }}
            {{ end }}
          '';
        };

        detsys.vaultAgent.systemd.services.example3 = {
          secretFiles.files."rand_bytes-v3".template = ''
            {{ with secret "sys/tools/random/9" "format=base64" }}
            Have NINE random bytes from a template string! {{ .Data.random_bytes }}
            {{ end }}
          '';
        };

        systemd.services.example = {
          script = ''
            cat /tmp/detsys-vault/rand_bytes
          '';
        };

        systemd.services.example2 = {
          script = ''
            cat /tmp/detsys-vault/rand_bytes-v2
            exit 1
          '';
        };

        systemd.services.example3 = {
          script = ''
            cat /tmp/detsys-vault/rand_bytes-v3
            sleep infinity
          '';
        };
      })
      ''
        machine.wait_for_file("/secret_id")
        machine.start_job("example")
        machine.start_job("example2")
        machine.start_job("example3")
        machine.succeed("sleep 1")

        if "dead" not in machine.succeed("systemctl show -p SubState --value example"):
            raise Exception("full unit should have exited successfully")
        if "dead" not in machine.succeed("systemctl show -p SubState --value detsys-vaultAgent-example"):
            raise Exception("sidecar unit should also have exited successfully")

        if "failed" not in machine.succeed("systemctl show -p SubState --value example2"):
            raise Exception("full unit should have failed")
        if "dead" not in machine.succeed("systemctl show -p SubState --value detsys-vaultAgent-example2"):
            raise Exception("sidecar unit should have exited successfully because the full unit failed")

        machine.stop_job("detsys-vaultAgent-example3")
        if "dead" not in machine.succeed("systemctl show -p SubState --value detsys-vaultAgent-example3"):
            raise Exception("sidecar unit should have exited because it was stopped")
        if "dead" not in machine.succeed("systemctl show -p SubState --value example3"):
            raise Exception("full unit should have exited successfully because the sidecar was stopped")
      '')
  ];
in
builtins.listToAttrs
  (map
    (test: { name = test.config.name; value = test; })
    tests)
