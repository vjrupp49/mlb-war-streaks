# ---- Project configuration & shared helpers -------------------------------------------------
suppressPackageStartupMessages({
  library(dplyr); library(tidyr); library(readr); library(stringr); library(purrr)
  library(slider); library(ggplot2); library(scales)
})

# Find project root whether run via Rscript, source(), or RStudio
find_root <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", args[grepl("^--file=", args)])
  d <- if (length(f)) dirname(normalizePath(f[1])) else getwd()
  for (i in 1:5) {
    if (file.exists(file.path(d, "data", "reference"))) return(d)
    d <- dirname(d)
  }
  getwd()
}
ROOT <- find_root()
P <- function(...) file.path(ROOT, ...)

# Seasons analysed: Lahman 13.0.0 (R package) ends at 2024, so we stop there even though the
# Baseball-Reference WAR files already contain 2025/2026 rows.
MIN_YEAR <- 1871
MAX_YEAR <- 2024

# What counts as "MLB": National League, American League, American Association, Union
# Association, Players League and Federal League. Excluded: the National Association (1871-75;
# not treated as major league by MLB) and the Negro Leagues (in the WAR file, absent from Lahman).
MLB_LEAGUES <- c("NL", "AL", "AA", "UA", "PL", "FL")

# Era cut-offs for the pre-modern vs modern split. The PRIMARY one is 1947.
ERA_CUTOFFS <- c(1901, 1920, 1947, 1969)
PRIMARY_CUTOFF <- 1947

# Seasons shortened by strikes / war / pandemic (used for the pace-adjusted sensitivity).
SHORT_SEASONS <- c(1918, 1919, 1981, 1994, 1995, 2020)

# Season-role rule (hitter / pitcher / two-way), applied to each player-season
TWO_WAY_MIN_IP   <- 50    # innings pitched
TWO_WAY_MIN_NONP <- 30    # games at non-pitcher positions (C,1B,2B,3B,SS,OF,DH)
PITCHER_MIN_IP   <- 50

dir.create(P("output", "parts", "tables"), recursive = TRUE, showWarnings = FALSE)
dir.create(P("output", "parts", "charts"), recursive = TRUE, showWarnings = FALSE)
dir.create(P("data", "processed"), recursive = TRUE, showWarnings = FALSE)

save_table <- function(df, name) {
  write_csv(df, P("output", "parts", "tables", paste0(name, ".csv")))
  invisible(df)
}
