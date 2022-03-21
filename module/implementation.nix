{ pkgs, lib, config, ... }:
let
  helpers = import ./helpers.nix { inherit lib; };
  inherit (helpers)
    mkScopedMerge
    renderAgentConfig;

  precreateTemplateFiles = serviceName: files: { user ? null, group ? null }:
    let
      create = lib.concatMapStringsSep "\n"
        (file:
          let
            dest = lib.escapeShellArg file;
          in
          ''
            (
              umask 027
              mkdir -p "$(dirname ${dest})"
              chown ${lib.optionalString (user != null) (lib.escapeShellArg (toString user))}:${lib.optionalString (group != null) (lib.escapeShellArg (toString group))} "$(dirname ${dest})"
              umask 777
              touch ${dest}
              chown ${lib.optionalString (user != null) (lib.escapeShellArg (toString user))}:${lib.optionalString (group != null) (lib.escapeShellArg (toString group))} ${dest}
            )
          '')
        files;
    in
    pkgs.writeShellScript "precreate-files-for-${serviceName}" ''
      set -eux
      ${create}
    '';

  waitFor = serviceName: files:
    let
      waiter = lib.concatMapStringsSep "\n"
        (file:
          let
            # NOTE: We `escapeRegex` because inotifywait's `--include` flag
            # accepts POSIX regex. Attempting to watch for "some.secret" would
            # match "some.secret", "some0secret", "someasecret", etc., which is
            # not ideal.
            file' = lib.removePrefix "/tmp/detsys-vault/" (lib.escapeShellArg (lib.escapeRegex file));
          in
          ''
            if [ ! -f ${lib.escapeShellArg file} ]; then
              ${pkgs.inotify-tools}/bin/inotifywait --quiet --event close_write --include ${file'} /tmp/detsys-vault &
            fi
          '')
        files;
    in
    pkgs.writeShellScript "wait-for-${serviceName}" ''
      set -eux
      [ ! -d /tmp/detsys-vault ] && ${pkgs.inotify-tools}/bin/inotifywait --quiet --event create --include 'detsys-vault' /tmp
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
      wantedBy = [ fullServiceName ];
      before = [ fullServiceName ];

      # Needs getent in PATH
      path = [ pkgs.glibc ];

      unitConfig = {
        # BindsTo = [ fullServiceName ];
      };

      serviceConfig = {
        PrivateTmp = lib.mkDefault true;
        ExecStartPre = precreateTemplateFiles serviceName agentConfig.secretFiles
          ({ }
            // lib.optionalAttrs (systemdServiceConfig ? User) { user = systemdServiceConfig.User; }
            // lib.optionalAttrs (systemdServiceConfig ? Group) { group = systemdServiceConfig.Group; });
        ExecStart = "${pkgs.vault}/bin/vault agent -log-level=trace -config ${agentCfgFile}";
        ExecStartPost = waitFor serviceName (agentConfig.environmentFiles ++ agentConfig.secretFiles);
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
            agentConfig = renderAgentConfig serviceName serviceConfig.vaultAgent;
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
