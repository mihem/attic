#!/usr/bin/env Rscript
# gen_packages.R
# Fetches the Bioconductor download-score table, takes the top-N packages
# (after removing known-broken ones), and writes a Nix list to bioc_list.nix.
# Blacklist is read from blacklist.txt (one package per line, lines starting
# with # are comments). No inline comments allowed; blacklist.txt must contain
# only package names (or full-line comments).

bioc_n <- Inf

# Read blacklist: strip full-line comments and everything after first whitespace
lines <- readLines("blacklist.txt")
lines <- sub("#.*$", "", lines)        # remove comments
lines <- trimws(lines)                  # remove leading/trailing whitespace
blacklist <- lines[nzchar(lines)]       # keep non-empty lines
cat("Loaded", length(blacklist), "blacklisted packages\n")

scores_url <- "https://bioconductor.org/packages/stats/bioc/bioc_pkg_scores.tab"
cat("Fetching", scores_url, "\n")

scores <- read.table(
  url(scores_url),
  header       = TRUE,
  sep          = "\t",
  quote        = "",
  fill         = TRUE,
  comment.char = ""
)

# Keep only Package and Download_score columns, sort descending
scores <- scores[, c("Package", "Download_score")]
scores <- scores[order(scores$Download_score, decreasing = TRUE), ]

# Remove blacklisted packages
scores <- scores[!scores$Package %in% blacklist, ]

# Take top-N
top <- head(scores, bioc_n)

# Convert package names to valid Nix attribute names (dots → underscores)
nix_names <- gsub("\\.", "_", top$Package)

# Write bioc_list.nix (no timestamp)
out_path <- "bioc_list.nix"
writeLines(c("[", paste0('  "', nix_names, '"'), "]"), out_path)
cat("Written", length(nix_names), "packages to", out_path, "\n")
