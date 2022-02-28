{ pkgs, lib, config, ... }:
let
  helpers = import ./helpers.nix { inherit lib; };
  inherit (helpers)
    mkScopedMerge
    renderAgentConfig;

  waiter = pkgs.writeScript "wait-for" ''
    set -eux
    while [ ! -f "$1" ]; do
      sleep 1
    done
  '';
  waitFor = serviceName: files: pkgs.writeShellScript "wait-for-${serviceName}"
    (lib.concatMapStringsSep "\n"
      (file: "${waiter} ${lib.escapeShellArg file}")
      files);

  makeAgentService = { serviceName, agentConfig }:
    let
      fullServiceName = "${serviceName}.service";
      agentCfgFile = pkgs.writeText "detsys-vaultAgent-${serviceName}.json"
        (builtins.toJSON agentConfig.agentConfig);

    in
    {
      wantedBy = [ fullServiceName ];
      before = [ fullServiceName ];

      # Needs getent in PATH
      path = [ pkgs.glibc ];

      unitConfig = {
        BindsTo = [ fullServiceName ];
      };

      serviceConfig = {
        ExecStart = "${pkgs.vault}/bin/vault agent -log-level=trace -config ${agentCfgFile}";
        ExecStartPost = waitFor serviceName (agentConfig.environmentFiles ++ agentConfig.secretFiles);
        PrivateTmp = true;
        WorkingDirectory = "/tmp";
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
        EnvironmentFile = builtins.map (f: "/tmp/${f}") agentConfig.environmentFiles;
      };
    };
in
{
  imports = [
    ./definition.nix
  ];

  config = mkScopedMerge [ [ "systemd" "services" ] ]
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
            };
          };
        })
      config.detsys.systemd.services
    );
}
