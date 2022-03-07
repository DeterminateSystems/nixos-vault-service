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
          cat /run/keys/files/rand_bytes
          cat /run/keys/files/rand_bytes-v2
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
      print(machine.succeed("sleep 1; ls /run/keys/files"))
      print(machine.succeed("sleep 1; cat /run/keys/files/rand_bytes"))
      print(machine.succeed("sleep 1; cat /run/keys/files/rand_bytes-v2"))
      print(machine.succeed("sleep 1; journalctl -u detsys-vaultAgent-example"))
      print(machine.succeed("sleep 30"))
    '';
}
