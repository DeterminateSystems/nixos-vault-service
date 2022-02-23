{
  description = "NixOS integration for Vault-backed secrets on systemd services.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
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
    in
    {
      devShell = forAllSystems
        ({ pkgs, ... }:
          pkgs.mkShell {
            buildInputs = with pkgs; [
              (terraform_1.withPlugins (tf: [
                tf.local
                tf.vault
              ]))
              foreman
              vault
            ];
          }
        );
    };
}
