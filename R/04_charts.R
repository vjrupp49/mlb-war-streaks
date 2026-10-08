# ---- 04: Charts ----------------------------------------------------------------------------------
# Reads data/processed/analysis_objects.rds, writes PNGs to output/charts/.
.this_dir <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]), mustWork = FALSE))
if (is.na(.this_dir) || !nzchar(.this_dir) || .this_dir == ".") .this_dir <- file.path(getwd(), "R")
source(file.path(.this_dir, "00_config.R"))
suppressPackageStartupMessages({ library(ggrepel); library(patchwork) })

ao <- readRDS(P("data", "processed", "analysis_objects.rds"))
ps <- ao$ps; ws <- ao$win_strict; thr <- ao$thr_runs; pl <- ao$pl; crown <- ao$crown; a4 <- ao$a4

role_cols <- c("Hitter" = "#2b6cb0", "Pitcher" = "#d9622b", "Two-way / mixed" = "#7b3fa0")
theme_war <- theme_minimal(base_size = 12) +
  theme(plot.title = element_text(face = "bold", size = 15), plot.subtitle = element_text(colour = "grey35"),
        plot.caption = element_text(colour = "grey45", size = 8), panel.grid.minor = element_blank(),
        panel.grid.major.y = element_blank(), legend.position = "bottom",
        strip.text = element_text(face = "bold"), plot.title.position = "plot")
CAP <- "WAR: Baseball-Reference daily files (bat + pitch). Seasons: Lahman 13.0.0, 1871-2024. Stretch = calendar-consecutive seasons."
save_plot <- function(p, name, w = 11, h = 7) ggsave(P("output", "parts", "charts", name), p, width = w, height = h, dpi = 150, bg = "white")
dash <- "–"
lab_win <- function(n, s, e) paste0(n, "  ", s, dash, substr(e, 3, 4))

best_pp <- function(w, metric = "WAR_sum") w %>% arrange(desc(.data[[metric]]), start) %>% distinct(playerID, .keep_all = TRUE)

# 1. Best two-year stretches: stacked by season --------------------------------------------------------
top2 <- best_pp(ws[["2"]]) %>% slice_head(n = 15) %>% mutate(lab = lab_win(name, start, end))
seas2 <- top2 %>% select(playerID, start, end, lab, role_label, WAR_sum) %>%
  inner_join(ps %>% select(playerID, yearID, WAR), by = "playerID", relationship = "many-to-many") %>%
  filter(yearID >= start, yearID <= end) %>% mutate(which = factor(if_else(yearID == start, "First season", "Second season"), c("Second season", "First season")))
p1 <- ggplot(seas2, aes(WAR, reorder(lab, WAR_sum), fill = role_label, alpha = which)) +
  geom_col(colour = "white", linewidth = 0.4) +
  geom_text(data = top2, aes(x = WAR_sum + 0.3, y = lab, label = sprintf("%.1f", WAR_sum)), inherit.aes = FALSE, hjust = 0, size = 3.6, fontface = "bold") +
  scale_fill_manual(values = role_cols, name = NULL) + scale_alpha_manual(values = c("First season" = 1, "Second season" = 0.62), name = NULL) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.08))) +
  labs(title = "The best two-year stretches in baseball history", subtitle = "Best back-to-back-season WAR per player (each player appears once)",
       x = "Combined WAR over two consecutive seasons", y = NULL, caption = CAP) + theme_war
save_plot(p1, "01_best_two_year_stretches.png", 11, 7.5)

# 2. Best 3- and 5-year stretches ------------------------------------------------------------------------
bar_k <- function(k, n = 12) {
  d <- best_pp(ws[[as.character(k)]]) %>% slice_head(n = n) %>% mutate(lab = lab_win(name, start, end))
  ggplot(d, aes(WAR_sum, reorder(lab, WAR_sum), fill = role_label)) + geom_col(width = 0.75) +
    geom_text(aes(label = sprintf("%.1f", WAR_sum)), hjust = 1.15, colour = "white", size = 3.5, fontface = "bold") +
    scale_fill_manual(values = role_cols, name = NULL) + scale_x_continuous(expand = expansion(mult = c(0, 0.02))) +
    labs(title = paste0("Best ", k, "-year stretch"), x = "WAR", y = NULL) + theme_war
}
p2 <- (bar_k(3) | bar_k(5)) + plot_layout(guides = "collect") &
  theme(legend.position = "bottom")
