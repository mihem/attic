let
  rNixpkgsDate = let
    value = builtins.getEnv "R_NIXPKGS_DATE";
  in if value == "" then "2026-05-18" else value;

  pkgs = import (fetchTarball "https://github.com/rstats-on-nix/nixpkgs/archive/${rNixpkgsDate}.tar.gz") { config = { allowBroken = true; }; };

  isDerivation = value: builtins.isAttrs value && value ? type && value.type == "derivation";
in
  builtins.filter (name: isDerivation pkgs.rPackages.${name}) (builtins.attrNames pkgs.rPackages)
