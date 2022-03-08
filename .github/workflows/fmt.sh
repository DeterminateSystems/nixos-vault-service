#!/usr/bin/env nix-shell
#!nix-shell ../../shell.nix -i bash
# shellcheck shell=bash

find . -path '*.nix' -print0 | xargs -0 nixpkgs-fmt --check
