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
    expectOk = cfg:
      let
        evaluatedCfg = evalCfg cfg;
        result = safeEval evaluatedCfg;

        filteredAsserts = builtins.map (asrt: asrt.message) (lib.filter (asrt: !asrt.assertion) result.value.assertions);
      in
      if !result.success
      then
        evaluatedCfg
      else if (filteredAsserts != [ ] || result.value.warnings != [ ])
      then
        throw "Unexpected assertions or warnings. Assertions: ${builtins.toJSON filteredAsserts}. Warnings: ${builtins.toJSON result.value.warnings}"
      else
        "ok";

    expectEvalError = cfg:
      let
        result = safeEval (evalCfg cfg);
      in
      if result.success
      then throw "Unexpectedly evaluated successfully."
      else "ok";

    expectAssertsWarns = { assertions ? [ ], warnings ? [ ] }: cfg:
      let
        evaluatedCfg = evalCfg cfg;
        result = safeEval evaluatedCfg;

        expect = {
          inherit assertions warnings;
        };
        actual = {
          assertions = builtins.map (asrt: asrt.message) (lib.filter (asrt: !asrt.assertion) result.value.assertions);
          inherit (result.value) warnings;
        };
      in
      if !result.success
      then
        evaluatedCfg
      else if (expect != actual)
      then
        throw "Unexpected assertions or warnings.\nExpected: ${builtins.toJSON expect}\nGot: ${builtins.toJSON actual}"
      else
        "ok";
  }
);
suite {
  nothingSet = expectOk {
    systemd.services.nothing-set = { };
    detsys.vaultAgent.systemd.services.nothing-set = { };
    detsys.vaultAgent.defaultAgentConfig = { };
  };

  envTemplate = expectOk {
    systemd.services.env-template = { };
    detsys.vaultAgent.systemd.services.env-template = {
      enable = true;

      environment.template = ''
        {{ with secret "postgresql/creds/hydra" }}
        HYDRA_DBI=dbi:Pg:dbname=hydra;host=the-database-server;username={{ .Data.username }};password={{ .Data.password }};
        {{ end }}
      '';
    };
  };

  envTemplateFile = expectOk {
    systemd.services.env-template-file = { };
    detsys.vaultAgent.systemd.services.env-template-file = {
      enable = true;
      environment.templateFiles."example".file = ./example.ctmpl;
    };
  };

  envTemplateFileNone = expectEvalError {
    systemd.services.env-template-file = { };
    detsys.vaultAgent.systemd.services.env-template-file = {
      enable = true;
      environment.templateFiles."example" = { };
    };
  };

  secretTemplateFile = expectOk {
    systemd.services.secret-template-file = { };
    detsys.vaultAgent.systemd.services.secret-template-file = {
      enable = true;
      secretFiles = {
        files."example".templateFile = ./example.ctmpl;
      };
    };
  };

  secretTemplate = expectOk {
    systemd.services.secret-template = { };
    detsys.vaultAgent.systemd.services.secret-template = {
      enable = true;
      secretFiles = {
        defaultChangeAction = "reload";
        files."example".template = ''
          ...
        '';
      };
    };
  };

  secretNoTemplate = expectAssertsWarns
    {
      assertions = [
        "detsys.vaultAgent.systemd.services.secret-template.secretFiles.example: One of the 'templateFile' and 'template' options must be specified."
      ];
    }
    {
      systemd.services.secret-template = { };
      detsys.vaultAgent.systemd.services.secret-template = {
        enable = true;
        secretFiles = {
          defaultChangeAction = "reload";
          files."example" = { };
        };
      };
    };

  secretMutuallyExclusiveTemplates = expectAssertsWarns
    {
      assertions = [
        "detsys.vaultAgent.systemd.services.secret-template.secretFiles.example: Both 'templateFile' and 'template' options are specified, but they are mutually exclusive."
      ];
    }
    {
      systemd.services.secret-template = { };
      detsys.vaultAgent.systemd.services.secret-template = {
        enable = true;
        secretFiles = {
          defaultChangeAction = "reload";
          files."example" = {
            template = "hi";
            templateFile = ./example.ctmpl;
          };
        };
      };
    };

  mainServiceDisablesPrivateTmp =
    expectAssertsWarns
      {
        assertions = [
          ''
            detsys.vaultAgent.systemd.services.no-private-tmp:
                The specified service has PrivateTmp= (systemd.exec(5)) disabled, but it must
                be enabled to share secrets between the sidecar service and the infected service.
          ''
        ];
      }
      {
        systemd.services.no-private-tmp.serviceConfig.PrivateTmp = false;
        detsys.vaultAgent.systemd.services.no-private-tmp = {
          enable = true;
          secretFiles = {
            defaultChangeAction = "reload";
            files."example".template = ''
              ...
            '';
          };
        };
      };

  globalConfig = expectOk {
    systemd.services.global-config = { };
    detsys.vaultAgent.systemd.services.global-config = { };
    detsys.vaultAgent.defaultAgentConfig = {
      vault = [{
        address = "http://127.0.0.1:8200";
        retry.num_retries = 1;
      }];
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
      template_config = {
        static_secret_render_interval = "5s";
        exit_on_retry_failure = true;
      };
    };
  };
}
