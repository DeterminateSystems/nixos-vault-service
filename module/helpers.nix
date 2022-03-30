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
          null
        else
          "systemctl ${restartAction} ${lib.escapeShellArg "${targetService}.service"}";

      environmentFileTemplates =
        let
          changeCommand = mkCommand cfg.environment.changeAction;
        in
        (lib.optional (cfg.environment.template != null)
          (
            {
              destination = "${environmentFilesRoot}${targetService}/EnvFile";
              contents = cfg.environment.template;
              inherit (cfg.environment) perms;
            } // lib.optionalAttrs (changeCommand != null) {
              command = changeCommand;
            }
          ))
        ++ (lib.mapAttrsToList
          (name: { file, perms }:
            (
              {
                destination = "${environmentFilesRoot}${targetService}/${name}.EnvFile";
                source = file;
                inherit perms;
              } // lib.optionalAttrs (changeCommand != null) {
                command = changeCommand;
              }
            ))
          cfg.environment.templateFiles);

      secretFileTemplates = lib.mapAttrsToList
        (name: { changeAction, templateFile, template, perms }:
          rec {
            command =
              let
                user = targetServiceConfig.serviceConfig.User or null;
                group = targetServiceConfig.serviceConfig.Group or null;
                escapedUser = lib.escapeShellArg user;
                escapedGroup = lib.escapeShellArg group;
                changeCommand = mkCommand (if changeAction != null then changeAction else cfg.secretFiles.defaultChangeAction);
              in
              builtins.concatStringsSep ";"
                ([
                  "chown ${lib.optionalString (user != null) escapedUser}:${lib.optionalString (group!= null) escapedGroup} ${lib.escapeShellArg destination}"
                ] ++ lib.optionals (changeCommand != null) [
                  changeCommand
                ]);
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

      agentConfig = (cfg.agentConfig or { }) // {
        template = environmentFileTemplates
          ++ secretFileTemplates;
      };
    };
}
