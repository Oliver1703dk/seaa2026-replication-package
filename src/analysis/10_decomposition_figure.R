# 09_decomposition_figure.R - Two-panel decomposition figure (ASD + LOC event studies)
# Input:  data/interim/models/m_es_borusyak.rds, data/interim/models/m_supp_loc_es.rds
# Output: results/figures/fig_decomposition_panels.pdf

source(here::here("src/analysis/utils/helpers.R"))
suppressPackageStartupMessages({
  library(fixest)
  library(didimputation)
  library(patchwork)
})

set.seed(SEED)
LOGFILE <- file.path(DIR_LOGS, "09_decomposition_figure.log")
cat("", file = LOGFILE)

log_msg("=== 09: Decomposition Two-Panel Figure ===", logfile = LOGFILE)

# Colors
COL_ASD <- "#2166AC"  # blue
COL_LOC <- "#E66101"  # orange

# --- Load event study models ---
m_asd_es <- readRDS(file.path(DIR_MODELS, "m_es_borusyak.rds"))
m_loc_es <- readRDS(file.path(DIR_MODELS, "m_supp_loc_es.rds"))

log_msg(sprintf("ASD ES: %d time points", nrow(m_asd_es)), logfile = LOGFILE)
log_msg(sprintf("LOC ES: %d time points", nrow(m_loc_es)), logfile = LOGFILE)

# --- Panel A: ASD event study ---
asd_df <- m_asd_es %>%
  mutate(
    h = as.integer(term),
    effect_pct = pct_effect(estimate),
    ci_lo_pct = pct_effect(conf.low),
    ci_hi_pct = pct_effect(conf.high)
  ) %>%
  arrange(h)

p_asd <- ggplot(asd_df, aes(x = h, y = effect_pct)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
  geom_vline(xintercept = -0.5, linetype = "dotted", color = "gray40", alpha = 0.7) +
  geom_ribbon(aes(ymin = ci_lo_pct, ymax = ci_hi_pct), alpha = 0.15, fill = COL_ASD) +
  geom_line(color = COL_ASD, linewidth = 0.8) +
  geom_point(color = COL_ASD, size = 2) +
  scale_x_continuous(breaks = seq(-6, 6)) +
  labs(x = NULL, y = "Effect (%)",
       title = "(a) Architectural Smell Density") +
  theme_paper(base_size = 10)

# --- Panel B: LOC event study ---
loc_df <- m_loc_es %>%
  mutate(
    h = as.integer(term),
    effect_pct = pct_effect(estimate),
    ci_lo_pct = pct_effect(conf.low),
    ci_hi_pct = pct_effect(conf.high)
  ) %>%
  arrange(h)

p_loc <- ggplot(loc_df, aes(x = h, y = effect_pct)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
  geom_vline(xintercept = -0.5, linetype = "dotted", color = "gray40", alpha = 0.7) +
  geom_ribbon(aes(ymin = ci_lo_pct, ymax = ci_hi_pct), alpha = 0.15, fill = COL_LOC) +
  geom_line(color = COL_LOC, linewidth = 0.8) +
  geom_point(color = COL_LOC, size = 2) +
  scale_x_continuous(breaks = seq(-6, 6)) +
  labs(x = "Months Relative to AI Tool Adoption", y = "Effect (%)",
       title = "(b) Lines of Code (KLOC)") +
  theme_paper(base_size = 10)

# --- Combine ---
p_combined <- p_asd / p_loc +
  plot_layout(ncol = 1, heights = c(1, 1))

save_fig(p_combined, "fig_decomposition_panels.pdf", w = 7, h = 6)
log_msg("Saved: fig_decomposition_panels.pdf", logfile = LOGFILE)
log_msg("=== 09: Complete ===", logfile = LOGFILE)
