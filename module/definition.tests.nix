{ path, lib, ... }:
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
        throw "Unexpected assertions or warnings. Expected: ${builtins.toJSON expect} Got: ${builtins.toJSON actual}"
      else
        "ok";
  }
);
suite {
  nothingSet = expectOk {
    detsys.systemd.services.nothing-set.vaultAgent = { };
  };

  envTemplate = expectOk {
    detsys.systemd.services.env-template.vaultAgent = {
      enable = true;

      environment.template = ''
        {{ with secret "postgresql/creds/hydra" }}
        HYDRA_DBI=dbi:Pg:dbname=hydra;host=the-database-server;username={{ .Data.username }};password={{ .Data.password }};
        {{ end }}
      '';
    };
  };

  envTemplateFile = expectOk {
    detsys.systemd.services.env-template-file.vaultAgent = {
      enable = true;
      environment.templateFiles."example".file = ./example.ctmpl;
    };
  };

  envTemplateFileNone = expectEvalError {
    detsys.systemd.services.env-template-file.vaultAgent = {
      enable = true;
      environment.templateFiles."example" = { };
    };
  };

  secretTemplateFile = expectOk {
    detsys.systemd.services.secret-template-file.vaultAgent = {
      enable = true;
      secretFiles = {
        files."example".templateFile = ./example.ctmpl;
      };
    };
  };

  secretTemplate = expectOk {
    detsys.systemd.services.secret-template.vaultAgent = {
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
        "detsys.systemd.services.secret-template.vaultAgent.secretFiles.example: One of the 'templateFile' and 'template' options must be specified."
      ];
    }
    {
      detsys.systemd.services.secret-template.vaultAgent = {
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
        "detsys.systemd.services.secret-template.vaultAgent.secretFiles.example: Both 'templateFile' and 'template' options must be specified, but they are mutually exclusive."
      ];
    }
    {
      detsys.systemd.services.secret-template.vaultAgent = {
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
}
