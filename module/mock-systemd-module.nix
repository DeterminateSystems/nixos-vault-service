{ lib, ... }:
let
  inherit (lib)
    mkOption
    ;

  inherit (lib.types)
    attrsOf
    submodule
    anything
    ;
in
{
  options = {
    systemd.services = lib.mkOption {
      default = { };
      type = attrsOf (submodule {
        options = {
          serviceConfig = lib.mkOption {
            default = { };
            type = attrsOf anything;
          };
        };
      });
    };
  };
}
