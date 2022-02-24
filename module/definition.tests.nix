{ lib, ... }:
let
  evalCfg = config: (lib.evalModules {
    modules = [
      ./definition.nix
      config
    ];
  }).config;

  expectError = val: expectSuccess false val; # point-free is for the Mets
  expectOk = val: expectSuccess true val;
  expectSuccess = expectedSuccess: val:
    (builtins.tryEval
      (builtins.deepSeq val val)
    ) // { inherit expectedSuccess; originalValue = val; };

  expectOkCfg = cfg: expectOk (evalCfg cfg);
  expectErrorCfg = cfg: expectError (evalCfg cfg);

  suite = { ... } @ tests:
    builtins.deepSeq
      (builtins.mapAttrs
        (name: { success, expectedSuccess, value, originalValue } @ args:
          let
            failureMessage = "test case '${name}': Evaluation was expected to ${if expectedSuccess then "succeed" else "fail"}, but it ${if success then "succeeded" else "failed"}.";

            handleMismatchedExpectation = if success then handleUnexpectedSuccess else handleUnexpectedFailure;
            handleUnexpectedSuccess = throw failureMessage;
            handleUnexpectedFailure = builtins.trace
              failureMessage
              (builtins.deepSeq originalValue null);

          in
          if
            success == expectedSuccess
          then
            null
          else
            handleMismatchedExpectation
        )
        tests)
      "ok";
in
suite {
  nothingSet = expectOkCfg {
    detsys.systemd.service.nothing-set.vaultAgent = { };
  };

  envTemplate = expectOkCfg {
    detsys.systemd.service.env-template.vaultAgent = {
      enable = true;

      environment.template = ''
        {{ with secret "postgresql/creds/hydra" }}
        HYDRA_DBI=dbi:Pg:dbname=hydra;host=the-database-server;username={{ .Data.username }};password={{ .Data.password }};
        {{ end }}
      '';
    };
  };

  envTemplateFile = expectOkCfg {
    detsys.systemd.service.env-template-file.vaultAgent = {
      enable = true;
      environment.templateFiles."example".file = ./example.ctmpl;
    };
  };

  envTemplateFileNone = expectErrorCfg {
    detsys.systemd.service.env-template-file.vaultAgent = {
      enable = true;
      environment.templateFiles."example" = { };
    };
  };

  secretTemplateFile = expectOkCfg {
    detsys.systemd.service.secret-template-file.vaultAgent = {
      enable = true;
      secretFiles = {
        files."example".templateFile = ./example.ctmpl;
      };
    };
  };

  secretTemplate = expectOkCfg {
    detsys.systemd.service.secret-template.vaultAgent = {
      enable = true;
      secretFiles = {
        defaultChangeAction = "reload";
        files."example".template = ''
          ...
        '';
      };
    };
  };
}