p2 <- p2 + plot_annotation(title = "Best three- and five-year stretches", caption = CAP,
                           theme = theme(plot.title = element_text(face = "bold", size = 15), plot.caption = element_text(colour = "grey45", size = 8)))
save_plot(p2, "02_best_3_and_5_year_stretches.png", 14, 6.5)

# 3. Longest streaks above a WAR threshold --------------------------------------------------------------------
thr_top <- map_dfr(c(5, 6, 8), function(T) {
  thr[[as.character(T)]] %>% arrange(desc(k), desc(WAR_sum)) %>% distinct(playerID, .keep_all = TRUE) %>% slice_head(n = 10) %>%
    mutate(threshold = paste0(T, "+ WAR every season"), lab = paste0(name, "  ", start, dash, substr(end, 3, 4)))
}) %>% group_by(threshold) %>% arrange(k, WAR_sum, .by_group = TRUE) %>% mutate(ord = row_number()) %>% ungroup()
p3 <- ggplot(thr_top, aes(k, ord, colour = role_label)) +
  geom_segment(aes(x = 0, xend = k, yend = ord), linewidth = 1.2) + geom_point(size = 3.5) +
  geom_text(aes(x = k + 0.25, label = lab), hjust = 0, size = 3.2, colour = "grey15") +
  facet_wrap(~ threshold, scales = "free", ncol = 3) +
  scale_colour_manual(values = role_cols, name = NULL) +
  scale_x_continuous(breaks = scales::breaks_width(2), expand = expansion(mult = c(0, 0.6))) + scale_y_continuous(breaks = NULL) +
  labs(title = "Longest streaks of consecutive elite seasons", subtitle = "Top 10 players at each threshold: number of straight seasons at or above the line",
       x = "Consecutive seasons", y = NULL, caption = CAP) + theme_war + theme(panel.grid.major.y = element_blank())
save_plot(p3, "03_longest_streaks_above_threshold.png", 15, 6)

# 4. Elite back-to-back seasons ----------------------------------------------------------------------------------------
pairs <- ws[["2"]] %>% mutate(w1 = as.numeric(sub(" /.*", "", war_seq)), w2 = as.numeric(sub(".*/ ", "", war_seq)))
elite <- pairs %>% filter(WAR_min >= 8)
lab_pairs <- elite %>% arrange(desc(WAR_sum)) %>% distinct(playerID, .keep_all = TRUE) %>% slice_head(n = 14) %>%
  mutate(lab = paste0(name, " ", start, dash, substr(end, 3, 4)))
p4 <- ggplot(pairs %>% filter(WAR_min >= 5), aes(w1, w2)) +
  geom_abline(linetype = 3, colour = "grey60") +
  geom_point(colour = "grey75", size = 1.4, alpha = 0.7) +
  geom_point(data = elite, aes(colour = role_label), size = 2.8) +
  geom_label_repel(data = lab_pairs, aes(label = lab, colour = role_label), size = 3, fill = alpha("white", 0.85),
                   label.size = 0, min.segment.length = 0, max.overlaps = Inf, seed = 4, show.legend = FALSE) +
  annotate("rect", xmin = 8, xmax = Inf, ymin = 8, ymax = Inf, fill = NA, colour = "grey40", linetype = 2) +
  scale_colour_manual(values = role_cols, name = NULL) + coord_equal() +
  labs(title = "When both seasons are elite", subtitle = "Every pair of consecutive seasons with both >= 5 WAR (grey); coloured = both >= 8 WAR (dashed box)",
       x = "WAR, first season", y = "WAR, second season", caption = CAP) + theme_war + theme(panel.grid.major.y = element_line(colour = "grey92"))
save_plot(p4, "04_elite_back_to_back_seasons.png", 11, 8.5)

# 5. Era-cutoff sensitivity ------------------------------------------------------------------------------------------------
es <- ao$era_sens %>% filter(k == 2) %>%
  mutate(panel = factor(paste0("Cutoff ", cutoff, ": ", side), levels = unlist(map(c(1901, 1920, 1947, 1969), ~ paste0("Cutoff ", .x, ": ", c(paste0("Pre-", .x), paste0(.x, "+")))))),
         lab = paste0(name, " ", start, dash, substr(end, 3, 4)))
