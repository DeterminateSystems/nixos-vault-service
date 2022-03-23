{ lib }:
rec {
  secretFilesRoot = "/tmp/detsys-vault/";
  environmentFilesRoot = "/run/keys/environment/";

  mkScopedMerge = attrs:
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

  renderAgentConfig = targetService: targetServiceConfig: cfg:
    let
      mkCommand = requestedAction:
        let
          restartAction = {
            restart = "try-restart";
            reload = "try-reload-or-restart";
            stop = "stop";
          }."${requestedAction}";
        in
        if requestedAction == "none"
        then
          ""
        else
          "systemctl ${restartAction} ${lib.escapeShellArg "${targetService}.service"}";

      environmentFileTemplates =
        (lib.optional (cfg.environment.template != null)
          (
            {
              command = mkCommand cfg.environment.changeAction;
              destination = "${environmentFilesRoot}EnvFile";
              contents = cfg.environment.template;
              inherit (cfg.environment) perms;
            }
          ))
        ++ (lib.mapAttrsToList
          (name: { file, perms }:
            (
              {
                command = mkCommand cfg.environment.changeAction;
                destination = "${environmentFilesRoot}${name}.EnvFile";
                source = file;
                inherit perms;
              }
            ))
          cfg.environment.templateFiles);

      secretFileTemplates = lib.mapAttrsToList
        (name: { changeAction, templateFile, template, perms }:
          rec {
            command =
              let
                user = targetServiceConfig.serviceConfig.User or "";
                group = targetServiceConfig.serviceConfig.Group or "";
                escapedUser = lib.escapeShellArg user;
                escapedGroup = lib.escapeShellArg group;
              in
              builtins.concatStringsSep ";" [
                "chown ${escapedUser}:${escapedGroup} ${destination}"
                (mkCommand (if changeAction != null then changeAction else cfg.secretFiles.defaultChangeAction))
              ];
            # This is ~safe because we require PrivateTmp to be true.
            destination = "${secretFilesRoot}${name}";
            inherit perms;
          } //
          (
            if template != null
            then {
              contents = template;
            }
            else if templateFile != null
            then {
              source = templateFile;
            }
            else throw ""
          )
        )
        cfg.secretFiles.files;
    in
    {
      inherit
        environmentFileTemplates
        secretFileTemplates
        ;

      environmentFiles = builtins.map
        (tpl: tpl.destination)
        environmentFileTemplates;

      secretFiles = builtins.map
        (tpl: tpl.destination)
        secretFileTemplates;

      agentConfig = (cfg.extraConfig or { }) // {
        template = environmentFileTemplates
          ++ secretFileTemplates;
      };
    };
}
