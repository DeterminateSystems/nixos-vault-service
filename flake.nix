{
  description = "NixOS integration for Vault-backed secrets on systemd services.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.0.1.tar.gz";
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
        import pkgs { inherit system; config.allowUnfree = true; };

      allSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
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

      devShells = forAllSystems
        ({ pkgs, ... }:
          {
            default = pkgs.mkShell {
              buildInputs = with pkgs; [
                (terraform_1.withPlugins (tf: [
                  tf.local
                  tf.vault
                ]))
                foreman
                jq
                vault
                nixpkgs-fmt
                cargo
              ] ++ lib.optionals (pkgs.stdenv.isDarwin) (with pkgs; [
                libiconv
              ]);
            };
          }
        );

      checks = forAllSystems
        ({ system, pkgs, ... }: ({
          definition = pkgs.writeText "definition.json" (builtins.toJSON (import ./module/definition.tests.nix {
            inherit nixpkgs;
            inherit (nixpkgs) lib;
          }));

          helpers = pkgs.writeText "helpers.json" (builtins.toJSON (import ./module/helpers.tests.nix {
            inherit nixpkgs;
            inherit (nixpkgs) lib;
          }));
        } // (if system == "x86_64-linux" || system == "aarch64-linux" then {
          implementation = pkgs.writeText "implementation.json" (builtins.toJSON (import ./module/implementation.tests.nix {
            inherit nixpkgs self system;
            inherit (nixpkgs) lib;
          }));
        }
        else { })));
    };
}
