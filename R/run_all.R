# Run the whole pipeline end to end:  Rscript R/run_all.R   (from the project root)
# Needs R packages: tidyverse (dplyr, tidyr, readr, stringr, purrr, ggplot2, scales), slider,
# Lahman, ggrepel, patchwork, jsonlite.
args <- commandArgs(FALSE)
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", args, value = TRUE)[1]), mustWork = FALSE))
if (is.na(here) || !nzchar(here) || here == ".") here <- file.path(getwd(), "R")
rscript <- file.path(R.home("bin"), "Rscript")
for (s in c("01_load_data.R", "02_analysis.R", "03_sanity_checks.R", "04_charts.R", "05_streak_explorer.R")) {
  message("\n===== ", s, " =====")
  status <- system2(rscript, shQuote(file.path(here, s)))
  if (status != 0) stop("Step failed: ", s)
}
message("\nAll done. See output/ (tables, charts, streak_explorer.html) and README.md")
