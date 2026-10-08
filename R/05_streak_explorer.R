# ---- 05: BONUS -- "WAR Streak Explorer" (self-contained interactive HTML) -------------------------
# Embeds every player with 30+ career WAR (~700 players) as JSON in a single offline HTML file:
#   - pick any player and any window length 1-20; see their best run of consecutive seasons
#   - all-time rank, % of the record, a season-by-season "barcode" with gaps marked
#   - "streak twins": the players whose best window had the closest year-by-year WAR shape
#   - toggle to stop military service from breaking a streak
#   - the "crown" strip: record WAR for every window length 1-20
# Output: output/streak_explorer.html  (double-click to open; no server, no internet needed)
.this_dir <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]), mustWork = FALSE))
if (is.na(.this_dir) || !nzchar(.this_dir) || .this_dir == ".") .this_dir <- file.path(getwd(), "R")
source(file.path(.this_dir, "00_config.R"))
suppressPackageStartupMessages({ library(jsonlite); library(Lahman) })

d  <- readRDS(P("data", "processed", "player_seasons.rds"))
ps <- d$ps; svc <- d$svc
hof <- HallOfFame %>% filter(inducted == "Y", category == "Player") %>% distinct(playerID) %>% pull(playerID)

role_code <- c(Hitter = 0L, Pitcher = 1L, `Two-way` = 2L)
career <- ps %>% group_by(playerID) %>% summarise(c = sum(WAR), .groups = "drop") %>% filter(c >= 30)
players <- ps %>% inner_join(career, by = "playerID") %>% arrange(playerID, yearID) %>%
  group_by(playerID) %>% summarise(
    n = first(name), c = round(first(c), 1), hof = as.integer(first(playerID) %in% hof),
    s = list(unname(pmap(list(yearID, round(WAR, 2), role_code[role]), ~ c(..1, ..2, ..3)))), .groups = "drop") %>%
  left_join(svc %>% group_by(playerID) %>% summarise(g = list(gap_year), .groups = "drop"), by = "playerID") %>%
  mutate(g = map(g, ~ if (is.null(.x)) integer(0) else .x)) %>% rename(id = playerID)

json <- toJSON(players, auto_unbox = TRUE, digits = 2)
tpl  <- readLines(file.path(.this_dir, "streak_explorer_template.html"), warn = FALSE, encoding = "UTF-8")
html <- paste(tpl, collapse = "\n")
html <- sub("/*__DATA__*/[]", paste0("/*__DATA__*/", json), html, fixed = TRUE)
out  <- P("output", "parts", "streak_explorer.html")
writeLines(html, out, useBytes = TRUE)
message(sprintf("Wrote %s (%.0f KB, %d players)", out, file.size(out) / 1024, nrow(players)))
