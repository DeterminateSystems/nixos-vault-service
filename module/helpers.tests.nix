{ path, lib, ... }:
let
  helpers = import ./helpers.nix { inherit lib; };
  suite = { ... } @ tests:
    (builtins.mapAttrs
      (name: value:
        (builtins.trace "test case '${name}':" value))
      tests);
in
with
(
  let
    evalCfg = config:
      (lib.evalModules {
        modules = [
          "${path}/nixos/modules/misc/assertions.nix"
          ./mock-systemd-module.nix
          ./definition.nix
          config
        ];
      }).config;

    safeEval = val:
      (builtins.tryEval
        (builtins.deepSeq val val)
      ) // { originalValue = val; };
  in
  {
    expectRenderedConfig = cfg: expect:
      let
        evaluatedCfg = evalCfg {
          systemd.services.example = { };
          detsys.systemd.services.example.vaultAgent = cfg;
        };
        result = safeEval evaluatedCfg;

        filteredAsserts = builtins.map (asrt: asrt.message) (lib.filter (asrt: !asrt.assertion) result.value.assertions);

        actual = (helpers.renderAgentConfig "example" result.value.detsys.systemd.services.example.vaultAgent).agentConfig;
      in
      if !result.success
      then
        evaluatedCfg
      else if (filteredAsserts != [ ] || result.value.warnings != [ ])
      then
        throw "Unexpected assertions or warnings. Assertions: ${builtins.toJSON filteredAsserts}. Warnings: ${builtins.toJSON result.value.warnings}"
      else if actual != expect
      then
        throw "Mismatched configuration. Expected: ${builtins.toJSON expect} Got: ${builtins.toJSON actual}"
      else "ok";
  }
);
{
  nothingSet = expectRenderedConfig
    { }
    {
      template = [ ];
    };

  environmentOnlyInline = expectRenderedConfig
    {
      environment.template = ''
        {{ with secret "postgresql/creds/hydra" }}
        HYDRA_DBI=dbi:Pg:dbname=hydra;host=the-database-server;username={{ .Data.username }};password={{ .Data.password }};
        {{ end }}
      '';
    }
    {
      template = [
        {
          command = "systemctl try-restart 'example.service'";
          destination = "${helpers.environmentFilesRoot}EnvFile";
          contents = ''
            {{ with secret "postgresql/creds/hydra" }}
            HYDRA_DBI=dbi:Pg:dbname=hydra;host=the-database-server;username={{ .Data.username }};password={{ .Data.password }};
            {{ end }}
          '';
        }
      ];
    };

  environmentOneFile = expectRenderedConfig
    {
      environment.templateFiles."example-a".file = ./helpers.tests.nix;
    }
    {
      template = [
        {
          command = "systemctl try-restart 'example.service'";
          destination = "${helpers.environmentFilesRoot}example-a.EnvFile";
          source = ./helpers.tests.nix;
        }
      ];
    };

  environmentChangeStop = expectRenderedConfig
    {
      environment = {
        changeAction = "stop";
        templateFiles."example-a".file = ./helpers.tests.nix;
      };
    }
    {
      template = [
        {
          command = "systemctl stop 'example.service'";
          destination = "${helpers.environmentFilesRoot}example-a.EnvFile";
          source = ./helpers.tests.nix;
        }
      ];
    };

  environmentChangeNone = expectRenderedConfig
    {
      environment = {
        changeAction = "none";
        templateFiles."example-a".file = ./helpers.tests.nix;
      };
    }
    {
      template = [
        {
          destination = "${helpers.environmentFilesRoot}example-a.EnvFile";
          source = ./helpers.tests.nix;
        }
      ];
    };

  environmentTwoFiles = expectRenderedConfig
    {
      environment.templateFiles = {
        "example-a".file = ./helpers.tests.nix;
        "example-b".file = ./helpers.tests.nix;
      };
    }
    {
      template = [
        {
          command = "systemctl try-restart 'example.service'";
          destination = "${helpers.environmentFilesRoot}example-a.EnvFile";
          source = ./helpers.tests.nix;
        }
        {
          command = "systemctl try-restart 'example.service'";
          destination = "${helpers.environmentFilesRoot}example-b.EnvFile";
          source = ./helpers.tests.nix;
        }
      ];
    };

  environmentInlineAndFiles = expectRenderedConfig
    {
      environment = {
        template = "FOO=BAR";
        templateFiles."example-a".file = ./helpers.tests.nix;
      };
    }
    {
      template = [
        {
          command = "systemctl try-restart 'example.service'";
          destination = "${helpers.environmentFilesRoot}EnvFile";
          contents = "FOO=BAR";
        }
        {
          command = "systemctl try-restart 'example.service'";
          destination = "${helpers.environmentFilesRoot}example-a.EnvFile";
          source = ./helpers.tests.nix;
        }
      ];
    };

  secretFileInline = expectRenderedConfig
    {
      secretFiles.files."example".template = "FOO=BAR";
    }
    {
      template = [
        {
          command = "systemctl try-restart 'example.service'";
          destination = "${helpers.secretFilesRoot}example";
          contents = "FOO=BAR";
          perms = "0400";
        }
      ];
    };

  secretFileTemplate = expectRenderedConfig
    {
      secretFiles.files."example".templateFile = ./helpers.tests.nix;
    }
    {
      template = [
        {
          command = "systemctl try-restart 'example.service'";
          destination = "${helpers.secretFilesRoot}example";
          source = ./helpers.tests.nix;
          perms = "0400";
        }
      ];
    };

  secretFileChangedDefaultChangeAction = expectRenderedConfig
    {
      secretFiles = {
        defaultChangeAction = "reload";
        files."example".template = "FOO=BAR";
      };
    }
    {
      template = [
        {
          command = "systemctl try-reload-or-restart 'example.service'";
          destination = "${helpers.secretFilesRoot}example";
          contents = "FOO=BAR";
          perms = "0400";
        }
      ];
    };

  secretFileChangedDefaultChangeActionOverride = expectRenderedConfig
    {
      secretFiles = {
        defaultChangeAction = "reload";
        files."example-a".template = "FOO=BAR";
        files."example-b" = {
          changeAction = "restart";
          template = "FOO=BAR";
          perms = "0600";
        };
      };
    }
    {
      template = [
        {
          command = "systemctl try-reload-or-restart 'example.service'";
          destination = "${helpers.secretFilesRoot}example-a";
          contents = "FOO=BAR";
          perms = "0400";
        }
        {
          command = "systemctl try-restart 'example.service'";
          destination = "${helpers.secretFilesRoot}example-b";
          contents = "FOO=BAR";
          perms = "0600";
        }
      ];
    };

  extraConfig = expectRenderedConfig
    {
      extraConfig = {
        vault = [{ address = "http://127.0.0.1:8200"; }];
        auto_auth = [
          {
            method = [
              {
                config = [
                  {
                    remove_secret_id_file_after_reading = false;
                    role_id_file_path = "role_id";
                    secret_id_file_path = "secret_id";
                  }
                ];
                type = "approle";
              }
            ];
          }
        ];
      };
      secretFiles = {
        defaultChangeAction = "reload";
        files."example-a".template = "FOO=BAR";
        files."example-b" = {
          changeAction = "restart";
          template = "FOO=BAR";
          perms = "0700";
        };
      };
    }
    {
      vault = [{ address = "http://127.0.0.1:8200"; }];
      auto_auth = [
        {
          method = [
            {
              config = [
                {
                  remove_secret_id_file_after_reading = false;
                  role_id_file_path = "role_id";
                  secret_id_file_path = "secret_id";
                }
              ];
              type = "approle";
            }
          ];
        }
      ];
      template = [
        {
          command = "systemctl try-reload-or-restart 'example.service'";
          destination = "${helpers.secretFilesRoot}example-a";
          contents = "FOO=BAR";
          perms = "0400";
        }
        {
          command = "systemctl try-restart 'example.service'";
          destination = "${helpers.secretFilesRoot}example-b";
          contents = "FOO=BAR";
          perms = "0700";
        }
      ];
    };
}
