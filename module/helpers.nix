{ lib }:
{
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

  renderAgentConfig = targetService: cfg:
    let
      mkCommandAttrset = requestedAction:
        let
          restartAction = {
            restart = "try-restart";
            reload = "try-reload-or-restart";
            stop = "stop";
          }."${requestedAction}";
        in
        if requestedAction == "none"
        then
          { }
        else
          {
            command = "systemctl ${restartAction} ${lib.escapeShellArg "${targetService}.service"}";
          };

      environmentFileTemplates =
        (lib.optional (cfg.environment.template != null)
          (
            (mkCommandAttrset cfg.environment.changeAction) // {
              destination = "/run/keys/environment/EnvFile";
              contents = cfg.environment.template;
            }
          ))
        ++ (lib.mapAttrsToList
          (name: { file }:
            (
              (mkCommandAttrset cfg.environment.changeAction) // {
                destination = "/run/keys/environment/${name}.EnvFile";
                source = file;
              }
            ))
          cfg.environment.templateFiles);

      secretFileTemplates = lib.mapAttrsToList
        (name: { changeAction, templateFile, template, perms }:
          (
            (mkCommandAttrset (if changeAction != null then changeAction else cfg.secretFiles.defaultChangeAction)) // {
              # This is ~safe because we require PrivateTmp to be true.
              destination = "/tmp/detsys-vault/${name}";
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
          ))
        cfg.secretFiles.files;
    in
    {
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
