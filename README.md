# nixos-vault-service

The NixOS Vault Service module is a NixOS module that allows easily integrating
Vault with existing systemd services.

> **NOTE**: The goal is not magic, so some services may need to be changed or patched.

## Usage

### With Flakes

```nix
# flake.nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.vaultModule = {
    url = "github:DeterminateSystems/nixos-vault-service/main";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, vaultModule }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        vaultModule.nixosModule
        ./configuration.nix
      ];
    };
  };
}
```

### Without Flakes

There are many ways to make this module available in your system configuration
without flakes. This is an example of just one possible method:

```nix
# vault.nix
let
  vaultModuleSrc = builtins.fetchGit {
    url = "https://github.com/DeterminateSystems/nixos-vault-service.git";
    ref = "main";
  };
in
{
  imports = [ "${vaultModuleSrc}/module/implementation" ];
}
```

## Configuration

After you have the module imported by your system's configuration, you can now
being integrating your services with Vault.

### Options

* `detsys.vaultAgent.defaultAgentConfig` (optional, default: `{ }`) &ndash; The default configuration for all Vault agents. Defers to individual service's `agentConfig`, if set.
* `detsys.vaultAgent.systemd.services.<service-name>.enable` (optional, default: `false`) &ndash; Whether to enable Vault integration with the service specified by `<service-name>`.
* `detsys.vaultAgent.systemd.services.<service-name>.agentConfig` (optional, default: `null`) &ndash; The Vault agent configuration for this service.
* `detsys.vaultAgent.systemd.services.<service-name>.environment` (optional, default: `{ }`) &ndash; Environment variable secret configuration.
  * `detsys.vaultAgent.systemd.services.<service-name>.environment.changeAction` (optional, default: `"restart"`) &ndash; What action to take if any secrets in the environment change. One of `"restart"`, `"stop"`, or `"none"`.
  * `detsys.vaultAgent.systemd.services.<service-name>.environment.templateFiles` (optional, default: `{ }`) &ndash; Set of files containing environment variables for Vault to template.
    * `detsys.vaultAgent.systemd.services.<service-name>.environment.templateFiles.<filename>.file` (required) &ndash; The file containing the environment variable(s) for Vault to template.
  * `detsys.vaultAgent.systemd.services.<service-name>.environment.template` (optional, default: `null`) &ndash; A multi-line string containing environment variables for Vault to template.
* `detsys.vaultAgent.systemd.services.<service-name>.secretFiles` (optional, default: `{ }`) &ndash; Secret file configuration.
  * `detsys.vaultAgent.systemd.services.<service-name>.secretFiles.defaultChangeAction` (optional, default: `"restart"`) &ndash; What action to take if any secrets in any of these files change. One of `"restart"`, `"reload"`, `"stop"`, or `"none"`.
  * `detsys.vaultAgent.systemd.services.<service-name>.secretFiles.files` (optional: default `{ }`) &ndash; Set of files for Vault to template.
    * `detsys.vaultAgent.systemd.services.<service-name>.secretFiles.files.<filename>.changeAction` (optional, default: the `defaultChangeAction`) &ndash; What action to take if the secret file changes. One of `"restart"`, `"reload"`, `"stop"`, or `"none"`.
    * `detsys.vaultAgent.systemd.services.<service-name>.secretFiles.files.<filename>.templateFile` (optional, default: `null`) &ndash; A file containing a Vault template. Conflicts with `template`.
    * `detsys.vaultAgent.systemd.services.<service-name>.secretFiles.files.<filename>.template` (optional, default: `null`) &ndash; A string containing a Vault template. Conflicts with `templateFile`.
    * `detsys.vaultAgent.systemd.services.<service-name>.secretFiles.files.<filename>.perms` (optional, default: `"0400"`) &ndash; The octal mode of the secret file.
    * `detsys.vaultAgent.systemd.services.<service-name>.secretFiles.files.<filename>.path` (read-only) &ndash; The path to the secret file inside `<service-name>`'s namespace's `PrivateTmp`.

### Examples

#### Demonstrating all the options

