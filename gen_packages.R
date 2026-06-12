#!/usr/bin/env Rscript
# gen_packages.R
# Fetches Bioconductor and CRAN package rankings, takes the configured top-N
# packages after removing blacklisted entries, and writes Nix package-name lists.
# Blacklist is read from blacklist.txt (one package per line, lines starting
# with # are comments). No inline comments allowed; blacklist.txt must contain
# only package names (or full-line comments).

bioc_n <- Inf
cran_n <- 5000

write_nix_list <- function(packages, out_path) {
  nix_names <- gsub("\\.", "_", packages)
  nix_names[nix_names == "import"] <- "r_import"
  writeLines(c("[", paste0('  "', nix_names, '"'), "]"), out_path)
  cat("Written", length(nix_names), "packages to", out_path, "\n")
}

# Read blacklist: strip full-line comments and everything after first whitespace
lines <- readLines("blacklist.txt")
lines <- sub("#.*$", "", lines)        # remove comments
lines <- trimws(lines)                  # remove leading/trailing whitespace
blacklist <- lines[nzchar(lines)]       # keep non-empty lines
cat("Loaded", length(blacklist), "blacklisted packages\n")

bioc_scores_url <- "https://bioconductor.org/packages/stats/bioc/bioc_pkg_scores.tab"
cat("Fetching", bioc_scores_url, "\n")

bioc_scores <- read.table(
  url(bioc_scores_url),
  header       = TRUE,
  sep          = "\t",
  quote        = "",
  fill         = TRUE,
  comment.char = ""
)

# Keep only Package and Download_score columns, sort descending
bioc_scores <- bioc_scores[, c("Package", "Download_score")]
bioc_scores <- bioc_scores[order(bioc_scores$Download_score, decreasing = TRUE), ]

# Remove blacklisted packages
bioc_scores <- bioc_scores[!bioc_scores$Package %in% blacklist, ]

# Take top-N
bioc_top <- head(bioc_scores$Package, bioc_n)

write_nix_list(bioc_top, "bioc_list.nix")

cran_scores_url <- "https://raw.githubusercontent.com/rstats-on-nix/top_cran_monthly/refs/heads/master/aggregated_counts.csv"
cat("Fetching", cran_scores_url, "\n")

cran_scores <- read.csv(
  url(cran_scores_url),
  header = TRUE,
  stringsAsFactors = FALSE
)

cran_scores <- cran_scores[, c("package", "N")]
cran_scores <- cran_scores[order(cran_scores$N, decreasing = TRUE), ]
cran_scores <- cran_scores[!cran_scores$package %in% blacklist, ]

cran_top <- head(cran_scores$package, cran_n)

write_nix_list(cran_top, "cran_list.nix")
