{ lib, config, ... }:
let
  inherit (lib) mkOption mkEnableOption types;
  inherit (import ./helpers.nix { inherit lib; }) mkScopedMerge;

  perServiceModule = { name, config, ... }: {
    options = {
      vaultAgent = mkOption {
        type = types.submodule vaultAgentModule;
      };
    };
  };

  vaultAgentModule = { config, ... }: {
    options = {
      enable = mkEnableOption "vaultAgent";

      extraConfig = mkOption {
        description = "Extra assorted config bits. The only place to specify vault and auto_auth config. To be replaced.";
        type = types.attrsOf types.unspecified;
        default = { };
      };

      # !!! should this be a submodule?
      environment = {
        changeAction = mkOption {
          description = "What to do if any secrets in the environment change.";
          type = types.enum [
            "none"
            "restart"
            "stop"
          ];
          default = "restart";
        };

        templateFiles = mkOption {
          type = types.attrsOf (types.submodule vaultAgentEnvironmentFileModule);
          default = { };
        };

        template = mkOption {
          description = "A consult-template snippet which produces EnvironmentFile-compatible output.";
          type = types.nullOr types.lines;
          default = null;
        };
      };

      # !!! should this be a submodule?
      secretFiles = {
        defaultChangeAction = mkOption {
          description = ''
            What to do if any secrets in the files change.
            Provides the default value, and is overridable per secret file.
          '';
          type = types.enum [
            "none"
            "reload"
            "restart"
            "stop"
          ];
          default = "restart";
        };

        files = mkOption {
          type = types.attrsOf (types.submodule vaultAgentSecretFilesModule);
          default = { };
        };
      };
    };
  };

  vaultAgentEnvironmentFileModule = { config, ... }: {
    options = {
      file = mkOption {
        description = "A consult-template file which produces EnvironmentFile-compatible output.";
        type = types.path;
      };
    };
  };

  vaultAgentSecretFilesModule = { name, config, ... }: {
    options = {
      changeAction = mkOption {
        description = ''
          What to do if any secrets in this file changes.
          If left unspecified, the defaultChangeAction for this service takes effect.
        '';
        type = types.nullOr (types.enum [
          "none"
          "reload"
          "restart"
          "stop"
        ]);
        default = null;
      };

      templateFile = mkOption {
        description = "A consult-template file. Conflicts with template.";
        type = types.nullOr types.path;
        default = null;
      };

      template = mkOption {
        description = "A consult-template snippet. Conflicts with templateFile.";
        type = types.nullOr types.lines;
        default = null;
      };
    };
  };

in
{
  options.detsys.systemd.service = mkOption {
    type = types.attrsOf (types.submodule perServiceModule);
  };

  config = mkScopedMerge [ [ "assertions" ] ]
    (lib.mapAttrsToList
      (serviceName: serviceConfig: {
        assertions = lib.flatten (lib.mapAttrsToList
          (secretFileName: secretFileConfig: [
            {
              assertion = !(secretFileConfig.templateFile == null && secretFileConfig.template == null);
              message = "detsys.systemd.service.${serviceName}.vaultAgent.secretFiles.${secretFileName}: One of the 'templateFile' and 'template' options must be specified.";
            }
            {
              assertion = !(secretFileConfig.templateFile != null && secretFileConfig.template != null);
              message = "detsys.systemd.service.${serviceName}.vaultAgent.secretFiles.${secretFileName}: Both 'templateFile' and 'template' options must be specified, but they are mutually exclusive.";
            }
          ])
          serviceConfig.vaultAgent.secretFiles.files);
      })
      config.detsys.systemd.service
    );
}
