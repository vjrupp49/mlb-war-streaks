# ---- 03: Sanity checks & edge-case demonstrations -------------------------------------------
# Verifies the pipeline against well-known results and shows how each edge case is handled.
# Run after 01_load_data.R and 02_analysis.R.  Writes output/tables/sanity_*.csv and
# output/sanity_checks_report.txt
.this_dir <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]), mustWork = FALSE))
if (is.na(.this_dir) || !nzchar(.this_dir) || .this_dir == ".") .this_dir <- file.path(getwd(), "R")
source(file.path(.this_dir, "00_config.R"))

ao <- readRDS(P("data", "processed", "analysis_objects.rds"))
ps <- ao$ps; ws <- ao$win_strict; wb <- ao$win_bridge
rep_lines <- character()
say <- function(...) { l <- paste0(...); rep_lines <<- c(rep_lines, l); message(l) }

# ---- 1. Structural integrity -----------------------------------------------------------------
checks <- tibble(check = character(), result = character(), pass = logical())
add <- function(check, result, pass) checks <<- bind_rows(checks, tibble(check = check, result = result, pass = pass))
add("one row per player-season", paste(nrow(ps), "rows,", nrow(distinct(ps, playerID, yearID)), "distinct"),
    nrow(ps) == nrow(distinct(ps, playerID, yearID)))
add("WAR == WAR_bat + WAR_pit everywhere", sprintf("max |diff| = %.2e", max(abs(ps$WAR - ps$WAR_bat - ps$WAR_pit))),
    max(abs(ps$WAR - ps$WAR_bat - ps$WAR_pit)) < 1e-9)
add("no missing WAR", paste(sum(is.na(ps$WAR)), "NAs"), !anyNA(ps$WAR))
add("seasons within 1871-2024", paste(range(ps$yearID), collapse = "-"), min(ps$yearID) >= 1871 && max(ps$yearID) <= 2024)
add("only MLB leagues", paste(sort(unique(ps$lgID)), collapse = ","), all(ps$lgID %in% MLB_LEAGUES))
add("franchise match rate", sprintf("%.1f%% of player-seasons have a Lahman franchise", 100 * mean(!is.na(ps$franchID))),
    mean(!is.na(ps$franchID)) > 0.99)
add("all-time WAR is roughly zero-sum around replacement (sanity of scale)",
    sprintf("mean WAR per player-season = %.2f", mean(ps$WAR)), abs(mean(ps$WAR)) < 2)

# ---- 2. Career totals vs. widely quoted Baseball-Reference totals (approximate!) ---------------
# Expected values are rounded figures from Baseball-Reference player pages as I know them
# (Ruth = 182.6 total = 162.1 as a position player + ~20.5 pitching; checked separately below);
# B-Ref revises WAR periodically, so allow +/- 8 WAR.  This only guards against pipeline errors
# (double counting, missing pitching/hitting half, bad joins) -- not against methodology drift.
known <- tribble(
  ~playerID,   ~expected,
  "ruthba01",  182.6, "bondsba01", 162.8, "mayswi01",  156.2, "mantlmi01", 109.7,
  "gibsobo01",  89.9, "clemero02", 139.2, "maddugr01", 106.6, "troutmi01",  86.0,
  "willite01", 122.1, "youngcy01", 163.6, "johnswa01", 165.6, "aaronha01", 143.1,
  "cobbty01",  151.4, "musiast01", 128.3, "wagneho01", 130.8, "johnsra05", 102.1)
career <- ps %>% group_by(playerID, name) %>% summarise(model = sum(WAR), .groups = "drop") %>%
  inner_join(known, by = "playerID") %>% mutate(diff = model - expected, ok = abs(diff) <= 8) %>%
  mutate(across(c(model, diff), ~ round(.x, 1)))
save_table(career, "sanity_career_totals")
rr <- ps %>% filter(playerID == "ruthba01") %>% summarise(bat = sum(WAR_bat), pit = sum(WAR_pit))
add("Ruth: hitting WAR 162.1 (B-Ref position-player total) + pitching ~20.5 are both captured",
    sprintf("bat %.1f + pit %.1f = %.1f", rr$bat, rr$pit, rr$bat + rr$pit), abs(rr$bat - 162.1) < 1 && abs(rr$pit - 20.5) < 1.5)
add("career totals within 8 WAR of B-Ref (16 icons)", sprintf("%d / %d within tolerance", sum(career$ok), nrow(career)), all(career$ok))

# ---- 3. Do the legends show up where expected? ------------------------------------------------
best_pp <- function(w) w %>% arrange(desc(WAR_sum), start) %>% distinct(playerID, .keep_all = TRUE) %>% mutate(rank = row_number())
icons <- c(ruthba01 = "Babe Ruth", bondsba01 = "Barry Bonds", mayswi01 = "Willie Mays", mantlmi01 = "Mickey Mantle",
           gibsobo01 = "Bob Gibson", clemero02 = "Roger Clemens", maddugr01 = "Greg Maddux", troutmi01 = "Mike Trout",
           willite01 = "Ted Williams", ohtansh01 = "Shohei Ohtani")
