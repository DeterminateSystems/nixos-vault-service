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

  envTemplateFile = evalCfg {
    detsys.systemd.service.env-template-file.vaultAgent = {
      enable = true;
      environment.templateFiles."example".file = ./example.ctmpl;
    };
  };

  secretTemplateFile = evalCfg {
    detsys.systemd.service.secret-template-file.vaultAgent = {
      enable = true;
      secretFiles = {
        files."example".templateFile = ./example.ctmpl;
      };
    };
  };

  secretTemplate = evalCfg {
    detsys.systemd.service.secret-template.vaultAgent = {
      enable = true;
      secretFiles = {
        defaultChangeAction = "reload";
        files."example".template = ''
          ...
        '';
      };
    };
  };
}
