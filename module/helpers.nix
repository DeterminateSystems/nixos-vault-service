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
    {
      template = [ ] ++
        (lib.optional (cfg.environment.template != null) {
          command = "systemctl ${cfg.environment.changeAction} ${lib.escapeShellArg "${targetService}.service"}";
          destination = "./environment.ctmpl";
          contents = cfg.environment.template;
        });
    };
}
