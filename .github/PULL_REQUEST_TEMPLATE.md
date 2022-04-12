##### Description

<!---
Please include a short description of what your PR does and / or the motivation
behind it
--->

##### Checklist

<!---
Use `nix-shell` for a shell with all the required dependencies for building /
formatting / testing / etc.
--->

- [ ] Formatted with `nixpkgs-fmt`
- [ ] Ran tests with:
  * `nix-instantiate --strict --eval --json ./default.nix -A checks.definition`
  * `nix-instantiate --strict --eval --json ./default.nix -A checks.helpers`
  * `nix-build ./default.nix -A checks.implementation`
  * `cargo test --manifest-path ./messenger/Cargo.toml`
- [ ] Added or updated relevant tests (leave unchecked if not applicable)
- [ ] Added or updated relevant documentation (leave unchecked if not applicable)
