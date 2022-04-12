{ lib
, rustPlatform
, nix-gitignore
}:
rustPlatform.buildRustPackage rec{
  pname = "messenger";
  version = (lib.importTOML ./Cargo.toml).package.version;

  src = nix-gitignore.gitignoreSourcePure [
    "!target"
  ] ./.;

  cargoLock.lockFile = ./Cargo.lock;
}
