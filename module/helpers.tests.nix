{ path, lib, ... }:
let
  helpers = import ./helpers.nix { inherit lib; };
  suite = { ... } @ tests:
    (builtins.mapAttrs
      (name: value:
        (builtins.trace "test case '${name}':" value))
      tests);
in
with
(
  let
    evalCfg = config:
      (lib.evalModules {
        modules = [
          "${path}/nixos/modules/misc/assertions.nix"
          ./definition.nix
          config
        ];
      }).config;

    safeEval = val:
      (builtins.tryEval
        (builtins.deepSeq val val)
      ) // { originalValue = val; };
  in
  {
    expectRenderedConfig = expect: cfg:
      let
        evaluatedCfg = evalCfg cfg;
        result = safeEval evaluatedCfg;

        filteredAsserts = builtins.map (asrt: asrt.message) (lib.filter (asrt: !asrt.assertion) result.value.assertions);

        actual = (helpers.renderAgentConfig result.value.detsys.systemd.service.example.vaultAgent);
      in
      if !result.success
      then
        evaluatedCfg
      else if (filteredAsserts != [ ] || result.value.warnings != [ ])
      then
        throw "Unexpected assertions or warnings. Assertions: ${builtins.toJSON filteredAsserts}. Warnings: ${builtins.toJSON result.value.warnings}"
      else if actual != expect
      then
        throw "Mismatched configuration. Expected: ${builtins.toJSON expect} Got: ${builtins.toJSON actual}"
      else "ok";
  }
);
{
  nothingSet = expectRenderedConfig { } {
    detsys.systemd.service.nothing-set.vaultAgent = { };
  };
}