icon_ranks <- map_dfr(c(2, 3, 5), function(k) {
  best_pp(ws[[as.character(k)]]) %>% filter(playerID %in% names(icons)) %>%
    transmute(k, player = name, best_window = paste0(start, "-", end), WAR = round(WAR_sum, 1), rank_among_players = rank)
}) %>% arrange(player, k)
save_table(icon_ranks, "sanity_icon_ranks")
top10_names <- function(k) best_pp(ws[[as.character(k)]])$name[1:10]
# NOTE: an overall ranking is dominated by 1876-1890s pitchers (Radbourn, Devlin, ...), so the
# "legends appear where expected" checks are made within role / era, where the expectation is sensible.
mod <- function(w) w %>% filter(era_1947 == "1947+")
hit <- function(w) w %>% filter(role_label == "Hitter")
add("Ruth is the #1 HITTER for best 2-year stretch (1923-24)", {x <- best_pp(hit(ws[["2"]]))[1, ]; paste(x$name, x$start, x$end)}, best_pp(hit(ws[["2"]]))$name[1] == "Babe Ruth")
add("Ruth is #2 overall for best 5-year stretch (only Walter Johnson ahead)", paste(best_pp(ws[["5"]])$name[1:2], collapse = ", "), best_pp(ws[["5"]])$name[2] == "Babe Ruth")
add("Bonds is a top-3 post-1946 3-year stretch and top-10 overall 5-year stretch",
    paste(paste(best_pp(mod(ws[["3"]]))$name[1:3], collapse = ", "), "|", which(best_pp(ws[["5"]])$name == "Barry Bonds")),
    "Barry Bonds" %in% best_pp(mod(ws[["3"]]))$name[1:3] && which(best_pp(ws[["5"]])$name == "Barry Bonds") <= 10)
rk <- icon_ranks %>% filter(k == 5)
add("Mays, Mantle, Gibson, Clemens, Maddux, Trout all rank top-60 for best 5-year WAR",
    paste(rk$player[rk$player %in% c("Willie Mays", "Mickey Mantle", "Bob Gibson", "Roger Clemens", "Greg Maddux", "Mike Trout")],
          rk$rank_among_players[rk$player %in% c("Willie Mays", "Mickey Mantle", "Bob Gibson", "Roger Clemens", "Greg Maddux", "Mike Trout")], collapse = "; "),
    all(rk$rank_among_players[rk$player %in% c("Willie Mays", "Mickey Mantle", "Bob Gibson", "Roger Clemens", "Greg Maddux", "Mike Trout")] <= 60) &&
      sum(rk$player %in% c("Willie Mays", "Mickey Mantle", "Bob Gibson", "Roger Clemens", "Greg Maddux", "Mike Trout")) == 6)

# ---- 4. Edge case: mid-season trades (stints are merged into one season) --------------------------
trades <- ps %>% filter(playerID %in% c("sabatcc01", "johnsra05", "ramirma02", "mcgwima01", "hendera01") &
                          ((playerID == "sabatcc01" & yearID == 2008) | (playerID == "johnsra05" & yearID == 1998) |
                           (playerID == "ramirma02" & yearID == 2008) | (playerID == "mcgwima01" & yearID == 1997) |
                           (playerID == "hendera01" & yearID %in% c(1989, 1993)))) %>%
  select(name, yearID, teamID, lgID, WAR_bat, WAR_pit, WAR) %>% mutate(across(where(is.numeric) & !yearID, ~ round(.x, 2)))
save_table(trades, "sanity_traded_players")
say("Traded players are summed across stints (e.g. Sabathia 2008 CLE+MIL, Johnson 1998 SEA+HOU): one row each, lgID/team = the stint with the most PA/IP.")

# ---- 5. Edge case: two-way players ------------------------------------------------------------
tw <- ps %>% filter(playerID %in% c("ruthba01", "ohtansh01"), WAR_pit != 0 | role != "Hitter") %>%
  select(name, yearID, role, PA, IP, WAR_bat, WAR_pit, WAR) %>% mutate(across(where(is.numeric) & !yearID, ~ round(.x, 2)))
save_table(tw, "sanity_two_way_seasons")
add("Ruth 1918-1919 and Ohtani 2021-2023 are labelled Two-way",
    paste(ps$role[ps$playerID == "ruthba01" & ps$yearID %in% 1918:1919], ps$role[ps$playerID == "ohtansh01" & ps$yearID %in% 2021:2023], collapse = " "),
    all(ps$role[ps$playerID == "ruthba01" & ps$yearID %in% 1918:1919] == "Two-way") &&
      all(ps$role[ps$playerID == "ohtansh01" & ps$yearID %in% 2021:2023] == "Two-way"))
add("Ohtani 2024 (DH only, no pitching) is a Hitter", ps$role[ps$playerID == "ohtansh01" & ps$yearID == 2024],
    ps$role[ps$playerID == "ohtansh01" & ps$yearID == 2024] == "Hitter")

