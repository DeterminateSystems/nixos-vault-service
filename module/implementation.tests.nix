{ nixpkgs, lib, ... }:
let
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
      (lib.nixosSystem
        {
          system = "x86_64-linux";
          modules = [
            ./implementation.nix
            config
          ];
        }
      ).config;

    safeEval = val:
      (builtins.tryEval
        (builtins.deepSeq val val)
      ) // { originalValue = val; };
  in
  {
    expectRenderedService = cfg: expect:
      let
        evaluatedCfg = evalCfg { detsys.systemd.service.example.vaultAgent = cfg; };
        result = safeEval evaluatedCfg;

        filteredAsserts = builtins.map (asrt: asrt.message) (lib.filter (asrt: !asrt.assertion) result.value.assertions);

        actual = result.value.systemd.services.example;
      in
      if !result.success
      then
        evaluatedCfg.systemd.services.example
      else if (filteredAsserts != [ ] || result.value.warnings != [ ])
      then
        throw "Unexpected assertions or warnings. Assertions: ${builtins.toJSON filteredAsserts}. Warnings: ${builtins.toJSON result.value.warnings}"
      else if actual != expect
      then
        throw "Mismatched configuration. Expected: ${builtins.toJSON expect} Got: ${builtins.toJSON actual}"
      else builtins.trace (builtins.toJSON actual) "ok";
  }
);
{
  nothingSet = expectRenderedService
    { }
    {
      template = [ ];
    };

  environmentOnlyInline = expectRenderedService
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
          command = "systemctl restart 'example.service'";
          destination = "./environment.EnvFile";
          contents = ''
            {{ with secret "postgresql/creds/hydra" }}
            HYDRA_DBI=dbi:Pg:dbname=hydra;host=the-database-server;username={{ .Data.username }};password={{ .Data.password }};
            {{ end }}
          '';
        }
      ];
    };

  environmentOneFile = expectRenderedService
    {
      environment.templateFiles."example-a".file = ./helpers.tests.nix;
    }
    {
      template = [
        {
          command = "systemctl restart 'example.service'";
          destination = "./environment/example-a.EnvFile";
          source = ./helpers.tests.nix;
        }
      ];
    };

  environmentChangeStop = expectRenderedService
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
          destination = "./environment/example-a.EnvFile";
          source = ./helpers.tests.nix;
        }
      ];
    };

  environmentChangeNone = expectRenderedService
    {
      environment = {
        changeAction = "none";
        templateFiles."example-a".file = ./helpers.tests.nix;
      };
    }
    {
      template = [
        {
          destination = "./environment/example-a.EnvFile";
          source = ./helpers.tests.nix;
        }
      ];
    };

  environmentTwoFiles = expectRenderedService
    {
      environment.templateFiles = {
        "example-a".file = ./helpers.tests.nix;
        "example-b".file = ./helpers.tests.nix;
      };
    }
    {
      template = [
        {
          command = "systemctl restart 'example.service'";
          destination = "./environment/example-a.EnvFile";
          source = ./helpers.tests.nix;
        }
        {
          command = "systemctl restart 'example.service'";
          destination = "./environment/example-b.EnvFile";
          source = ./helpers.tests.nix;
        }
      ];
    };

  environmentInlineAndFiles = expectRenderedService
    {
      environment = {
        template = "FOO=BAR";
        templateFiles."example-a".file = ./helpers.tests.nix;
      };
    }
    {
      template = [
        {
          command = "systemctl restart 'example.service'";
          destination = "./environment.EnvFile";
          contents = "FOO=BAR";
        }
        {
          command = "systemctl restart 'example.service'";
          destination = "./environment/example-a.EnvFile";
          source = ./helpers.tests.nix;
        }
      ];
    };

  secretFileInline = expectRenderedService
    {
      secretFiles.files."example".template = "FOO=BAR";
    }
    {
      template = [
        {
          command = "systemctl restart 'example.service'";
          destination = "./files/example";
          contents = "FOO=BAR";
        }
      ];
    };

  secretFileTemplate = expectRenderedService
    {
      secretFiles.files."example".templateFile = ./helpers.tests.nix;
    }
    {
      template = [
        {
          command = "systemctl restart 'example.service'";
          destination = "./files/example";
          source = ./helpers.tests.nix;
        }
      ];
    };

  secretFileChangedDefaultChangeAction = expectRenderedService
    {
      secretFiles = {
        defaultChangeAction = "reload";
        files."example".template = "FOO=BAR";
      };
    }
    {
      template = [
        {
          command = "systemctl reload 'example.service'";
          destination = "./files/example";
          contents = "FOO=BAR";
        }
      ];
    };

  secretFileChangedDefaultChangeActionOverride = expectRenderedService
    {
      secretFiles = {
        defaultChangeAction = "reload";
        files."example-a".template = "FOO=BAR";
        files."example-b" = {
          changeAction = "restart";
          template = "FOO=BAR";
        };
      };
    }
    {
      template = [
        {
          command = "systemctl reload 'example.service'";
          destination = "./files/example-a";
          contents = "FOO=BAR";
        }
        {
          command = "systemctl restart 'example.service'";
          destination = "./files/example-b";
          contents = "FOO=BAR";
        }
      ];
    };

  extraConfig = expectRenderedService
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
        };
      };
    }
    {
      template = [
        {
          command = "systemctl reload 'example.service'";
          destination = "./files/example-a";
          contents = "FOO=BAR";
        }
        {
          command = "systemctl restart 'example.service'";
          destination = "./files/example-b";
          contents = "FOO=BAR";
        }
      ];
    };
}