p5 <- ggplot(es, aes(WAR_sum, reorder(paste(panel, lab), WAR_sum), fill = role_label)) + geom_col() +
  geom_text(aes(label = sprintf("%.1f", WAR_sum)), hjust = 1.1, colour = "white", size = 3) +
  facet_wrap(~ panel, scales = "free_y", ncol = 2) +
  scale_y_discrete(labels = function(x) sub("^.*?: [^ ]+ ", "", x)) +
  scale_fill_manual(values = role_cols, name = NULL) +
  labs(title = "Does the era cutoff change who's best?", subtitle = "Top 5 two-year stretches either side of four candidate 'modern era' cutoffs (a stretch must lie entirely within one side)",
       x = "WAR over two consecutive seasons", y = NULL, caption = CAP) + theme_war
save_plot(p5, "05_era_cutoff_sensitivity.png", 12, 11)

# 6. By position ----------------------------------------------------------------------------------------------------------------
pos5 <- ws[["5"]] %>% filter(!is.na(pos_group), pos_group != "Two-way") %>% group_by(pos_group) %>%
  group_modify(~ best_pp(.x) %>% slice_head(n = 3)) %>% ungroup() %>% mutate(lab = paste0(name, " ", start, dash, substr(end, 3, 4)))
pos5$pos_group <- factor(pos5$pos_group, c("C", "1B", "2B", "3B", "SS", "OF", "DH", "P"))
p6 <- ggplot(pos5, aes(WAR_sum, reorder(paste(pos_group, lab), WAR_sum), fill = pos_group)) + geom_col(show.legend = FALSE) +
  geom_text(aes(label = sprintf("%.1f", WAR_sum)), hjust = 1.1, colour = "white", size = 3.2) +
  facet_wrap(~ pos_group, scales = "free_y", ncol = 2) +
  scale_y_discrete(labels = function(x) sub("^[^ ]+ ", "", x)) + scale_fill_brewer(palette = "Dark2") +
  labs(title = "Best five-year stretch by position", subtitle = "Top 3 players at each position (position = where the player's best season in the stretch was played; P = pitchers)",
       x = "WAR over five consecutive seasons", y = NULL, caption = CAP) + theme_war
save_plot(p6, "06_best_5_year_by_position.png", 12, 10)

# 7. By decade ------------------------------------------------------------------------------------------------------------------------
dec3 <- ws[["3"]] %>% group_by(decade) %>% group_modify(~ best_pp(.x) %>% slice_head(n = 1)) %>% ungroup() %>%
  mutate(lab = paste0(name, "\n", start, dash, substr(end, 3, 4)), dnum = as.numeric(sub("s", "", decade))) %>% filter(dnum >= 1880)
p7 <- ggplot(dec3, aes(dnum, WAR_sum, fill = role_label)) + geom_col(width = 8) +
  geom_text(aes(label = lab), vjust = -0.3, size = 2.9, lineheight = 0.9) +
  scale_fill_manual(values = role_cols, name = NULL) + scale_x_continuous(breaks = seq(1880, 2020, 10), labels = function(x) paste0(x, "s")) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(title = "The best three-year stretch of each decade", subtitle = "Decade = year the stretch started", x = NULL, y = "WAR over three consecutive seasons", caption = CAP) +
  theme_war + theme(panel.grid.major.y = element_line(colour = "grey92"))
save_plot(p7, "07_best_3_year_by_decade.png", 13, 6.5)

# 8. Peak vs longevity ------------------------------------------------------------------------------------------------------------------------
plx <- pl %>% filter(career_WAR >= 50)
lab_pl <- bind_rows(plx %>% slice_max(career_WAR, n = 8),
                    plx %>% filter(career_type == "Peak-heavy (>=55% of WAR in best 5 yrs)") %>% slice_max(best5, n = 7),
                    plx %>% filter(career_type == "Longevity (<=35% of WAR in best 5 yrs)") %>% slice_max(career_WAR, n = 7),
                    plx %>% slice_max(best5, n = 5)) %>% distinct(playerID, .keep_all = TRUE)
