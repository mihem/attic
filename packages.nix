# packages.nix
# Uses pkgs.buildEnv instead of mkShell to avoid ARG_MAX with 1000+ packages.
# buildEnv creates a symlink farm internally, without passing the list to any
# shell command line.  push.sh simply builds the 'rEnv' attribute.

let
  pkgs = import (fetchTarball "https://github.com/rstats-on-nix/nixpkgs/archive/2026-05-18.tar.gz") { config = { allowBroken = true; }; };

  bioc_names = import ./bioc_list.nix;
  valid_bioc_names = builtins.filter (name: builtins.hasAttr name pkgs.rPackages) bioc_names;
  bioc_pkgs  = builtins.map (name: pkgs.rPackages.${name}) valid_bioc_names;

  rpkgs = builtins.attrValues {
    inherit (pkgs.rPackages)
      ape biomaRt colourpicker devtools dplyr DT formattable future_apply
      ggplot2 glue GSVA HDF5Array httr igraph Matrix msigdbr pbapply pkgdown
      plotly qvalue R6 readr rlang scales Seurat SeuratObject shiny
      shinycssloaders shinydashboard shinyFiles shinyjs shinytest2
      shinyvalidate shinyWidgets stringr testthat tibble tidyr tidyselect viridis;
  };

  BPCells-src = pkgs.fetchgit {
    url = "https://github.com/bnprks/BPCells";
    rev = "adc4a3c30f60a03522f58947d733d7d77a6eb2cf";
    sha256 = "sha256-7VRa1iADZ3Btcke8IHqCF97O2HhE184dZ1cH1i66Uhc=";
  };

  BPCells = pkgs.rPackages.buildRPackage {
    name = "BPCells";
    src = "${BPCells-src}/r";
    postPatch = "patchShebangs configure";
    nativeBuildInputs = [ pkgs.hdf5.dev ];
    propagatedBuildInputs = builtins.attrValues {
      inherit (pkgs.rPackages)
        magrittr Matrix Rcpp rlang vctrs lifecycle stringr tibble dplyr tidyr
        readr ggplot2 scales patchwork scattermore ggrepel RColorBrewer hexbin RcppEigen;
    };
  };

  system_packages = builtins.attrValues {
    inherit (pkgs) chromium glibcLocales nix pandoc R;
  };

  allR = [ BPCells ] ++ rpkgs ++ bioc_pkgs;

  # Expose individual R packages as an attribute set so nix-fast-build can evaluate and build them individually.
  rPackagesSet = builtins.listToAttrs (builtins.map (pkg: {
    name = if builtins.hasAttr "pname" pkg then pkg.pname else pkg.name;
    value = pkg;
  }) allR);

  # Build a single combined environment (symlink farm) containing everything.
  # buildEnv handles 1000+ packages without ARG_MAX because it doesn't pass
  # the list to any shell command.
  rEnv = pkgs.buildEnv {
    name = "r-bioc-env";
    paths = allR ++ system_packages;
    # Prevent collisions from overwriting files (keep first occurrence)
    ignoreCollisions = true;
  };
in
  { inherit pkgs rEnv rPackagesSet; }
