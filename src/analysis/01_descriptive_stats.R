# 01_descriptive_stats.R - Sample description, distributions, attrition analysis
# Input:  data/processed/panel_monthly.csv
# Output: results/tables/tab_descriptive.tex, results/figures/fig_distributions.pdf,
#         data/interim/models/descriptive_objects.rds

source(here::here("src/analysis/utils/helpers.R"))
suppressPackageStartupMessages({
  library(kableExtra)
  library(patchwork)
})

set.seed(SEED)
LOGFILE <- file.path(DIR_LOGS, "01_descriptive_stats.log")
cat("", file = LOGFILE)  # clear
cat("", file = SUMMARY_FILE)  # clear summary for fresh run

log_msg("=== 01: Descriptive Statistics ===", logfile = LOGFILE)

# --- Load data ---
panel <- load_panel()
panel_cc <- panel %>% filter(!is.na(asd))

log_msg(sprintf("Full panel: %d rows, %d repos", nrow(panel), n_distinct(panel$repo_name)),
        logfile = LOGFILE)
log_msg(sprintf("Complete-case: %d rows, %d repos", nrow(panel_cc), n_distinct(panel_cc$repo_name)),
        logfile = LOGFILE)
log_msg(sprintf("Missing ASD: %d rows (%.1f%%)",
                sum(is.na(panel$asd)), 100 * mean(is.na(panel$asd))),
        logfile = LOGFILE)

# --- Attrition analysis ---
repo_coverage <- panel %>%
  group_by(repo_name, is_treatment) %>%
  summarise(
    n_months = n(),
    n_valid = sum(!is.na(asd)),
    pct_valid = mean(!is.na(asd)),
    .groups = "drop"
  )

all_missing <- repo_coverage %>% filter(n_valid == 0)
log_msg(sprintf("\nAll-missing repos: %d total (%d treatment, %d control)",
                nrow(all_missing),
                sum(all_missing$is_treatment == 1),
                sum(all_missing$is_treatment == 0)),
        logfile = LOGFILE)

# Attrition rates by group
treat_n <- n_distinct(panel$repo_name[panel$is_treatment == 1])
ctrl_n  <- n_distinct(panel$repo_name[panel$is_treatment == 0])
treat_missing <- sum(all_missing$is_treatment == 1)
ctrl_missing  <- sum(all_missing$is_treatment == 0)
log_msg(sprintf("Attrition rate: treatment=%.1f%% (%d/%d), control=%.1f%% (%d/%d)",
                100 * treat_missing / treat_n, treat_missing, treat_n,
                100 * ctrl_missing / ctrl_n, ctrl_missing, ctrl_n),
        logfile = LOGFILE)

# Compare dropped vs retained repos on covariates
repo_chars <- panel %>%
  group_by(repo_name, is_treatment) %>%
  summarise(
    mean_kloc = mean(kloc, na.rm = TRUE),
    stars = first(stars),
    repo_age = first(repo_age_months),
    mean_commits = mean(monthly_commits, na.rm = TRUE),
    has_data = any(!is.na(asd)),
    .groups = "drop"
  )

log_msg("\nDropped vs Retained repo comparison:", logfile = LOGFILE)
for (v in c("mean_kloc", "stars", "repo_age", "mean_commits")) {
  dropped <- repo_chars %>% filter(!has_data) %>% pull(!!sym(v))
  retained <- repo_chars %>% filter(has_data) %>% pull(!!sym(v))
  # Remove NaN/NA values before t.test
  dropped <- dropped[!is.na(dropped) & !is.nan(dropped)]
  retained <- retained[!is.na(retained) & !is.nan(retained)]
  if (length(dropped) >= 2 && length(retained) >= 2) {
    tt <- t.test(dropped, retained)
    log_msg(sprintf("  %s: dropped mean=%.1f, retained mean=%.1f, p=%.3f",
                    v, mean(dropped), mean(retained), tt$p.value),
            logfile = LOGFILE)
  } else {
    log_msg(sprintf("  %s: insufficient non-NA observations (dropped=%d, retained=%d) - skipped",
                    v, length(dropped), length(retained)),
            logfile = LOGFILE)
  }
}