# ---- 6. Edge case: shortened seasons ------------------------------------------------------------
sh <- ps %>% filter(short_flag, yearID >= 1981) %>% group_by(yearID) %>% slice_max(WAR, n = 3, with_ties = FALSE) %>%
  ungroup() %>% select(yearID, name, WAR_raw = WAR, WAR_pace_adj = WAR_pace, pace_factor) %>%
  mutate(across(where(is.numeric) & !yearID, ~ round(.x, 2)))
save_table(sh, "sanity_shortened_seasons_top3")
add("shortened seasons flagged (1918, 1919, 1981, 1994, 1995, 2020)", paste(sort(unique(ps$yearID[ps$short_flag])), collapse = ","),
    identical(sort(unique(ps$yearID[ps$short_flag])), sort(SHORT_SEASONS)))
add("2020 pace factor ~ 162/60", sprintf("%.2f", unique(ps$pace_factor[ps$yearID == 2020])),
    abs(unique(ps$pace_factor[ps$yearID == 2020]) - 2.7) < 0.01)

# ---- 7. Edge case: gaps and military service ------------------------------------------------------
svc_demo <- map_dfr(c("willite01", "mayswi01", "dimagjo01", "fellebo01", "musiast01", "mizejo01"), function(p) {
  map_dfr(c(2, 5), function(k) {
    s <- ws[[as.character(k)]] %>% filter(playerID == p) %>% arrange(desc(WAR_sum)) %>% slice_head(n = 1) %>% mutate(mode = "strict")
    b <- wb[[as.character(k)]] %>% filter(playerID == p) %>% arrange(desc(WAR_sum)) %>% slice_head(n = 1) %>% mutate(mode = "service-adjusted")
    bind_rows(s, b)
  })
}) %>% transmute(name, k, mode, window = paste0(start, "-", end), seasons_skipped = skipped_years, WAR = round(WAR_sum, 1), war_seq) %>%
  arrange(name, k, mode)
save_table(svc_demo, "sanity_military_service_effect")
tw5 <- svc_demo %>% filter(name == "Ted Williams", k == 5)
add("Williams best 5-yr: service-adjusted bridges 1943-45 and beats strict",
    paste(tw5$mode, tw5$window, tw5$WAR, collapse = " | "),
    tw5$WAR[tw5$mode == "service-adjusted"] > tw5$WAR[tw5$mode == "strict"] && tw5$seasons_skipped[tw5$mode == "service-adjusted"] > 0)
add("Mays 1952 appears as a partial season (34 G) and 1953 is absent",
    paste0(sum(ps$playerID == "mayswi01" & ps$yearID == 1952), " row 1952; ", sum(ps$playerID == "mayswi01" & ps$yearID == 1953), " rows 1953"),
    sum(ps$playerID == "mayswi01" & ps$yearID == 1952) == 1 && sum(ps$playerID == "mayswi01" & ps$yearID == 1953) == 0)

# Elite seasons separated by a gap: why "consecutive" matters
gaps <- ps %>% arrange(playerID, yearID) %>% group_by(playerID) %>%
  mutate(next_year = lead(yearID), next_WAR = lead(WAR), gap = next_year - yearID) %>% ungroup() %>%
  filter(!is.na(gap), gap > 1) %>%
  transmute(name, year_a = yearID, year_b = next_year, years_missing = gap - 1, WAR_a = round(WAR, 1), WAR_b = round(next_WAR, 1),
            WAR_pair = round(WAR + next_WAR, 1), min_WAR = round(pmin(WAR, next_WAR), 1)) %>%
  arrange(desc(WAR_pair)) %>% slice_head(n = 15)
save_table(gaps, "sanity_best_gap_pairs_not_counted")
add("gap pairs are excluded from consecutive windows",
    paste(gaps$name[1], gaps$year_a[1], "->", gaps$year_b[1]),
    !any(ws[["2"]]$playerID == "willite01" & ws[["2"]]$start == 1942))

# ---- 8. Consistency between analyses -----------------------------------------------------------------
w2 <- ws[["2"]]
top_pair <- w2 %>% arrange(desc(WAR_sum)) %>% slice(1)
add("best 2-yr window equals sum of its two seasons",
    sprintf("%s %d-%d = %.2f", top_pair$name, top_pair$start, top_pair$end, top_pair$WAR_sum),
    abs(top_pair$WAR_sum - sum(ps$WAR[ps$playerID == top_pair$playerID & ps$yearID %in% top_pair$start:top_pair$end])) < 1e-8)
add("no window spans a missing year (strict mode)", paste(sum(w2$skipped_years != 0), "windows with skipped years"), all(w2$skipped_years == 0))

save_table(checks, "sanity_checks_summary")
say("")
say(sprintf("SANITY CHECKS: %d / %d passed", sum(checks$pass), nrow(checks)))
for (i in seq_len(nrow(checks))) say(sprintf("  [%s] %s -- %s", if (checks$pass[i]) "PASS" else "FAIL", checks$check[i], checks$result[i]))
writeLines(rep_lines, P("output", "parts", "sanity_checks_report.txt"))
