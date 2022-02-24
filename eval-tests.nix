let
  lib = import <nixpkgs/lib>;

  evalCfg = config: (lib.evalModules {
    modules = [
      ./module.nix
      config
    ];
  }).config;
in
{
  nothingSet = evalCfg {
    detsys.systemd.service.nothing-set.vaultAgent = { };
  };

  envTemplate = evalCfg {
    detsys.systemd.service.env-template.vaultAgent = {
      enable = true;

      environment.template = ''
        {{ with secret "postgresql/creds/hydra" }}
        HYDRA_DBI=dbi:Pg:dbname=hydra;host=the-database-server;username={{ .Data.username }};password={{ .Data.password }};
        {{ end }}
      '';
    };
  };
}
