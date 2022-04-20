{ lib, config, ... }:
let
  inherit (lib)
    mkOption
    mkEnableOption
    types;

  inherit (import ./helpers.nix { inherit lib; })
    mkScopedMerge
    secretFilesRoot
    ;

  autoAuthMethodModule = types.submodule {
    freeformType = types.attrsOf types.unspecified;

    options = {
      type = mkOption {
        type = types.str;
      };

      config = mkOption {
        type = types.attrsOf types.unspecified;
      };
    };
  };

  autoAuthModule = types.submodule {
    freeformType = types.attrsOf types.unspecified;

    options = {
      method = mkOption {
        type = types.listOf autoAuthMethodModule;
        default = [ ];
      };
    };
  };

  templateConfigModule = types.submodule {
    freeformType = types.attrsOf types.unspecified;

    options = {
      exit_on_retry_failure = mkOption {
        type = types.bool;
        default = true;
      };
    };
  };

  agentConfigType = types.submodule {
    freeformType = types.attrsOf types.unspecified;

    options = {
      auto_auth = mkOption {
        type = autoAuthModule;
        default = { };
      };

      template_config = mkOption {
        type = templateConfigModule;
        default = { };
      };
    };
  };

  vaultAgentModule = { ... }: {
    options = {
      enable = mkEnableOption "vaultAgent";

      agentConfig = mkOption {
        description = "Vault agent configuration. The only place to specify vault and auto_auth config.";
        type = agentConfigType;
        default = config.detsys.vaultAgent.defaultAgentConfig;
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
          description = "A consul-template snippet which produces EnvironmentFile-compatible output.";
          type = types.nullOr types.lines;
          default = null;
        };

        perms = mkOption {
          readOnly = true;
          internal = true;
          description = "The octal mode of the environment file as a string.";
          type = types.str;
          default = "0400";
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

  vaultAgentEnvironmentFileModule = { ... }: {
    options = {
      file = mkOption {
        description = "A consul-template file which produces EnvironmentFile-compatible output.";
        type = types.path;
      };

      perms = mkOption {
        readOnly = true;
        internal = true;
        description = "The octal mode of the environment file as a string.";
        type = types.str;
        default = "0400";
      };
    };
  };

  vaultAgentSecretFilesModule = { name, ... }: {
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
        description = "A consul-template file. Conflicts with template.";
        type = types.nullOr types.path;
        default = null;
      };

      template = mkOption {
        description = "A consul-template snippet. Conflicts with templateFile.";
        type = types.nullOr types.lines;
        default = null;
      };

      perms = mkOption {
        description = "The octal mode of the secret file as a string.";
        type = types.str;
        default = "0400";
      };

      path = mkOption {
        readOnly = true;
        description = "The path to the secret file inside the unit's namespace's PrivateTmp.";
        type = types.str;
        default = "${secretFilesRoot}${name}";
      };
    };
  };

in
{
  options.detsys.vaultAgent = {
    defaultAgentConfig = mkOption {
      description = "Default Vault agent configuration. Defers to individual <code>agentConfig</code>s, if set.";
      type = agentConfigType;
      default = { };
    };

    systemd.services = mkOption {
      type = types.attrsOf (types.submodule vaultAgentModule);
      default = { };
    };
  };

  config = lib.mkMerge [
    (mkScopedMerge [ [ "assertions" ] ]
      (lib.mapAttrsToList
        (serviceName: serviceConfig: {
          assertions = lib.flatten (lib.mapAttrsToList
            (secretFileName: secretFileConfig: [
              {
                assertion = !(secretFileConfig.templateFile == null && secretFileConfig.template == null);
                message = "detsys.vaultAgent.systemd.services.${serviceName}.secretFiles.${secretFileName}: One of the 'templateFile' and 'template' options must be specified.";
              }
              {
                assertion = !(secretFileConfig.templateFile != null && secretFileConfig.template != null);
                message = "detsys.vaultAgent.systemd.services.${serviceName}.secretFiles.${secretFileName}: Both 'templateFile' and 'template' options are specified, but they are mutually exclusive.";
              }
            ])
            serviceConfig.secretFiles.files);
        })
        config.detsys.vaultAgent.systemd.services))
    (mkScopedMerge [ [ "assertions" ] ]
      (lib.mapAttrsToList
        (serviceName: _serviceConfig: {
          assertions = [
            {
              assertion =
                let
                  systemdServiceConfig = config.systemd.services."${serviceName}".serviceConfig;
                in
                  !(systemdServiceConfig ? PrivateTmp && !systemdServiceConfig.PrivateTmp);
              message = ''
                detsys.vaultAgent.systemd.services.${serviceName}:
                    The specified service has PrivateTmp= (systemd.exec(5)) disabled, but it must
                    be enabled to share secrets between the sidecar service and the infected service.
              '';
            }
          ];
        })
        config.detsys.vaultAgent.systemd.services))
    (mkScopedMerge [ [ "assertions" ] ]
      (lib.mapAttrsToList
        (serviceName: serviceConfig: {
          assertions = [
            {
              assertion =
                serviceConfig.agentConfig.template_config.exit_on_retry_failure;
              message = ''
                detsys.vaultAgent.systemd.services.${serviceName}:
                    The agent config has template_config.exit_on_retry_failure
                    set to false. This is not supported.
              '';
            }
          ];
        })
        config.detsys.vaultAgent.systemd.services))
    {
      assertions = [
        {
          assertion =
            config.detsys.vaultAgent.defaultAgentConfig.template_config.exit_on_retry_failure;
          message = ''
            detsys.vaultAgent.defaultAgentConfig:
                The default agent config has template_config.exit_on_retry_failure
                set to false. This is not supported.
          '';
        }
      ];
    }
  ];
}
