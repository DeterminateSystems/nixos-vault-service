{
  description = "NixOS integration for Vault-backed secrets on systemd services.";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.533189.tar.gz";
  };

  outputs =
    { nixpkgs
    , self
    , ...
    }@inputs:
    let
      nameValuePair = name: value: { inherit name value; };
      genAttrs = names: f: builtins.listToAttrs (map (n: nameValuePair n (f n)) names);

      pkgsFor = pkgs: system:
        import pkgs { inherit system; };

      allSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" ];
      forAllSystems = f: genAttrs allSystems
        (system: f {
          inherit system;
          pkgs = pkgsFor nixpkgs system;
        });

      inherit (nixpkgs) lib;
    in
    {
      nixosModule = self.nixosModules.nixos-vault-service;
      nixosModules = {
        nixos-vault-service = {
          imports = [
            ./module/implementation.nix
          ];

          nixpkgs.overlays = [
            self.overlays.default
          ];
        };
      };

      packages = forAllSystems
        ({ pkgs, ... }: rec {
          messenger = pkgs.callPackage ./messenger { };

          default = messenger;
        });

      overlays.default = final: prev: {
        detsys-messenger = self.packages.${final.stdenv.system}.messenger;
      };

      devShell = forAllSystems
        ({ pkgs, ... }:
          pkgs.mkShell {
            buildInputs = with pkgs; [
              (terraform_1.withPlugins (tf: [
                tf.local
                tf.vault
              ]))
              foreman
              jq
              vault
              nixpkgs-fmt
            ];
          }
        );

      checks.definition = import ./module/definition.tests.nix {
        inherit nixpkgs;
        inherit (nixpkgs) lib;
      };

      checks.helpers = import ./module/helpers.tests.nix {
        inherit nixpkgs;
        inherit (nixpkgs) lib;
      };

      checks.implementation = import ./module/implementation.tests.nix {
        inherit nixpkgs self;
        inherit (nixpkgs) lib;
      };
    };
}
