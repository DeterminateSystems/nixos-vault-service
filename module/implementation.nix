{ pkgs, lib, config, ... }:
let
  helpers = import ./helpers.nix { inherit lib; };
  inherit (helpers)
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

  waitFor = serviceName: files:
    let
      waiter = lib.concatMapStringsSep "\n"
        (file:
          ''
            if [ ! -f ${lib.escapeShellArg file.destination} ]; then
              echo Waiting for ${lib.escapeShellArg file.destination} to exist...
              (while [ ! -f ${lib.escapeShellArg file.destination} ]; do sleep 1; done) &
            fi
          '')
        files;
    in
    pkgs.writeShellScript "wait-for-${serviceName}" ''
      set -eux
      ${waiter}
      wait
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
        # BindsTo = [ fullServiceName ];
        StartLimitIntervalSec = 200;
        StartLimitBurst = 6;
      };

      serviceConfig = {
        PrivateTmp = lib.mkDefault true;
        ExecStart = "${pkgs.vault}/bin/vault agent -log-level=trace -config ${agentCfgFile}";
        ExecStartPre = precreateDirectories serviceName
          ({ }
            // lib.optionalAttrs (systemdServiceConfig ? User) { user = systemdServiceConfig.User; }
            // lib.optionalAttrs (systemdServiceConfig ? Group) { group = systemdServiceConfig.Group; });
        ExecStartPost = waitFor serviceName
          (map (path: { prefix = environmentFilesRoot; inherit (path) destination perms; }) agentConfig.environmentFileTemplates
            ++ map (path: { prefix = secretFilesRoot; inherit (path) destination perms; }) agentConfig.secretFileTemplates);

        Restart = "on-failure";
        RestartSec = 5;
      };

    };

  makeTargetServiceInfection = { serviceName, agentConfig }:
    let
      sidecarServiceName = "detsys-vaultAgent-${serviceName}.service";
    in
    {
      after = [ sidecarServiceName ];
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
            agentConfig = renderAgentConfig serviceName config.systemd.services.${serviceName} serviceConfig.vaultAgent;
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
        config.detsys.systemd.services))
  ];
}
