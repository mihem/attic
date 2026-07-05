# packages.nix
# Exposes every non-blacklisted derivation in rstats-on-nix pkgs.rPackages as
# rPackagesSet so nix-fast-build can build and push packages individually.

let
  rNixpkgsDate =
    let
      value = builtins.getEnv "R_NIXPKGS_DATE";
    in
    if value == "" then "2026-05-18" else value;

  defaultBPCellsRev = "adc4a3c30f60a03522f58947d733d7d77a6eb2cf";
  BPCellsRev =
    let
      value = builtins.getEnv "BP_CELLS_REV";
    in
    if value == "" then defaultBPCellsRev else value;
  BPCellsSha256 = builtins.getEnv "BP_CELLS_SHA256";

  pkgs =
    import (fetchTarball "https://github.com/rstats-on-nix/nixpkgs/archive/${rNixpkgsDate}.tar.gz")
      {
        config = {
          allowBroken = true;
        };
      };

  isDerivation = value: builtins.isAttrs value && value ? type && value.type == "derivation";

  blacklistFile =
    let
      value = builtins.getEnv "BLACKLIST_FILE";
    in
    if value == "" then ./blacklist.txt else value;

  blacklistLines = builtins.filter (line: line != "") (
    builtins.filter builtins.isString (builtins.split "\n" (builtins.readFile blacklistFile))
  );

  blacklistNames = builtins.map (
    name:
    let
      nixName = builtins.replaceStrings [ "." ] [ "_" ] name;
    in
    if nixName == "import" then "r_import" else nixName
  ) blacklistLines;

  unique =
    names:
    builtins.attrNames (
      builtins.listToAttrs (
        builtins.map (name: {
          inherit name;
          value = true;
        }) names
      )
    );

  valid_r_names = builtins.filter (
    name: isDerivation pkgs.rPackages.${name} && !(builtins.elem name blacklistNames)
  ) (unique (builtins.attrNames pkgs.rPackages));
  generated_r_pkgs = builtins.map (name: pkgs.rPackages.${name}) valid_r_names;

  BPCells-src = pkgs.fetchgit {
    url = "https://github.com/bnprks/BPCells";
    rev = BPCellsRev;
    sha256 =
      if BPCellsSha256 != "" then
        BPCellsSha256
      else
        pkgs.lib.fakeSha256;
  };

  BPCells = pkgs.rPackages.buildRPackage {
    name = "BPCells";
    src = "${BPCells-src}/r";
    postPatch = "patchShebangs configure";
    nativeBuildInputs = [ pkgs.hdf5.dev ];
    propagatedBuildInputs = builtins.attrValues {
      inherit (pkgs.rPackages)
        magrittr
        Matrix
        Rcpp
        rlang
        vctrs
        lifecycle
        stringr
        tibble
        dplyr
        tidyr
        readr
        ggplot2
        scales
        patchwork
        scattermore
        ggrepel
        RColorBrewer
        hexbin
        RcppEigen
        ;
    };
  };

  allR = [ BPCells ] ++ generated_r_pkgs;

  # Expose individual R packages as an attribute set so nix-fast-build can evaluate and build them individually.
  rPackagesSet = builtins.listToAttrs (
    builtins.map (pkg: {
      name = if builtins.hasAttr "pname" pkg then pkg.pname else pkg.name;
      value = pkg;
    }) allR
  );

in
{
  inherit pkgs rPackagesSet;
}