```nix
{
  detsys.vaultAgent.defaultAgentConfig = {
    # The configuration passed to `vault agent` -- will be converted to JSON.
    # This is where your `vault`, `auto_auth`, `template_config`, etc., configuration should go.
  };

  detsys.vaultAgent.systemd.services."service-name" = {
    enable = true;

    agentConfig = {
      # Overrides the entirety of `detsys.vaultAgent.defaultAgentConfig`.
    };

    environment = {
      changeAction = "restart";

      templateFiles = {
        "example-a".file = ./example-a.ctmpl;
        "example-b".file = ./example-b.ctmpl;
      };

      template = ''
        EXAMPLE_C={{ with secret "secret/super_secret" }}{{ .Data.c }}{{ end }}
        EXAMPLE_D={{ with secret "secret/super_secret" }}{{ .Data.d }}{{ end }}
      '';
    };

    secretFiles = {
      defaultChangeAction = "restart";

      files."example-e" = {
        changeAction = "reload";
        perms = "0440";

        # NOTE: You can only use either:
        templateFile = ./example-e.ctmpl;
        # or:
        template = ''
          {{ with secret "secret/super_secret" }}{{ .Data.e }}{{ end }}
        '';
        # but not both.
      };

      files."example-f".template = ''
        {{ with secret "secret/super_secret" }}{{ .Data.f }}{{ end }}
      '';
    };
  };
}
```

#### Default Vault Agent configuration

You can set the default `agentConfig` for all units by using the `detsys.vaultAgent.defaultAgentConfig` interface.

> **NOTE**: Manually-specified unit `agentConfig`s will override _**all**_ of the the settings specified in the `detsys.vaultAgent.defaultAgentConfig` option.

> **NOTE**: Some of these options _must_ be wrapped in a list (e.g. see `auto_auth`) in order for the generated JSON to be valid. Wrapping them all in a list doesn't hurt.

```nix
{
  detsys.vaultAgent.defaultAgentConfig = {
    vault = [{ address = "http://127.0.0.1:8200"; }];
    auto_auth = [{
      method = [{
        config = [{
          remove_secret_id_file_after_reading = false;
          role_id_file_path = "/role_id";
          secret_id_file_path = "/secret_id";
        }];
        type = "approle";
      }];
    }];
    template_config = [{
      static_secret_render_interval = "5s";
    }];
  };
}
```

#### Accessing the path of a file in `secretFiles`

All `secretFiles.files.<NAME>` expose a `path` attribute, so you don't need to memorize where the secrets are written to:

```nix
{ config, ... }:
{
  detsys.vaultAgent.systemd.services.prometheus = {
    enable = true;

    secretFiles.files."vault.token".template = ''
      {{ with secret "secrets/nginx-basic-auth"}}
      {{ .Data.data.htpasswd }}
      {{ end }}
    '';
  };
}
```

You can then access the path to the above `vault.token` secret file via `config.detsys.vaultAgent.systemd.services.prometheus.secretFiles.files."vault.token".path`.

### How to override systemd service configuration

By using the NixOS module system, it is possible to override the sidecar's systemd service configuration (e.g. to tune how often the service is allowed to restart):
Sidecar unit names follow the pattern of `detsys-vaultAgent-${service-name}`.

```nix
{
  detsys.vaultAgent.systemd.services.prometheus = {
    enable = true;

    secretFiles = {
      defaultChangeAction = "none";
      files."vault.token".templateFile = ./vault-token.ctmpl;
    };
  };

  systemd.services.detsys-vaultAgent-prometheus = {
    unitConfig = {
      StartLimitIntervalSec = 300;
      StartLimitBurst = 10;
    };

    serviceConfig = {
      RestartSec = 30;
      Restart = "always";
    };
  };
}
```

## Running tests

We have tests for the module's definition, helpers, and implementation. These can be run like so:

```bash
nix-instantiate --strict --eval --json ./default.nix -A checks.definition
nix-instantiate --strict --eval --json ./default.nix -A checks.helpers
nix-build ./default.nix -A checks.implementation
```

### Tips for writing tests

To read the secret file (e.g. to verify the contents), you will need to join the namespace of the sidecar vaultAgent unit:

```bash
systemd-run -p JoinsNamespaceOf=detsys-vaultAgent-serviceName.service -p PrivateTmp=true cat /tmp/detsys-vault/some-secret-file
```

# License

[MIT](./LICENSE)
