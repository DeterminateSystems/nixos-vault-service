{ lib }:
rec {
  # This is ~safe because we require PrivateTmp to be true.
  secretFilesRoot = "/tmp/detsys-vault/";
  environmentFilesRoot = "/run/keys/environment/";

  mkScopedMerge = attrs:
    let
      pluckFunc = attr: values: lib.mkMerge
        (builtins.map
          (v:
            lib.mkIf
              (lib.hasAttrByPath attr v)
              (lib.getAttrFromPath attr v))
          values);

      pluckFuncs = attrs: values:
        lib.mkMerge (builtins.map
          (attr: lib.setAttrByPath attr (pluckFunc attr values))
          attrs);

    in
    pluckFuncs attrs;

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
          ({
            destination = "${environmentFilesRoot}${targetService}/EnvFile";
            contents = cfg.environment.template;
            inherit (cfg.environment) perms;
          } // lib.optionalAttrs (changeCommand != null) {
            command = changeCommand;
          }))
        ++ (lib.mapAttrsToList
          (name: { file, perms }:
            ({
              destination = "${environmentFilesRoot}${targetService}/${name}.EnvFile";
              source = file;
              inherit perms;
            } // lib.optionalAttrs (changeCommand != null) {
              command = changeCommand;
            }))
          cfg.environment.templateFiles);

      secretFileTemplates = lib.mapAttrsToList
        (_name: { changeAction, templateFile, template, perms, path }:
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
            destination = path;
            inherit perms;
          }
          // lib.optionalAttrs (template != null) { contents = template; }
          // lib.optionalAttrs (templateFile != null) { source = templateFile; }
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

      agentConfig = cfg.agentConfig // {
          template = environmentFileTemplates
          ++ secretFileTemplates;
        };
    };
}
