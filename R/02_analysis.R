# ---- 02: Consecutive-season WAR analysis ----------------------------------------------------
# Question: which MLB player has had the highest WAR in consecutive seasons?
# Four interpretations (see README), each broken out across every split:
#   A1  best 2-year stretch                       A2  best 3-/5-year (+7, 10) stretches
#   A3  longest streaks of seasons >= WAR threshold
#   A4  back-to-back seasons where BOTH are individually elite
# Run 01_load_data.R first.
.this_dir <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]), mustWork = FALSE))
if (is.na(.this_dir) || !nzchar(.this_dir) || .this_dir == ".") .this_dir <- file.path(getwd(), "R")
source(file.path(.this_dir, "00_config.R"))

d  <- readRDS(P("data", "processed", "player_seasons.rds"))
ps <- d$ps; svc <- d$svc
nm <- ps %>% distinct(playerID, name) %>% { setNames(.$name, .$playerID) }

# Where each season ranked among ALL MLB players that year (1 = best WAR in MLB)
ps <- ps %>% group_by(yearID) %>% mutate(rank_mlb = min_rank(desc(WAR))) %>% ungroup()

# ---------------------------------------------------------------------------------------------
# 1. Consecutive-season machinery
# ---------------------------------------------------------------------------------------------
# A "run" is a maximal set of seasons with no gap.  strict: calendar-consecutive only.
# bridge=TRUE: gap years listed in data/reference/military_service_gaps.csv do not break a run.
add_runs <- function(ps, bridge = FALSE) {
  s <- ps %>% arrange(playerID, yearID) %>% group_by(playerID) %>%
    mutate(prev = lag(yearID), gap = yearID - prev) %>% ungroup()
  s$joined <- !is.na(s$gap) & s$gap == 1
  if (bridge) {
    key  <- paste(svc$playerID, svc$gap_year)
    cand <- which(!is.na(s$gap) & s$gap > 1)
    s$joined[cand] <- vapply(cand, function(i)
      all(paste(s$playerID[i], (s$prev[i] + 1):(s$yearID[i] - 1)) %in% key), logical(1))
  }
  s %>% group_by(playerID) %>% mutate(run_id = cumsum(!joined)) %>%
    group_by(playerID, run_id) %>% mutate(idx = row_number(), run_len = n()) %>% ungroup()
}
seasons_strict <- add_runs(ps, FALSE)
seasons_bridge <- add_runs(ps, TRUE)

# Summarise a grouped set of seasons (a window or a threshold-run) into one row
span_summary <- function(g) {
  g %>% summarise(
    k = n(), start = min(yearID), end = max(yearID),
    WAR_sum = sum(WAR), WAR_pace_sum = sum(WAR_pace),
    WAR_min = min(WAR), WAR_max = max(WAR), WAR_avg = mean(WAR),
    WAR_bat = sum(WAR_bat), WAR_pit = sum(WAR_pit),
    war_seq = paste(sprintf("%.1f", WAR), collapse = " / "),
    n_hit = sum(role == "Hitter"), n_pit = sum(role == "Pitcher"), n_two = sum(role == "Two-way"),
    pos_group = pos_group[which.max(WAR)],
    franch_peak = franchID[which.max(WAR)], one_franchise = n_distinct(franchID) == 1,
    lg = if (n_distinct(lgID) == 1) first(lgID) else "Mixed",
    age_start = first(age), age_end = last(age), short = any(short_flag),
    rank_max = max(rank_mlb), rank_min = min(rank_mlb),
    .groups = "drop")
}
era_lab <- function(start, end, cut)
  case_when(start >= cut ~ paste0(cut, "+"), end < cut ~ paste0("Pre-", cut), TRUE ~ NA_character_)

decorate <- function(x) {
  x %>% mutate(
    name = nm[playerID],
    skipped_years = (end - start + 1) - k,
    role_label = case_when(n_hit == k ~ "Hitter", n_pit == k ~ "Pitcher", TRUE ~ "Two-way / mixed"),
    league = case_when(lg %in% c("NL", "AL") ~ lg, lg == "Mixed" ~ "Mixed", TRUE ~ "Other (AA/UA/PL/FL)"),
    decade = paste0(floor(start / 10) * 10, "s"),
    age_band = as.character(cut(age_start, c(-Inf, 24, 27, 30, Inf), labels = c("<=24", "25-27", "28-30", "31+"))),
    era_1901 = era_lab(start, end, 1901), era_1920 = era_lab(start, end, 1920),
    era_1947 = era_lab(start, end, 1947), era_1969 = era_lab(start, end, 1969))
}

