# ---- 01: Load Lahman + Baseball-Reference WAR and build the player-season table -------------
# Output: data/processed/player_seasons.rds  (one row per player-season, all stints combined)
.this_dir <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]), mustWork = FALSE))
if (is.na(.this_dir) || !nzchar(.this_dir) || .this_dir == ".") .this_dir <- file.path(getwd(), "R")
source(file.path(.this_dir, "00_config.R"))
suppressPackageStartupMessages(library(Lahman))

bat_url   <- "https://www.baseball-reference.com/data/war_daily_bat.txt"
pitch_url <- "https://www.baseball-reference.com/data/war_daily_pitch.txt"
bat_file   <- P("data", "raw", "war_daily_bat.txt")
pitch_file <- P("data", "raw", "war_daily_pitch.txt")
dir.create(P("data", "raw"), recursive = TRUE, showWarnings = FALSE)

# ---- 1. WAR download (cached; delete the files to refresh) ----
dl <- function(url, dest) {
  if (file.exists(dest) && file.size(dest) > 1e6) return(invisible(TRUE))
  message("Downloading ", url)
  ok <- tryCatch({
    download.file(url, dest, mode = "wb", quiet = TRUE, headers = c("User-Agent" = "Mozilla/5.0"))
    TRUE
  }, error = function(e) FALSE)
  if (!ok || !file.exists(dest) || file.size(dest) < 1e6)
    stop("WAR download blocked/failed for ", url, ".\nSave it manually to ", dest,
         " (a browser download works) and re-run. Do NOT substitute another stat silently.")
  invisible(TRUE)
}
dl(bat_url, bat_file); dl(pitch_url, pitch_file)

nas <- c("NA", "NULL", "")
bat   <- read_csv(bat_file,   na = nas, show_col_types = FALSE, guess_max = 1e5)
pitch <- read_csv(pitch_file, na = nas, show_col_types = FALSE, guess_max = 1e5)
message(sprintf("WAR files: %s batting rows, %s pitching rows (years %d-%d)",
                format(nrow(bat), big.mark = ","), format(nrow(pitch), big.mark = ","),
                min(bat$year_ID), max(bat$year_ID)))

# ---- 2. Stint level -> player-season (a traded player has several stints per year) ----
# Total WAR = position-player WAR (war_daily_bat: bat + baserunning + fielding + position +
# replacement, for ALL players incl. pitchers' hitting) + pitching WAR (war_daily_pitch).
# This is how Baseball-Reference's own player pages total WAR, and it is what lets two-way
# players (Ruth, Ohtani) get credit for both halves.
# NA WAR rows are all tiny (<=37 PA / 0 IP, mostly Negro League pitchers) and are treated as 0.
bat_s <- bat %>%
  filter(lg_ID %in% MLB_LEAGUES, year_ID >= MIN_YEAR, year_ID <= MAX_YEAR) %>%
  group_by(bbrefID = player_ID, yearID = year_ID) %>%
  summarise(WAR_bat = sum(WAR, na.rm = TRUE), PA = sum(PA, na.rm = TRUE),
            age = first(age), name_bbref = first(name_common),
            # stint with the most PA decides team/league for traded players
            teamID = team_ID[which.max(PA)], lgID = lg_ID[which.max(PA)],
            .groups = "drop")
pit_s <- pitch %>%
  filter(lg_ID %in% MLB_LEAGUES, year_ID >= MIN_YEAR, year_ID <= MAX_YEAR) %>%
  group_by(bbrefID = player_ID, yearID = year_ID) %>%
  summarise(WAR_pit = sum(WAR, na.rm = TRUE), IP = sum(IPouts, na.rm = TRUE) / 3,
            age_p = first(age), name_p = first(name_common),
            teamID_p = team_ID[which.max(IPouts)], lgID_p = lg_ID[which.max(IPouts)],
            .groups = "drop")

ps <- full_join(bat_s, pit_s, by = c("bbrefID", "yearID")) %>%
  mutate(across(c(WAR_bat, WAR_pit, PA, IP), ~ replace_na(.x, 0)),
         age = coalesce(age, age_p), name_bbref = coalesce(name_bbref, name_p),
         # team/league of the larger contributor
         use_p = IP > 0 & WAR_pit > WAR_bat & !is.na(teamID_p),
         teamID = if_else(is.na(teamID) | use_p, coalesce(teamID_p, teamID), teamID),
         lgID   = if_else(is.na(lgID)   | use_p, coalesce(lgID_p, lgID), lgID),
         WAR = WAR_bat + WAR_pit) %>%
  select(-age_p, -name_p, -teamID_p, -lgID_p, -use_p)

# ---- 3. Join to Lahman by playerID (Lahman People$bbrefID == B-Ref player_ID) ----
people <- People %>% filter(!is.na(bbrefID)) %>% distinct(bbrefID, .keep_all = TRUE) %>%
  transmute(playerID, bbrefID, name = paste(nameFirst, nameLast), birthYear, debut, finalGame,
            bats, throws)

unmatched <- ps %>% anti_join(people, by = "bbrefID") %>%
  group_by(bbrefID, name_bbref) %>% summarise(seasons = n(), WAR = sum(WAR), .groups = "drop") %>%
  arrange(desc(WAR))
