#!/usr/bin/env Rscript
# gen_packages.R
# Generates package_scores.tsv for reporting only. The build itself is defined
# directly in packages.nix from pkgs.rPackages.

to_nix_name <- function(packages) {
  nix_names <- gsub("\\.", "_", packages)
  nix_names[nix_names == "import"] <- "r_import"
  nix_names
}

read_blacklist <- function(path) {
  lines <- readLines(path)
  lines <- sub("#.*$", "", lines)
  lines <- trimws(lines)
  to_nix_name(lines[nzchar(lines)])
}

read_nix_packages <- function() {
  cmd <- "nix eval --impure --json --file rpackages_source.nix"
  raw <- system2("bash", c("-lc", shQuote(cmd)), stdout = TRUE)
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("R package jsonlite is required", call. = FALSE)
  }
  jsonlite::fromJSON(paste(raw, collapse = "\n"))
}

add_scores <- function(scores, packages, values, source) {
  rbind(
    scores,
    data.frame(
      package = to_nix_name(packages),
      score = as.numeric(values),
      source = source,
      stringsAsFactors = FALSE
    )
  )
}

blacklist <- read_blacklist("blacklist.txt")
packages <- sort(unique(read_nix_packages()))

scores <- data.frame(package = character(), score = numeric(), source = character())

bioc_scores_url <- "https://bioconductor.org/packages/stats/bioc/bioc_pkg_scores.tab"
cat("Fetching", bioc_scores_url, "\n")
tryCatch({
  bioc_scores <- read.table(url(bioc_scores_url), header = TRUE, sep = "\t", quote = "", fill = TRUE, comment.char = "")
  scores <- add_scores(scores, bioc_scores$Package, bioc_scores$Download_score, "bioc")
}, error = function(e) {
  cat("Warning: failed to refresh Bioconductor scores:", conditionMessage(e), "\n")
  if (file.exists("bioc_list.nix")) {
    bioc_names <- trimws(readLines("bioc_list.nix"))
    bioc_names <- bioc_names[!(bioc_names %in% c("[", "]"))]
    bioc_names <- gsub('^"|"$|",$', "", bioc_names)
    scores <<- add_scores(scores, bioc_names, rev(seq_along(bioc_names)), "bioc_fallback_rank")
  }
})

cran_scores_url <- "https://raw.githubusercontent.com/rstats-on-nix/top_cran_monthly/refs/heads/master/aggregated_counts.csv"
cat("Fetching", cran_scores_url, "\n")
tryCatch({
  cran_scores <- read.csv(url(cran_scores_url), header = TRUE, stringsAsFactors = FALSE)
  scores <- add_scores(scores, cran_scores$package, cran_scores$N, "cran")
}, error = function(e) cat("Warning: failed to refresh CRAN scores:", conditionMessage(e), "\n"))

if (nrow(scores) > 0) {
  best <- aggregate(score ~ package, scores, max, na.rm = TRUE)
  source_by_package <- aggregate(source ~ package, scores, function(x) paste(sort(unique(x)), collapse = ","))
  scores <- merge(best, source_by_package, by = "package", all = TRUE)
}

table <- merge(data.frame(package = packages, stringsAsFactors = FALSE), scores, by = "package", all.x = TRUE)
table$score[is.na(table$score)] <- 0
table$source[is.na(table$source)] <- ""
table$blacklisted <- table$package %in% blacklist

write.table(table[order(-table$score, table$package), ], "package_scores.tsv", sep = "\t", row.names = FALSE, quote = FALSE)
cat("Written", nrow(table), "package score rows to package_scores.tsv\n")
