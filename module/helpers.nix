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
      mkCommandAttrset = restartAction:
        if restartAction == "none"
        then
          { }
        else
          {
            command = "systemctl ${restartAction} ${lib.escapeShellArg "${targetService}.service"}";
          };
    in
    {
      template = [ ]
        ++ (lib.optional (cfg.environment.template != null)
        (
          (mkCommandAttrset cfg.environment.changeAction) // {
            destination = "./environment.EnvFile";
            contents = cfg.environment.template;
          }
        ))
        ++ (lib.mapAttrsToList
        (name: { file }:
          (
            (mkCommandAttrset cfg.environment.changeAction) // {
              destination = "./environment/${name}.EnvFile";
              source = file;
            }
          ))
        cfg.environment.templateFiles)
        ++ (lib.mapAttrsToList
        (name: { changeAction, templateFile, template }:
          (
            (mkCommandAttrset (if changeAction != null then changeAction else cfg.secretFiles.defaultChangeAction)) // {
              destination = "./files/${name}";
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
        cfg.secretFiles.files);
    };
}
