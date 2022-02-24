{ lib, config, ... }:

let
  mkLimitedMerge = attrs:
    let
      pluckFunc = attr: values: lib.mkMerge
        (builtins.map
          (v:
            lib.mkIf
              (lib.hasAttrByPath attr v)
              (lib.getAttrFromPath attr v)
          )
          values
        );

      pluckFuncs = attrs: values:
        lib.mkMerge (builtins.map
          (attr: lib.setAttrByPath attr (pluckFunc attr values))
          attrs);

    in
    values:
    pluckFuncs attrs values;
in
let
  inherit (lib) mkOption mkEnableOption types;

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

  config = mkLimitedMerge [ [ "assertions" ] ]
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
