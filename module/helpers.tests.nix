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
        evaluatedCfg = evalCfg { detsys.systemd.service.example.vaultAgent = cfg; };
        result = safeEval evaluatedCfg;

        filteredAsserts = builtins.map (asrt: asrt.message) (lib.filter (asrt: !asrt.assertion) result.value.assertions);

        actual = (helpers.renderAgentConfig "example" result.value.detsys.systemd.service.example.vaultAgent);
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

  environmentOneFile = expectRenderedConfig
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
          destination = "./environment/example-a.EnvFile";
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
          destination = "./environment/example-a.EnvFile";
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

  secretFileInline = expectRenderedConfig
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

  secretFileTemplate = expectRenderedConfig
    {
      secretFiles.files."example".templateFile = ./helpers.test.nix;
    }
    {
      template = [
        {
          command = "systemctl restart 'example.service'";
          destination = "./files/example";
          source = ./helpers.test.nix;
        }
      ];
    };
}