# --- Size grouping ---
repo_median_kloc <- panel_cc %>%
  group_by(repo_int) %>%
  summarise(repo_kloc = median(kloc, na.rm = TRUE), .groups = "drop")
overall_median_kloc <- median(repo_median_kloc$repo_kloc)
log_msg(sprintf("\nMedian repo KLOC: %.1f", overall_median_kloc), logfile = LOGFILE)

# --- Descriptive table ---
desc_vars <- c("kloc", "asd", "total_smells", "cd_count", "ud_count", "hl_count", "gc_count",
               "monthly_commits", "monthly_contributors", "stars", "repo_age_months")

make_desc_row <- function(data, var) {
  x <- data[[var]]
  x <- x[!is.na(x)]
  tibble(
    Variable = var,
    N = length(x),
    Mean = mean(x),
    SD = sd(x),
    Median = median(x),
    Min = min(x),
    Max = max(x)
  )
}

desc_treat <- map_dfr(desc_vars, ~make_desc_row(filter(panel_cc, is_treatment == 1), .x)) %>%
  mutate(Group = "Treatment")
desc_ctrl <- map_dfr(desc_vars, ~make_desc_row(filter(panel_cc, is_treatment == 0), .x)) %>%
  mutate(Group = "Control")

desc_all <- bind_rows(desc_treat, desc_ctrl)

# Format for LaTeX
desc_wide <- desc_all %>%
  mutate(summary = sprintf("%.1f (%.1f)", Mean, SD)) %>%
  select(Variable, Group, summary) %>%
  pivot_wider(names_from = Group, values_from = summary)

# Variable labels
var_labels <- c(
  kloc = "KLOC", asd = "ASD (smells/KLOC)", total_smells = "Total smells",
  cd_count = "Cyclic dep.", ud_count = "Unstable dep.",
  hl_count = "Hub-like dep.", gc_count = "God component",
  monthly_commits = "Commits/month", monthly_contributors = "Contributors/month",
  stars = "GitHub stars", repo_age_months = "Repo age (months)"
)
desc_wide <- desc_wide %>%
  mutate(Variable = var_labels[Variable])

# Add sample sizes as header row
n_treat_repos <- n_distinct(panel_cc$repo_name[panel_cc$is_treatment == 1])
n_ctrl_repos  <- n_distinct(panel_cc$repo_name[panel_cc$is_treatment == 0])

tab_tex <- desc_wide %>%
  kable(format = "latex", booktabs = TRUE, align = c("l", "r", "r"),
        col.names = c("", sprintf("Treatment (n=%d)", n_treat_repos),
                       sprintf("Control (n=%d)", n_ctrl_repos)),
        caption = "Descriptive statistics for treatment and control groups (complete-case observations). Values shown as mean (SD).",
        label = "descriptive") %>%
  kable_styling(latex_options = "hold_position")

writeLines(tab_tex, file.path(DIR_TABLES, "tab_descriptive.tex"))
log_msg("Saved: tab_descriptive.tex", logfile = LOGFILE)

# --- Distribution figure ---
p_density <- panel_cc %>%
  filter(post == 0) %>%
  mutate(Group = ifelse(is_treatment == 1, "Treatment", "Control")) %>%
  ggplot(aes(x = log_asd, fill = Group, color = Group)) +
  geom_density(alpha = 0.3) +
  scale_fill_manual(values = c("Treatment" = "#2166AC", "Control" = "#B2182B")) +
  scale_color_manual(values = c("Treatment" = "#2166AC", "Control" = "#B2182B")) +
  labs(x = "log(ASD + 1)", y = "Density",
       title = "A) Pre-adoption ASD distribution") +
  theme_paper()

