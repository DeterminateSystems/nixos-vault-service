{
  detsys.systemd.service = rec {
    hydra-init = {
      vaultAgent = {
        enable = true;
        defaultChangeAction = "restart";

        environment.template = ''
          {{ with secret "postgresql/creds/hydra" }}
          HYDRA_DBI=dbi:Pg:dbname=hydra;host=the-database-server;username={{ .Data.username }};password={{ .Data.password }};
          {{ end }}
        '';

        secretsFiles = {
          "github-authorizations.conf" = {
            changeAction = "reload";
            template = ''
              <github_authorization>
                {{ with secret "github/permissionset/DeterminateSystems" }}
                DeterminateSystems = {{ .Data.token }}
                {{ end }}
              </github_authorization>
            '';
          };
        };
      };
    };
  };
  hydra-notify = hydra-init;
  hydra-server = hydra-init;
}
