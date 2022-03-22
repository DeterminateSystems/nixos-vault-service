# Vault integration for systemd services on NixOS

The goal is to easily integrate Vault into an existing systemd service.
Note the goal is not magic: services may need to be changed or patched to make this work.
However, it should be straightforward to express the intent of additive secrets to a service.

## Overall Design

In general the idea is to create a NixOS module which builds on top of the existing systemd interface and "hooks in" to it.
Each service would get a Vault Agent service running as a "sidecar": in addition to, and bound to the lifecycle of its target process.

The agent will start before the target service, and can send restart/reload instructions to systmed. The agent should share the private namespace of the service as well.

If the user manually start, restarts, or stops the target service, the agent sidecar should start, restart, or stop with it.

### Where do the files go?

> **NOTE:** Currently, we use the systemd `PrivateTmp` directive, which interacts with `JoinsNamespaceOf` in a documented fashion.
> It is unknown at this time whether `TemporaryFileSystem` exhibits the same functionality (namely, sharing of mountpoints between services) when used in conjunction with `JoinsNamespaceOf`.

We'll create a temporary filesystem in the sidecar using the `TemporaryFileSystem` at `/run/detsys/vaultAgent`.
All generated, secret files will go there.
This temporary filessytem will be shared with the target service via the `JoinsNamespaceOf` directive.

## Example Nix Interface

```nix
{
  detsys.systemd.services."service-name".vaultAgent = {
    enable = true;

    environment = {
        # What to do by default if any secrets in the environment change.
        #
        # One of:
        #  * restart (default)
        #  * stop
        #  * none
        #
        # Note that "reload" is not valid, because the environment
        # cannot be reloaded.
        changeAction = "restart";


        templateFiles = {
            # An EnvironmentFile is created for each section here.
            "file-section" = {
                file = ./example.ctmpl;
            };
        };

        # vault-agent template data embedded as strings in the module.
        # Multiple template strings can be provided in different modules,
        # which will be concatenated together into a single EnvironmentFile.
        # It is up to the caller to escape the contents and handle the input properly.
        template = ''
            WIFI_PASSWORD={{ with secret "secret/passwords" }}{{ .Data.wifi }}{{ end }}
        '';

        # In the future, once we have correct escaping down right:
        variables."WIFI_PASSWORD" = ''{{ with secret "secret/passwords" }}{{ .Data.wifi }}{{ end }}'';
    };

    secretFiles = {
        # What to do by default if any secrets change.
        #
        # One of:
        #  * stop
        #  * restart
        #  * reload
        #  * none
        defaultChangeAction = "...";

        # This file will be accessible at `/tmp/detsys-vault/webserver.cert` by
        # any units in the namespace of `detsys-vaultAgent-service-name.service`
        # via the JoinsNamespaceOf= systemd directive.
        files."webserver.cert" = {
            # What to do if this *specific* file changes content.
            # Defaults to the secretFiles.defaultChangeAction, and any of those values are valid here too.
            changeAction = "reload";

            # The octal mode of the created secret file (as a string).
            # Defaults to 0400.
            # NOTE: The owner and group of the file are set based on the
            # infected service's User= and Group= systemd directives.
            perms = "0400";

            # Either use an external file as the template:
            templateFile = ./example.ctmpl;

            # or an embedded string template:
            template = ''
                {{ with secret "pki/issue/my-domain-dot-com" "common_name=foo.example.com" }}
                {{ .Data.certificate }}{{ end }}
            '';
        };
    };
  };
}
```

### Hydra

Getting database credentials for Hydra:

```nix
{
  detsys.systemd.services.hydra-init.vaultAgent = {
    enable = true;

    environment.template = ''
      {{ with secret "postgresql/creds/hydra" }}
      HYDRA_DBI=dbi:Pg:dbname=hydra;host=the-database-server;username={{ .Data.username }};password={{ .Data.password }};
      {{ end }}
    '';
  };
}
```

This will put HYDRA_DBI=xxx into an EnvironmentFile for the `hydra-init` service
When the credentials are about to expire, the service will restart.
Care should be taken in this case: `hydra-init`'s lifecycle is expected to start, run briefly, and then shut down.
This should be allowed normally, and the sidecar should not cause the service to be started again.

Furthermore, hydra-init could potentially run migrations that take _many_ hours.
Once the connection to the database is open, will it remain open even if the credentials expire?
Should hydra-init be marked as "reload" or a "none" changeAction?
If hydra-init is terminated in the middle of a migration no _harm_ is done exactly, however the migration will be rolled back and therefore never complete.


### Secret environment variables with an external template file

With a file named `hydra-dbi-env.ctmpl`:

```golang
{{ with secret "postgresql/creds/hydra" }}
HYDRA_DBI=dbi:Pg:dbname=hydra;host=the-database-server;username={{ .Data.username }};password={{ .Data.password }};
{{ end }}
```

```nix
{
    detsys.systemd.services.prometheus.vaultAgent = {
        enable = true;

        environment.templateFiles."dbi".file = ./hydra-dbi-env.ctmpl;
    };
}
```


### Basic Auth for Nginx

```nix
{
  detsys.systemd.services.nginx.vaultAgent = {
    enable = true;

    secretFiles = {
        defaultChangeAction = "reload";
        files."basic-auth.conf".template = ''
            {{ with secret "secrets/nginx-basic-auth"}}
            {{ .Data.data.htpasswd }}
            {{ end }}
        '';
    };
  };
}
```

### Vault token for Prometheus

```nix
{
    detsys.systemd.services.prometheus.vaultAgent = {
        enable = true;

        secretFiles = {
            defaultChangeAction = "none";
            files."vault.token".template = ''
                {{with secret "/auth/token/create" "policies=vault_mon" "no_default_policy=true"}}{{.Auth.ClientToken}}{{ end }}
            '';
        };
    };
}
```

### Secret files with an external template file

With a file named `vault-token.ctmpl`:

```golang
{{ with secret "/auth/token/create" "policies=vault_mon" "no_default_policy=true"}}{{.Auth.ClientToken}}{{ end }}
```

```nix
{
    detsys.systemd.services.prometheus.vaultAgent = {
        enable = true;

        secretFiles = {
            defaultChangeAction = "none";
            files."vault.token".templateFile = ./vault-token.ctmpl;
        };
    };
}
```

---

# Running tests

Validate the module's definition passes checks.

```
nix-instantiate --strict --eval --json ./default.nix -A checks.definition
```

Or interactively on each change:

```
git ls-files | entr -s 'nix-instantiate --strict --eval --json ./default.nix -A checks.definition | jq .'
```

## Tips for writing tests

To read the secret file (e.g. to verify the contents), you will need to join the namespace of the sidecar vaultAgent unit:

```
systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-serviceName.service -p PrivateTmp=true cat /tmp/detsys-vault/some-secret-file
```

----

# Known Issues

* the `detsys-vaultAgent-*` unit gets stuck in ExecStartPost if the vault agent dies.
* there is no way to get the file path of the secret file, so you have to "just know" where it will be
