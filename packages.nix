# packages.nix
# Exposes every non-blacklisted derivation in rstats-on-nix pkgs.rPackages as
# rPackagesSet so nix-fast-build can build and push packages individually.

let
  rNixpkgsDate =
    let
      value = builtins.getEnv "R_NIXPKGS_DATE";
    in
    if value == "" then "2026-05-18" else value;

  BPCellsRev = builtins.getEnv "BP_CELLS_REV";
  BPCellsSha256 = builtins.getEnv "BP_CELLS_SHA256";
  scMiscRev = builtins.getEnv "SC_MISC_REV";
  scMiscSha256 = builtins.getEnv "SC_MISC_SHA256";
  permFDPRev = builtins.getEnv "PERM_FDP_REV";
  permFDPSha256 = builtins.getEnv "PERM_FDP_SHA256";

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

  permFDP-src = pkgs.fetchgit {
    url = "https://github.com/steven-shuken/permFDP";
    rev = permFDPRev;
    sha256 =
      if permFDPSha256 != "" then
        permFDPSha256
      else
        pkgs.lib.fakeSha256;
  };

  permFDP = pkgs.rPackages.buildRPackage {
    name = "permFDP";
    src = permFDP-src;
    propagatedBuildInputs = builtins.attrValues {
      inherit (pkgs.rPackages) Rcpp BH;
    };
  };

  scMisc-src = pkgs.fetchgit {
    url = "https://github.com/mihem/scMisc";
    rev = scMiscRev;
    sha256 =
      if scMiscSha256 != "" then
        scMiscSha256
      else
        pkgs.lib.fakeSha256;
  };

  scMisc = pkgs.rPackages.buildRPackage {
    name = "scMisc";
    src = scMisc-src;
    propagatedBuildInputs = builtins.attrValues {
      inherit permFDP;
      inherit (pkgs.rPackages)
        Seurat
        readr
        glue
        viridis
        ggplot2
        pheatmap
        homologene
        dplyr
        tibble
        magrittr
        clustifyr
        ggrepel
        writexl
        ggsignif
        patchwork
        rstatix
        readxl
        tidyr
        speckle
        limma
        RColorBrewer
        factoextra
        FactoMineR
        Matrix
        ggpubr
        enrichR
        tidyselect
        stringr
        forcats
        ;
    };
  };

  allR = [ BPCells permFDP scMisc ] ++ generated_r_pkgs;

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