# All k-season windows (k calendar-consecutive seasons).  Only windows averaging >= floor_avg
# WAR/season (raw or pace-adjusted) are expanded -- every leaderboard we publish sits far above it.
make_windows <- function(seasons, k, floor_avg = 3) {
  # rolling k-season sums via a global running total (valid wherever idx >= k, i.e. the k rows
  # ending here all belong to the same run)
  roll <- function(x) { cs <- cumsum(x); cs - c(rep(0, k), cs)[seq_along(cs)] }
  cand <- seasons %>% mutate(ws = roll(WAR), wp = roll(WAR_pace)) %>%
    filter(idx >= k, pmax(ws, wp) >= floor_avg * k) %>% select(playerID, run_id, end_idx = idx)
  cand %>% cross_join(tibble(j = 0:(k - 1))) %>% mutate(idx = end_idx - j) %>%
    inner_join(seasons, by = c("playerID", "run_id", "idx")) %>%
    arrange(playerID, run_id, end_idx, idx) %>%
    group_by(playerID, run_id, end_idx) %>% span_summary() %>% decorate()
}

# Maximal runs of consecutive seasons with `col` >= thr
make_thr_runs <- function(seasons, thr, col = "WAR") {
  seasons %>% filter(.data[[col]] >= thr) %>%
    group_by(playerID, run_id) %>% mutate(g = idx - row_number()) %>%
    group_by(playerID, run_id, g) %>% span_summary() %>% decorate()
}

# ---------------------------------------------------------------------------------------------
# 2. Leaderboard + split helpers
# ---------------------------------------------------------------------------------------------
best_per_player <- function(w, metric = "WAR_sum", tie = "WAR_sum")
  w %>% arrange(desc(.data[[metric]]), desc(.data[[tie]]), start) %>% distinct(playerID, .keep_all = TRUE)

TOP_COLS <- c("rank", "name", "playerID", "start", "end", "k", "WAR_sum", "WAR_avg", "war_seq",
              "role_label", "pos_group", "franch_peak", "league", "age_start", "short", "skipped_years",
              "WAR_bat", "WAR_pit")
leaderboard <- function(w, n = 25, metric = "WAR_sum", tie = "WAR_sum") {
  best_per_player(w, metric, tie) %>% slice_head(n = n) %>% mutate(rank = row_number()) %>%
    select(any_of(TOP_COLS)) %>% mutate(across(where(is.numeric), ~ round(.x, 2)))
}

# Long table of top-n distinct players inside every split group
all_splits <- function(w, metric = "WAR_sum", tie = "WAR_sum", n = 5) {
  specs <- list(
    list("Overall", "All", rep("All", nrow(w))),
    list("Role", "role", w$role_label),
    list("Position", "pos", w$pos_group),
    list("Decade (start year)", "decade", w$decade),
    list("Age at start", "age", w$age_band),
    list("League", "league", w$league),
    list("Franchise (one-team windows only)", "franch", if_else(w$one_franchise, w$franch_peak, NA_character_)),
    list("Era cutoff 1901", "e1901", w$era_1901), list("Era cutoff 1920", "e1920", w$era_1920),
    list("Era cutoff 1947 (PRIMARY)", "e1947", w$era_1947), list("Era cutoff 1969", "e1969", w$era_1969))
  map_dfr(specs, function(sp) {
    w %>% mutate(split_type = sp[[1]], split_value = sp[[3]]) %>%
      filter(!is.na(split_value), !is.na(.data[[metric]])) %>%
      group_by(split_type, split_value) %>% group_modify(~ leaderboard(.x, n, metric, tie) %>% select(-any_of("rank"))) %>%
      mutate(rank = row_number()) %>% ungroup()
  }) %>% relocate(split_type, split_value, rank) %>%
    mutate(across(where(is.numeric), ~ round(.x, 2)))
}

# ---------------------------------------------------------------------------------------------
# 3. A1 + A2: best k-year stretches (k = 2, 3, 5, plus 7 and 10 as bonus lengths)
# ---------------------------------------------------------------------------------------------
KS <- c(2, 3, 5, 7, 10)
win_strict <- list(); win_bridge <- list()
for (k in KS) {
  message("windows k=", k)
  win_strict[[as.character(k)]] <- make_windows(seasons_strict, k)
  win_bridge[[as.character(k)]] <- make_windows(seasons_bridge, k)
}

for (k in KS) {
  ws <- win_strict[[as.character(k)]]; wb <- win_bridge[[as.character(k)]]
  tag <- if (k == 2) "a1_two_year" else paste0("a2_k", k, "_year")
  save_table(leaderboard(ws, 30), paste0(tag, "_top30"))
  save_table(ws %>% arrange(desc(WAR_sum)) %>% slice_head(n = 40) %>% mutate(rank = row_number()) %>%
               select(any_of(TOP_COLS)) %>% mutate(across(where(is.numeric), ~ round(.x, 2))),
             paste0(tag, "_top40_all_overlapping_windows"))
  save_table(all_splits(ws), paste0(tag, "_splits"))
  # Sensitivity to how we treat shortened seasons and military service
  sens <- bind_rows(
    leaderboard(ws, 10) %>% mutate(mode = "strict (raw WAR, calendar-consecutive)"),
    leaderboard(wb, 10) %>% mutate(mode = "service-adjusted (known military gaps bridged)"),
    leaderboard(ws, 10, "WAR_pace_sum") %>% mutate(mode = "pace-adjusted (1918/19/81/94/95/2020 scaled to full season)")
  ) %>% relocate(mode)
  save_table(sens, paste0(tag, "_sensitivity_modes"))
}