save_table(unmatched, "diag_unmatched_war_players")
message(sprintf("Unmatched WAR players (no Lahman bbrefID): %d (sum of |WAR| = %.1f)",
                nrow(unmatched), sum(abs(unmatched$WAR))))

ps <- ps %>% inner_join(people, by = "bbrefID")

# ---- 4. Lahman Appearances -> games by position, primary position ----
app <- Appearances %>%
  filter(yearID >= MIN_YEAR, yearID <= MAX_YEAR) %>%
  group_by(playerID, yearID) %>%
  summarise(across(c(G_all, G_p, G_c, G_1b, G_2b, G_3b, G_ss, G_lf, G_cf, G_rf, G_dh), sum),
            .groups = "drop") %>%
  mutate(G_nonp = G_c + G_1b + G_2b + G_3b + G_ss + G_lf + G_cf + G_rf + G_dh)

pos_cols <- c(P = "G_p", C = "G_c", `1B` = "G_1b", `2B` = "G_2b", `3B` = "G_3b", SS = "G_ss",
              LF = "G_lf", CF = "G_cf", RF = "G_rf", DH = "G_dh")
app$pos <- names(pos_cols)[max.col(as.matrix(app[, unname(pos_cols)]), ties.method = "first")]
app$pos[rowSums(app[, unname(pos_cols)]) == 0] <- NA

ps <- ps %>% left_join(app %>% select(playerID, yearID, G_all, G_p, G_nonp, pos),
                       by = c("playerID", "yearID"))

# ---- 5. Franchise (Lahman Teams -> franchID) ----
# B-Ref team codes (SFG, NYY, LAA...) differ from Lahman's teamID (SFN, NYA, ANA...), so join on
# Lahman's teamIDBR column.
fr <- Teams %>% filter(!is.na(teamIDBR)) %>% transmute(yearID, teamID = teamIDBR, franchID) %>%
  distinct(yearID, teamID, .keep_all = TRUE)
ps <- ps %>% left_join(fr, by = c("yearID", "teamID"))

# ---- 6. Season role: Hitter / Pitcher / Two-way ----
# Two-way: >= 50 IP AND >= 30 games at non-pitcher positions (incl. DH) in the same season
# (Ruth 1918-19, Ohtani 2021-23, 1880s pitcher-outfielders).  Pitcher: >= 50 IP otherwise.
# Everyone else is a Hitter (position players mopping up blowouts stay Hitters).
ps <- ps %>%
  mutate(G_nonp = replace_na(G_nonp, 0L), G_p = replace_na(G_p, 0L),
         role = case_when(IP >= TWO_WAY_MIN_IP & G_nonp >= TWO_WAY_MIN_NONP ~ "Two-way",
                          IP >= PITCHER_MIN_IP ~ "Pitcher",
                          TRUE ~ "Hitter"),
         pos_group = case_when(role == "Pitcher" ~ "P", role == "Two-way" ~ "Two-way",
                               pos %in% c("LF", "CF", "RF") ~ "OF", pos == "P" ~ "P",
                               is.na(pos) ~ NA_character_, TRUE ~ pos))

# ---- 7. Season length (strike-shortened flags and pace adjustment) ----
len <- Teams %>% filter(lgID %in% MLB_LEAGUES, yearID >= MIN_YEAR) %>%
  group_by(yearID) %>% summarise(median_team_G = median(G), .groups = "drop")
std_len <- map_dbl(len$yearID, function(y) {
  nb <- len %>% filter(abs(yearID - y) <= 3, !(yearID %in% SHORT_SEASONS))
  max(nb$median_team_G)
})
season_len <- len %>% mutate(std_G = std_len, short_flag = yearID %in% SHORT_SEASONS,
                             pace_factor = if_else(short_flag, std_G / median_team_G, 1))
save_table(season_len %>% filter(yearID >= 1900), "diag_season_lengths")

ps <- ps %>% left_join(season_len %>% select(yearID, short_flag, pace_factor), by = "yearID") %>%
  mutate(WAR_pace = WAR * pace_factor,           # WAR scaled up to a full-length season
         age = as.integer(age)) %>%
  arrange(playerID, yearID)

# ---- 8. Military-service gap list ----
svc <- read_csv(P("data", "reference", "military_service_gaps.csv"), show_col_types = FALSE) %>%
  separate_longer_delim(gap_years, ";") %>% transmute(playerID, gap_year = as.integer(gap_years))

# ---- 9. Diagnostics ----
diag <- ps %>% summarise(player_seasons = n(), players = n_distinct(playerID),
                         first_year = min(yearID), last_year = max(yearID),
                         total_WAR = round(sum(WAR), 1), missing_pos = sum(is.na(pos)),
                         missing_franchise = sum(is.na(franchID)))
print(as.data.frame(diag))
save_table(diag, "diag_load_summary")
saveRDS(list(ps = ps, svc = svc, season_len = season_len), P("data", "processed", "player_seasons.rds"))
write_csv(ps %>% select(playerID, name, yearID, age, teamID, franchID, lgID, role, pos, PA, IP,
                        WAR_bat, WAR_pit, WAR, short_flag, WAR_pace),
          P("data", "processed", "player_seasons.csv"))
message("Saved data/processed/player_seasons.rds and .csv")
