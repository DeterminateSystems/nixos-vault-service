{ nixpkgs, lib, ... }:
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
          "${nixpkgs}/nixos/modules/misc/assertions.nix"
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
    expectRenderedConfig = globalCfg: cfg: expect:
      let
        evaluatedCfg = evalCfg {
          systemd.services.example' = { };
          detsys.vaultAgent.defaultAgentConfig = globalCfg;
          detsys.vaultAgent.systemd.services.example' = cfg;
        };
        result = safeEval evaluatedCfg;

        filteredAsserts = builtins.map (asrt: asrt.message) (lib.filter (asrt: !asrt.assertion) result.value.assertions);

        actual = (helpers.renderAgentConfig "example'" { } result.value.detsys.vaultAgent.systemd.services.example').agentConfig;
      in
      if !result.success
      then
        evaluatedCfg
      else if (filteredAsserts != [ ] || result.value.warnings != [ ])
      then
        throw "Unexpected assertions or warnings. Assertions: ${builtins.toJSON filteredAsserts}. Warnings: ${builtins.toJSON result.value.warnings}"
      else if actual != expect
      then
        throw "Mismatched configuration.\nExp: ${builtins.toJSON expect}\nGot: ${builtins.toJSON actual}"
      else "ok";
  }
);
{
  nothingSet = expectRenderedConfig
    { }
    { }
    {
      auto_auth.method = [ ];
      template_config.exit_on_retry_failure = true;
      template = [ ];
    };

  environmentOnlyInline = expectRenderedConfig
    { }
    {
      environment.template = ''
        {{ with secret "postgresql/creds/hydra" }}
        HYDRA_DBI=dbi:Pg:dbname=hydra;host=the-database-server;username={{ .Data.username }};password={{ .Data.password }};
        {{ end }}
      '';
    }
    {
      auto_auth.method = [ ];
      template_config.exit_on_retry_failure = true;
      template = [
        {
          command = "systemctl try-restart 'example'\\''.service'";
          destination = "${helpers.environmentFilesRoot}example'/EnvFile";
          contents = ''
            {{ with secret "postgresql/creds/hydra" }}
            HYDRA_DBI=dbi:Pg:dbname=hydra;host=the-database-server;username={{ .Data.username }};password={{ .Data.password }};
            {{ end }}
          '';
          perms = "0400";
        }
      ];
    };

  environmentOneFile = expectRenderedConfig
    { }
    {
      environment.templateFiles."example'-a".file = ./helpers.tests.nix;
    }
    {
      auto_auth.method = [ ];
      template_config.exit_on_retry_failure = true;
      template = [
        {
          command = "systemctl try-restart 'example'\\''.service'";
          destination = "${helpers.environmentFilesRoot}example'/example\'-a.EnvFile";
          source = ./helpers.tests.nix;
          perms = "0400";
        }
      ];
    };

  environmentChangeStop = expectRenderedConfig
    { }
    {
      environment = {
        changeAction = "stop";
        templateFiles."example'-a".file = ./helpers.tests.nix;
      };
    }
    {
      auto_auth.method = [ ];
      template_config.exit_on_retry_failure = true;
      template = [
        {
          command = "systemctl stop 'example'\\''.service'";
          destination = "${helpers.environmentFilesRoot}example'/example'-a.EnvFile";
          source = ./helpers.tests.nix;
          perms = "0400";
        }
      ];
    };

  environmentChangeNone = expectRenderedConfig
    { }
    {
      environment = {
        changeAction = "none";
        templateFiles."example'-a".file = ./helpers.tests.nix;
      };
    }
    {
      auto_auth.method = [ ];
      template_config.exit_on_retry_failure = true;
      template = [
        {
          destination = "${helpers.environmentFilesRoot}example'/example'-a.EnvFile";
          source = ./helpers.tests.nix;
          perms = "0400";
        }
      ];
    };

  environmentTwoFiles = expectRenderedConfig
    { }
    {
      environment.templateFiles = {
        "example\'-a".file = ./helpers.tests.nix;
        "example'-b".file = ./helpers.tests.nix;
      };
    }
    {
      auto_auth.method = [ ];
      template_config.exit_on_retry_failure = true;
      template = [
        {
          command = "systemctl try-restart 'example'\\''.service'";
          destination = "${helpers.environmentFilesRoot}example'/example\'-a.EnvFile";
          source = ./helpers.tests.nix;
          perms = "0400";
        }
        {
          command = "systemctl try-restart 'example'\\''.service'";
          destination = "${helpers.environmentFilesRoot}example'/example'-b.EnvFile";
          source = ./helpers.tests.nix;
          perms = "0400";
        }
      ];
    };

  environmentInlineAndFiles = expectRenderedConfig
    { }
    {
      environment = {
        template = "FOO=BAR";
        templateFiles."example\'-a".file = ./helpers.tests.nix;
      };
    }
    {
      auto_auth.method = [ ];
      template_config.exit_on_retry_failure = true;
      template = [
        {
          command = "systemctl try-restart 'example'\\''.service'";
          destination = "${helpers.environmentFilesRoot}example'/EnvFile";
          contents = "FOO=BAR";
          perms = "0400";
        }
        {
          command = "systemctl try-restart 'example'\\''.service'";
          destination = "${helpers.environmentFilesRoot}example'/example\'-a.EnvFile";
          source = ./helpers.tests.nix;
          perms = "0400";
        }
      ];
    };

  secretFileInline = expectRenderedConfig
    { }
    {
      secretFiles.files."example'".template = "FOO=BAR";
    }
    {
      auto_auth.method = [ ];
      template_config.exit_on_retry_failure = true;
      template = [
        {
          command = "chown : '${helpers.secretFilesRoot}example'\\''';systemctl try-restart 'example'\\''.service'";
          destination = "${helpers.secretFilesRoot}example\'";
          contents = "FOO=BAR";
          perms = "0400";
        }
      ];
    };

  secretFileTemplate = expectRenderedConfig
    { }
    {
      secretFiles.files."example'".templateFile = ./helpers.tests.nix;
    }
    {
      auto_auth.method = [ ];
      template_config.exit_on_retry_failure = true;
      template = [
        {
          command = "chown : '${helpers.secretFilesRoot}example'\\''';systemctl try-restart 'example'\\''.service'";
          destination = "${helpers.secretFilesRoot}example\'";
          source = ./helpers.tests.nix;
          perms = "0400";
        }
      ];
    };

  secretFileChangedDefaultChangeAction = expectRenderedConfig
    { }
    {
      secretFiles = {
        defaultChangeAction = "reload";
        files."example'".template = "FOO=BAR";
      };
    }
    {
      auto_auth.method = [ ];
      template_config.exit_on_retry_failure = true;
      template = [
        {
          command = "chown : '${helpers.secretFilesRoot}example'\\''';systemctl try-reload-or-restart 'example'\\''.service'";
          destination = "${helpers.secretFilesRoot}example'";
          contents = "FOO=BAR";
          perms = "0400";
        }
      ];
    };

  secretFileChangedDefaultChangeActionOverride = expectRenderedConfig
    { }
    {
      secretFiles = {
        defaultChangeAction = "reload";
        files."example\'-a".template = "FOO=BAR";
        files."example'-b" = {
          changeAction = "restart";
          template = "FOO=BAR";
          perms = "0600";
        };
      };
    }
    {
      auto_auth.method = [ ];
      template_config.exit_on_retry_failure = true;
      template = [
        {
          command = "chown : '${helpers.secretFilesRoot}example'\\''-a';systemctl try-reload-or-restart 'example'\\''.service'";
          destination = "${helpers.secretFilesRoot}example\'-a";
          contents = "FOO=BAR";
          perms = "0400";
        }
        {
          command = "chown : '${helpers.secretFilesRoot}example'\\''-b';systemctl try-restart 'example'\\''.service'";
          destination = "${helpers.secretFilesRoot}example\'-b";
          contents = "FOO=BAR";
          perms = "0600";
        }
      ];
    };

  agentConfig = expectRenderedConfig
    { }
    {
      agentConfig = {
        vault = { address = "http://127.0.0.1:8200"; };
        auto_auth = {
          method = [{
            config = {
              remove_secret_id_file_after_reading = false;
              role_id_file_path = "role_id";
              secret_id_file_path = "secret_id";
            };
            type = "approle";
          }];
        };
      };
      secretFiles = {
        defaultChangeAction = "reload";
        files."example\'-a".template = "FOO=BAR";
        files."example'-b" = {
          changeAction = "restart";
          template = "FOO=BAR";
          perms = "0700";
        };
      };
    }
    {
      vault = { address = "http://127.0.0.1:8200"; };
      auto_auth = {
        method = [{
          config = {
            remove_secret_id_file_after_reading = false;
            role_id_file_path = "role_id";
            secret_id_file_path = "secret_id";
          };
          type = "approle";
        }];
      };
      template_config.exit_on_retry_failure = true;
      template = [
        {
          command = "chown : '${helpers.secretFilesRoot}example'\\''-a';systemctl try-reload-or-restart 'example'\\''.service'";
          destination = "${helpers.secretFilesRoot}example\'-a";
          contents = "FOO=BAR";
          perms = "0400";
        }
        {
          command = "chown : '${helpers.secretFilesRoot}example'\\''-b';systemctl try-restart 'example'\\''.service'";
          destination = "${helpers.secretFilesRoot}example'-b";
          contents = "FOO=BAR";
          perms = "0700";
        }
      ];
    };

  defaultAgentConfig = expectRenderedConfig
    {
      vault = { address = "http://127.0.0.1:8200"; };
      auto_auth = {
        method = [{
          config = {
            remove_secret_id_file_after_reading = false;
            role_id_file_path = "role_id";
            secret_id_file_path = "secret_id";
          };
          type = "approle";
        }];
      };
    }
    {
      secretFiles = {
        defaultChangeAction = "reload";
        files."example\'-a".template = "FOO=BAR";
        files."example'-b" = {
          changeAction = "restart";
          template = "FOO=BAR";
          perms = "0700";
        };
      };
    }
    {
      vault = { address = "http://127.0.0.1:8200"; };
      auto_auth = {
        method = [{
          config = {
            remove_secret_id_file_after_reading = false;
            role_id_file_path = "role_id";
            secret_id_file_path = "secret_id";
          };
          type = "approle";
        }];
      };
      template_config.exit_on_retry_failure = true;
      template = [
        {
          command = "chown : '${helpers.secretFilesRoot}example'\\''-a';systemctl try-reload-or-restart 'example'\\''.service'";
          destination = "${helpers.secretFilesRoot}example\'-a";
          contents = "FOO=BAR";
          perms = "0400";
        }
        {
          command = "chown : '${helpers.secretFilesRoot}example'\\''-b';systemctl try-restart 'example'\\''.service'";
          destination = "${helpers.secretFilesRoot}example\'-b";
          contents = "FOO=BAR";
          perms = "0700";
        }
      ];
    };
}