# ---------------------------------------------------------------------------------------------
# 4. A3: longest streaks of seasons at/above a WAR threshold
# ---------------------------------------------------------------------------------------------
THRS <- c(4, 5, 6, 7, 8, 10)
thr_runs <- map(setNames(THRS, THRS), ~ make_thr_runs(seasons_strict, .x))
thr_bridge <- map(setNames(THRS, THRS), ~ make_thr_runs(seasons_bridge, .x))
thr_leader <- function(r, n = 25) {
  r %>% arrange(desc(k), desc(WAR_sum), start) %>% distinct(playerID, .keep_all = TRUE) %>%
    slice_head(n = n) %>% mutate(rank = row_number()) %>% select(any_of(TOP_COLS)) %>%
    mutate(across(where(is.numeric), ~ round(.x, 2)))
}
for (T in THRS) {
  save_table(thr_leader(thr_runs[[as.character(T)]]) %>% mutate(threshold = T), paste0("a3_streak_ge", T, "_top25"))
}
# splits: longest run per group (ties broken by total WAR in the run)
thr_splits <- map_dfr(THRS, function(T) {
  r <- thr_runs[[as.character(T)]]
  specs <- list(
    list("Overall", rep("All", nrow(r))), list("Role", r$role_label), list("Position", r$pos_group),
    list("Decade (start year)", r$decade), list("Age at start", r$age_band), list("League", r$league),
    list("Franchise (one-team runs only)", if_else(r$one_franchise, r$franch_peak, NA_character_)),
    list("Era cutoff 1901", r$era_1901), list("Era cutoff 1920", r$era_1920),
    list("Era cutoff 1947 (PRIMARY)", r$era_1947), list("Era cutoff 1969", r$era_1969))
  map_dfr(specs, function(sp) {
    r %>% mutate(split_type = sp[[1]], split_value = sp[[2]]) %>% filter(!is.na(split_value)) %>%
      group_by(split_type, split_value) %>%
      group_modify(~ .x %>% arrange(desc(k), desc(WAR_sum), start) %>% distinct(playerID, .keep_all = TRUE) %>%
                     slice_head(n = 5) %>% mutate(rank = row_number()) %>% select(any_of(TOP_COLS))) %>% ungroup()
  }) %>% mutate(threshold = T) %>% relocate(threshold, split_type, split_value, rank)
}) %>% mutate(across(where(is.numeric), ~ round(.x, 2)))
save_table(thr_splits, "a3_streak_splits")

# How rare are long streaks?  Number of players with a run of >= n seasons at each threshold
thr_counts <- map_dfr(THRS, function(T) {
  b <- thr_runs[[as.character(T)]] %>% group_by(playerID) %>% summarise(best = max(k), .groups = "drop")
  tibble(threshold = T, run_len = 1:max(b$best), players = map_int(1:max(b$best), ~ sum(b$best >= .x)))
})
save_table(thr_counts, "a3_streak_player_counts")

# Service-adjusted view of the long streaks (does bridging war years change the leaders?)
save_table(map_dfr(THRS, ~ thr_leader(thr_bridge[[as.character(.x)]], 10) %>% mutate(threshold = .x)) %>%
             relocate(threshold), "a3_streak_top10_service_adjusted")

# ---------------------------------------------------------------------------------------------
# 5. A4: back-to-back seasons where BOTH seasons are individually elite
# ---------------------------------------------------------------------------------------------
pairs <- win_strict[["2"]]
elite_defs <- list(
  `both >= 6 WAR`  = list(f = quote(WAR_min >= 6),  m = "WAR_sum"),
  `both >= 8 WAR`  = list(f = quote(WAR_min >= 8),  m = "WAR_sum"),
  `both >= 10 WAR` = list(f = quote(WAR_min >= 10), m = "WAR_sum"),
  `both seasons top-5 in MLB (WAR)` = list(f = quote(rank_max <= 5), m = "WAR_sum"),
  `both seasons #1 in MLB (WAR)`    = list(f = quote(rank_max <= 1), m = "WAR_sum"),
  `highest FLOOR (weaker of the two seasons)` = list(f = quote(TRUE), m = "WAR_min"))