p_box <- panel_cc %>%
  mutate(
    Group = ifelse(is_treatment == 1, "Treatment", "Control"),
    Period = ifelse(post == 1, "Post", "Pre")
  ) %>%
  ggplot(aes(x = interaction(Period, Group), y = asd, fill = Group)) +
  geom_boxplot(outlier.size = 0.5) +
  scale_fill_manual(values = c("Treatment" = "#2166AC", "Control" = "#B2182B")) +
  scale_x_discrete(labels = c("Pre.Control" = "Control\nPre", "Post.Control" = "Control\nPost",
                               "Pre.Treatment" = "Treatment\nPre", "Post.Treatment" = "Treatment\nPost")) +
  coord_cartesian(ylim = c(0, quantile(panel_cc$asd, 0.95, na.rm = TRUE))) +
  labs(x = NULL, y = "ASD (smells/KLOC)", title = "B) ASD by group and period") +
  theme_paper() +
  theme(legend.position = "none")

p_combined <- p_density / p_box + plot_layout(heights = c(1, 1))
save_fig(p_combined, "fig_distributions.pdf", w = 7, h = 8)
log_msg("Saved: fig_distributions.pdf", logfile = LOGFILE)

# =====================================================
# B.6: ICC computation
# =====================================================
log_msg("\n--- ICC for log_asd ---", logfile = LOGFILE)
tryCatch({
  suppressPackageStartupMessages(library(lme4))
  m_icc <- lmer(log_asd ~ 1 + (1 | repo_int), data = panel_cc)
  icc_val <- as.data.frame(VarCorr(m_icc))
  icc <- icc_val$vcov[1] / sum(icc_val$vcov)
  log_msg(sprintf("ICC for log_asd: %.4f", icc), logfile = LOGFILE)
  cat(sprintf("ICC log_asd: %.4f\n", icc), file = SUMMARY_FILE, append = TRUE)
  log_msg(sprintf("  Interpretation: %.1f%% of variance is between-repo", 100 * icc),
          logfile = LOGFILE)
}, error = function(e) {
  log_msg(sprintf("ICC error: %s", e$message), logfile = LOGFILE)
})

# =====================================================
# B.8: 2x2 Pre/Post Mean Table
# =====================================================
log_msg("\n--- 2x2 Pre/Post Mean Table ---", logfile = LOGFILE)

# For controls, define "post" relative to median treatment adoption time
median_treat_time <- median(panel_cc$first_treat_int[panel_cc$is_treatment == 1 & panel_cc$first_treat_int > 0])

means_2x2 <- panel_cc %>%
  mutate(
    period = case_when(
      is_treatment == 1 & month_id >= first_treat_int ~ "Post",
      is_treatment == 1 & month_id < first_treat_int ~ "Pre",
      is_treatment == 0 & month_id >= median_treat_time ~ "Post",
      TRUE ~ "Pre"
    ),
    group = ifelse(is_treatment == 1, "Treatment", "Control")
  ) %>%
  group_by(group, period) %>%
  summarise(
    mean_asd = mean(asd, na.rm = TRUE),
    mean_log_asd = mean(log_asd, na.rm = TRUE),
    n = n(),
    .groups = "drop"
  )

log_msg("2x2 Pre/Post means:", logfile = LOGFILE)
for (i in seq_len(nrow(means_2x2))) {
  row <- means_2x2[i, ]
  log_msg(sprintf("  %s-%s: ASD=%.2f, log_ASD=%.4f (n=%d)",
                  row$group, row$period, row$mean_asd, row$mean_log_asd, row$n),
          logfile = LOGFILE)
}

# Naive DiD from group means
treat_pre  <- means_2x2 %>% filter(group == "Treatment", period == "Pre") %>% pull(mean_log_asd)
treat_post <- means_2x2 %>% filter(group == "Treatment", period == "Post") %>% pull(mean_log_asd)
ctrl_pre   <- means_2x2 %>% filter(group == "Control", period == "Pre") %>% pull(mean_log_asd)
ctrl_post  <- means_2x2 %>% filter(group == "Control", period == "Post") %>% pull(mean_log_asd)