p8 <- ggplot(plx, aes(career_WAR, best5, colour = career_type)) + geom_point(size = 2.2, alpha = 0.85) +
  geom_label_repel(data = lab_pl, aes(label = name), size = 3, fill = alpha("white", 0.8), label.size = 0, max.overlaps = Inf, seed = 8, min.segment.length = 0, show.legend = FALSE) +
  scale_colour_manual(values = c("Peak-heavy (>=55% of WAR in best 5 yrs)" = "#d95f02", "Balanced" = "grey60", "Longevity (<=35% of WAR in best 5 yrs)" = "#1b9e77"), name = NULL, na.value = "grey60") +
  labs(title = "Peak vs. longevity", subtitle = "Players with 50+ career WAR: best five-year stretch against career total",
       x = "Career WAR", y = "WAR in best five-year stretch", caption = CAP) + theme_war + theme(panel.grid.major.y = element_line(colour = "grey92"))
save_plot(p8, "08_peak_vs_longevity.png", 12, 8)

# 9. When do great stretches happen (age) ----------------------------------------------------------------------------------------------------------------
top_age <- map_dfr(c(2, 3, 5), function(k) best_pp(ws[[as.character(k)]]) %>% slice_head(n = 100) %>% mutate(len = paste0(k, "-year stretches")))
p9 <- ggplot(top_age, aes(age_start, fill = role_label)) + geom_histogram(binwidth = 1, colour = "white") + facet_wrap(~ len, ncol = 3) +
  scale_fill_manual(values = role_cols, name = NULL) + scale_x_continuous(breaks = seq(19, 40, 2)) +
  labs(title = "How old are players when the great stretches begin?", subtitle = "Age in the first season of each player's top-100 best stretches",
       x = "Age at start of stretch", y = "Players", caption = CAP) + theme_war + theme(panel.grid.major.y = element_line(colour = "grey92"))
save_plot(p9, "09_age_at_start_of_elite_stretches.png", 13, 5)

# 10. Franchises with the most elite three-year stretches (top-100 players) -----------------------------------------------------------------------------------------
fr <- best_pp(ws[["3"]]) %>% slice_head(n = 100) %>% filter(one_franchise) %>% count(franch_peak, sort = TRUE) %>% slice_head(n = 15)
p10 <- ggplot(fr, aes(n, reorder(franch_peak, n))) + geom_col(fill = "#2b6cb0") + geom_text(aes(label = n), hjust = -0.3) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.1))) +
  labs(title = "Where the great three-year stretches happened", subtitle = "Franchise (Lahman franchID) of the top-100 best three-year stretches, one-franchise stretches only",
       x = "Players among top-100", y = NULL, caption = CAP) + theme_war
save_plot(p10, "10_franchises_with_elite_3yr_stretches.png", 9, 6.5)

# 11. The crown: who holds the record for every stretch length --------------------------------------------------------------------------------------------------------------
cr <- crown %>% filter(rank == 1) %>% mutate(lab = paste0(name, "\n", start, dash, substr(end, 3, 4)))
p11 <- ggplot(crown %>% mutate(top = rank == 1), aes(k, WAR_sum)) +
  geom_line(data = cr, aes(group = 1), colour = "grey70", linewidth = 0.8) +
  geom_point(data = cr, aes(colour = name), size = 3.5) +
  geom_text(data = cr %>% group_by(name) %>% filter(k == min(k)) %>% ungroup(), aes(label = paste0(name, "\nfrom ", k, " yr")), vjust = -0.7, hjust = 0.5, size = 3, lineheight = 0.9) +
  scale_x_continuous(breaks = 1:20) + scale_colour_brewer(palette = "Dark2", guide = "none") +
  scale_y_continuous(expand = expansion(mult = c(0.02, 0.12))) +
  labs(title = "The crown changes hands as the window grows", subtitle = "Record WAR for any k consecutive seasons, and who holds it",
       x = "Window length (consecutive seasons)", y = "Record WAR", caption = CAP) + theme_war + theme(panel.grid.major.y = element_line(colour = "grey92"))
save_plot(p11, "11_crown_record_by_window_length.png", 13, 6.5)
message("Charts written to output/charts")
