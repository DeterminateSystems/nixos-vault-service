{ pkgs, lib, config, ... }:
let
  inherit (import ./helpers.nix { inherit lib; })
    mkScopedMerge
    renderAgentConfig
    secretFilesRoot
    environmentFilesRoot;

  precreateDirectories = serviceName: { user ? null, group ? null }:
    let
      userEscaped = lib.escapeShellArg (toString user);
      groupEscaped = lib.escapeShellArg (toString group);
    in
    pkgs.writeShellScript "precreate-dirs-for-${serviceName}" ''
      set -eux
      (
        umask 027
        mkdir -p ${environmentFilesRoot}

        mkdir -p ${secretFilesRoot}
        chown ${lib.optionalString (user != null) userEscaped}:${lib.optionalString (group != null) groupEscaped} ${secretFilesRoot}
      )
    '';

  makeAgentService = { serviceName, agentConfig, systemdUnitConfig }:
    let
      fullServiceName = "${serviceName}.service";
      agentCfgFile = pkgs.writeText "detsys-vaultAgent-${serviceName}.json"
        (builtins.toJSON agentConfig.agentConfig);
      systemdServiceConfig = systemdUnitConfig.serviceConfig;

    in
    {
      requires = [ "network.target" ];
      after = [ "network.target" ];

      wantedBy = [ fullServiceName ];
      before = [ fullServiceName ];

      # Needs getent in PATH
      path = [ pkgs.glibc ];

      unitConfig = {
        StartLimitIntervalSec = lib.mkDefault 30;
        StartLimitBurst = lib.mkDefault 6;
      };

      serviceConfig = {
        PrivateTmp = lib.mkDefault true;
        Restart = lib.mkDefault "on-failure";
        RestartSec = lib.mkDefault 5;
        Type = "notify";

        ExecStartPre = precreateDirectories serviceName
          (lib.optionalAttrs (systemdServiceConfig ? User) { user = systemdServiceConfig.User; }
            // lib.optionalAttrs (systemdServiceConfig ? Group) { group = systemdServiceConfig.Group; });

        ExecStart =
          let
            filesToMonitor = pkgs.writeText "files-to-monitor"
              (builtins.concatStringsSep "\n"
                (map (path: path.destination) agentConfig.environmentFileTemplates
                  ++ map (path: path.destination) agentConfig.secretFileTemplates));
          in
          builtins.concatStringsSep " " [
            "${pkgs.detsys-messenger}/bin/messenger"
            "--vault-binary"
            "${pkgs.vault}/bin/vault"
            "--agent-config"
            agentCfgFile
            "--files-to-monitor"
            filesToMonitor
            "-vvvv"
          ];
      };

    };

  makeTargetServiceInfection = { serviceName, agentConfig }:
    let
      sidecarServiceName = "detsys-vaultAgent-${serviceName}.service";
    in
    {
      after = [ sidecarServiceName ];
      bindsTo = [ sidecarServiceName ];
      unitConfig = {
        JoinsNamespaceOf = sidecarServiceName;
      };
      serviceConfig = {
        PrivateTmp = lib.mkDefault true;
        EnvironmentFile = agentConfig.environmentFiles;
      };
    };
in
{
  imports = [
    ./definition.nix
  ];

  config = lib.mkMerge [
    (mkScopedMerge [ [ "systemd" "services" ] ]
      (lib.mapAttrsToList
        (serviceName: serviceConfig:
          let
            agentConfig = renderAgentConfig serviceName config.systemd.services.${serviceName} serviceConfig;
          in
          {
            systemd.services = {
              "${serviceName}" = makeTargetServiceInfection {
                inherit serviceName agentConfig;
              };
              "detsys-vaultAgent-${serviceName}" = makeAgentService {
                inherit serviceName agentConfig;
                systemdUnitConfig = config.systemd.services."${serviceName}";
              };
            };
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
                    The agent config does not specify template_config.exit_on_retry_failure or has
                    it set to false. This is not supported.
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
                The default agent config does not specify template_config.exit_on_retry_failure
                or has it set to false. This is not supported.
          '';
        }
      ];
    }
  ];
}