if (length(treat_pre) > 0 && length(ctrl_pre) > 0) {
  naive_did <- (treat_post - treat_pre) - (ctrl_post - ctrl_pre)
  log_msg(sprintf("  Naive DiD from means: %.4f (%.1f%%)",
                  naive_did, pct_effect(naive_did)), logfile = LOGFILE)
  cat(sprintf("Naive DiD from 2x2 means: %.4f (%.1f%%)\n",
              naive_did, pct_effect(naive_did)),
      file = SUMMARY_FILE, append = TRUE)
}

# =====================================================
# B.9: Attrition Characterization Table
# =====================================================
log_msg("\n--- Attrition Characterization Table ---", logfile = LOGFILE)

# Load matching data for all 180 repos
matching_path <- here("data/processed/matching.csv")
char_path <- here("data/processed/repo_characteristics.csv")

if (file.exists(matching_path) && file.exists(char_path)) {
  matching <- read_csv(matching_path, show_col_types = FALSE)
  characteristics <- read_csv(char_path, show_col_types = FALSE)

  # All repos in the study
  all_repos <- bind_rows(
    tibble(repo_name = matching$treatment_repo, group = "Treatment"),
    tibble(repo_name = matching$control_repo, group = "Control")
  )

  # Which appear in panel_cc?
  retained_repos <- unique(panel_cc$repo_name)
  all_repos <- all_repos %>%
    mutate(status = ifelse(repo_name %in% retained_repos, "Retained", "Dropped"))

  # Merge with characteristics
  all_repos <- all_repos %>%
    left_join(characteristics %>% select(repo_name = full_name, stars, size_kb,
                                          num_commits, num_contributors, repo_age_months),
              by = "repo_name")

  # Summary by group x status
  attrition_summary <- all_repos %>%
    group_by(group, status) %>%
    summarise(
      n = n(),
      mean_stars = mean(stars, na.rm = TRUE),
      mean_size_kb = mean(size_kb, na.rm = TRUE),
      mean_commits = mean(num_commits, na.rm = TRUE),
      mean_contributors = mean(num_contributors, na.rm = TRUE),
      mean_age = mean(repo_age_months, na.rm = TRUE),
      .groups = "drop"
    )

  log_msg("Attrition characterization:", logfile = LOGFILE)
  for (i in seq_len(nrow(attrition_summary))) {
    row <- attrition_summary[i, ]
    log_msg(sprintf("  %s %s (n=%d): stars=%.0f, size_kb=%.0f, commits=%.0f, contributors=%.0f, age=%.0f",
                    row$group, row$status, row$n,
                    row$mean_stars, row$mean_size_kb, row$mean_commits,
                    row$mean_contributors, row$mean_age),
            logfile = LOGFILE)
  }

  # Generate LaTeX table
  attrition_tex <- attrition_summary %>%
    mutate(across(starts_with("mean_"), ~sprintf("%.0f", .))) %>%
    kable(format = "latex", booktabs = TRUE,
          col.names = c("Group", "Status", "N", "Stars", "Size (KB)",
                        "Commits", "Contributors", "Age (mo)"),
          caption = "Characteristics of retained vs.\\ dropped repositories.",
          label = "attrition") %>%
    kable_styling(latex_options = "hold_position")
  writeLines(attrition_tex, file.path(DIR_TABLES, "tab_attrition.tex"))
  log_msg("Saved: tab_attrition.tex", logfile = LOGFILE)
} else {
  log_msg("  Matching/characteristics files not found - skipping attrition table", logfile = LOGFILE)
}

# --- Save objects for downstream scripts ---
saveRDS(
  list(median_kloc = overall_median_kloc, repo_median_kloc = repo_median_kloc),
  file.path(DIR_MODELS, "descriptive_objects.rds")
)

log_session("01_descriptive_stats")
log_msg("\n=== 01: Complete ===", logfile = LOGFILE)
