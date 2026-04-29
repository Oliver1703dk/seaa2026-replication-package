# 03_disaggregated_did.R - Per-smell-type DiD (RQ2)
# Input:  data/processed/panel_monthly.csv
# Output: data/interim/models/m_disagg_{cd,ud,hl,gc}.rds

source(here::here("src/analysis/utils/helpers.R"))
suppressPackageStartupMessages({
  library(didimputation)
})

set.seed(SEED)
LOGFILE <- file.path(DIR_LOGS, "03_disaggregated_did.log")
cat("", file = LOGFILE)

log_msg("=== 03: Disaggregated DiD (RQ2) ===", logfile = LOGFILE)

# --- Load data ---
panel <- load_panel()
panel_cc <- panel %>% filter(!is.na(asd))

n_repos <- n_distinct(panel_cc$repo_int)
n_obs <- nrow(panel_cc)

# --- Per-smell-type estimates ---
outcomes <- list(
  cd = list(var = "log_cd", label = "Cyclic Dependency"),
  ud = list(var = "log_ud", label = "Unstable Dependency"),
  hl = list(var = "log_hl", label = "Hub-Like Dependency"),
  gc = list(var = "log_gc", label = "God Component")
)

# Note zero-inflation
gc_zero_pct <- 100 * mean(panel_cc$gc_density == 0, na.rm = TRUE)
log_msg(sprintf("GC zero-inflation: %.1f%%", gc_zero_pct), logfile = LOGFILE)

for (name in names(outcomes)) {
  oc <- outcomes[[name]]
  log_msg(sprintf("\n--- %s (%s) ---", oc$label, oc$var), logfile = LOGFILE)

  m <- tryCatch({
    did_imputation(
      data       = panel_cc,
      yname      = oc$var,
      gname      = "first_treat_int",
      tname      = "month_id",
      idname     = "repo_int",
      first_stage = ~ 0 | repo_int + month_id,
      cluster_var = "repo_int"
    )
  }, error = function(e) {
    log_msg(sprintf("  Error: %s. Trying minimal spec...", e$message), logfile = LOGFILE)
    did_imputation(
      data   = panel_cc,
      yname  = oc$var,
      gname  = "first_treat_int",
      tname  = "month_id",
      idname = "repo_int"
    )
  })

  saveRDS(m, file.path(DIR_MODELS, sprintf("m_disagg_%s.rds", name)))

  r <- extract_did_imp(m)

  log_result(sprintf("RQ2 %s ATT", oc$label), r$beta, r$se, r$ci_lo, r$ci_hi, r$pval, n_obs, n_repos)

  if (name == "gc") {
    log_msg("  Note: GC results have low power due to 77.5% zero-inflation", logfile = LOGFILE)
  }
}

# --- Holm correction for multiple testing ---
log_msg("\n--- Holm Correction ---", logfile = LOGFILE)
raw_pvals <- c()
smell_labels <- c()
for (name in names(outcomes)) {
  fpath <- file.path(DIR_MODELS, sprintf("m_disagg_%s.rds", name))
  if (file.exists(fpath)) {
    m <- readRDS(fpath)
    r <- extract_did_imp(m)
    raw_pvals <- c(raw_pvals, r$pval)
    smell_labels <- c(smell_labels, toupper(name))
  }
}
holm_pvals <- p.adjust(raw_pvals, method = "holm")
names(holm_pvals) <- smell_labels
log_msg("Raw vs Holm-adjusted p-values:", logfile = LOGFILE)
for (i in seq_along(raw_pvals)) {
  log_msg(sprintf("  %s: raw p=%.4f, Holm-adjusted p=%.4f %s",
                  smell_labels[i], raw_pvals[i], holm_pvals[i],
                  ifelse(holm_pvals[i] < ALPHA, "(survives)", "(not significant)")),
          logfile = LOGFILE)
}
cat(sprintf("Holm-adjusted p-values: %s\n",
            paste(sprintf("%s=%.4f", smell_labels, holm_pvals), collapse=", ")),
    file = SUMMARY_FILE, append = TRUE)

log_session("03_disaggregated_did")
log_msg("\n=== 03: Complete ===", logfile = LOGFILE)