a4 <- imap(elite_defs, function(def, nm_def) {
  w <- pairs %>% filter(!!def$f)
  list(top = leaderboard(w, 25, def$m, "WAR_sum") %>% mutate(definition = nm_def),
       splits = all_splits(w, def$m, "WAR_sum", n = 3) %>% mutate(definition = nm_def),
       n_pairs = nrow(w), n_players = n_distinct(w$playerID))
})
save_table(map_dfr(a4, "top") %>% relocate(definition), "a4_elite_pairs_top25")
save_table(map_dfr(a4, "splits") %>% relocate(definition), "a4_elite_pairs_splits")
save_table(tibble(definition = names(a4), pairs = map_int(a4, "n_pairs"), players = map_int(a4, "n_players")),
           "a4_elite_pairs_counts")
# sensitivity: pace/service-adjusted floor and elite lists
pairs_b <- win_bridge[["2"]]
save_table(bind_rows(
  leaderboard(pairs %>% filter(WAR_min >= 8), 15) %>% mutate(mode = "strict"),
  leaderboard(pairs_b %>% filter(WAR_min >= 8), 15) %>% mutate(mode = "service-adjusted")) %>%
    relocate(mode), "a4_elite_pairs_sensitivity")

# ---------------------------------------------------------------------------------------------
# 6. Peak vs longevity
# ---------------------------------------------------------------------------------------------
w5 <- win_strict[["5"]]; w3 <- win_strict[["3"]]
streak5 <- thr_runs[["5"]] %>% group_by(playerID) %>% summarise(longest_5plus = max(k), .groups = "drop")
pl <- ps %>% group_by(playerID, name) %>%
  summarise(seasons = n(), first_year = min(yearID), last_year = max(yearID), career_WAR = sum(WAR),
            best_season = max(WAR), n_5plus = sum(WAR >= 5), n_8plus = sum(WAR >= 8),
            pos_group = { t <- sort(table(pos_group), decreasing = TRUE); if (length(t)) names(t)[1] else NA_character_ }, .groups = "drop") %>%
  left_join(best_per_player(w3) %>% select(playerID, best3 = WAR_sum), by = "playerID") %>%
  left_join(best_per_player(w5) %>% select(playerID, best5 = WAR_sum), by = "playerID") %>%
  left_join(streak5, by = "playerID") %>%
  mutate(across(c(best3, best5, longest_5plus), ~ replace_na(.x, 0)),
         peak5_share = best5 / career_WAR,
         career_type = case_when(career_WAR >= 40 & peak5_share >= 0.55 ~ "Peak-heavy (>=55% of WAR in best 5 yrs)",
                                 career_WAR >= 40 & peak5_share <= 0.35 ~ "Longevity (<=35% of WAR in best 5 yrs)",
                                 career_WAR >= 40 ~ "Balanced", TRUE ~ NA_character_)) %>%
  mutate(across(where(is.numeric), ~ round(.x, 2))) %>% arrange(desc(career_WAR))
save_table(pl %>% filter(career_WAR >= 30), "peak_vs_longevity")

# ---------------------------------------------------------------------------------------------
# 7. Era-cutoff sensitivity summary: top-5 players (best 2-/5-year windows) under each cut-off
# ---------------------------------------------------------------------------------------------
era_sens <- map_dfr(c(2, 5), function(k) {
  w <- win_strict[[as.character(k)]]
  map_dfr(ERA_CUTOFFS, function(cut) {
    col <- paste0("era_", cut)
    map_dfr(c(paste0("Pre-", cut), paste0(cut, "+")), function(side)
      leaderboard(w %>% filter(.data[[col]] == side), 5) %>% mutate(k = k, cutoff = cut, side = side))
  })
}) %>% relocate(k, cutoff, side)
save_table(era_sens, "era_cutoff_sensitivity")

# The "crown": who holds the best k-year window for every k (feeds the explorer + a chart)
crown <- map_dfr(1:20, function(k) {
  w <- if (k == 1) ps %>% transmute(playerID, name = nm[playerID], start = yearID, end = yearID, k = 1, WAR_sum = WAR, role_label = role)
       else make_windows(seasons_strict, k, floor_avg = 4)
  best_per_player(w) %>% slice_head(n = 3) %>% mutate(rank = row_number(), k = k) %>%
    select(k, rank, name, playerID, start, end, WAR_sum)
}) %>% mutate(WAR_sum = round(WAR_sum, 1))
save_table(crown, "crown_best_window_by_length")

saveRDS(list(win_strict = win_strict, win_bridge = win_bridge, thr_runs = thr_runs, pl = pl, crown = crown, ps = ps,
             a4 = a4, era_sens = era_sens), P("data", "processed", "analysis_objects.rds"))
message("Analysis done: ", length(list.files(P("output", "parts", "tables"))), " tables in output/parts/tables")
