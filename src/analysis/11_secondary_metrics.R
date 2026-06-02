# 11_secondary_metrics.R - DiD on secondary graph metrics (Ce, Instability, Distance)
# Input:  data/processed/panel_monthly.csv
# Output: data/interim/models/m_secondary_*.rds
#
# B.4: ECSA reviewers familiar with Arcan will expect coupling metric analysis.
# Tests whether AI adoption changes coupling profiles (Ce, Instability, Distance).

source(here::here("src/analysis/utils/helpers.R"))
suppressPackageStartupMessages({
  library(fixest)
  library(didimputation)
})

set.seed(SEED)
LOGFILE <- file.path(DIR_LOGS, "11_secondary_metrics.log")
cat("", file = LOGFILE)

log_msg("=== 11: Secondary Graph Metrics ===", logfile = LOGFILE)

# --- Load data ---
panel <- load_panel()
panel_cc <- panel %>% filter(!is.na(asd))

n_repos <- n_distinct(panel_cc$repo_int)
n_obs <- nrow(panel_cc)

# --- DiD on secondary metrics ---
metrics <- c("ce_mean", "instability_mean", "distance_mean")

for (metric in metrics) {
  log_msg(sprintf("\n--- %s ---", metric), logfile = LOGFILE)

  # Filter to non-missing observations for this metric
  panel_m <- panel_cc %>% filter(!is.na(.data[[metric]]))
  n_valid <- nrow(panel_m)
  n_repos_m <- n_distinct(panel_m$repo_int)
  log_msg(sprintf("  Non-missing: %d obs, %d repos", n_valid, n_repos_m), logfile = LOGFILE)

  if (n_valid < 100 || n_repos_m < 20) {
    log_msg(sprintf("  Insufficient data for %s - skipping", metric), logfile = LOGFILE)
    next
  }

  # Log-transform
  log_var <- paste0("log_", metric)
  panel_m[[log_var]] <- log(panel_m[[metric]] + 1)

  # Descriptive stats
  log_msg(sprintf("  Mean: %.4f, SD: %.4f, Median: %.4f",
                  mean(panel_m[[metric]], na.rm = TRUE),
                  sd(panel_m[[metric]], na.rm = TRUE),
                  median(panel_m[[metric]], na.rm = TRUE)),
          logfile = LOGFILE)

  # Borusyak imputation
  m <- tryCatch({
    did_imputation(
      data        = panel_m,
      yname       = log_var,
      gname       = "first_treat_int",
      tname       = "month_id",
      idname      = "repo_int",
      first_stage = ~ 0 | repo_int + month_id,
      cluster_var = "repo_int"
    )
  }, error = function(e) {
    log_msg(sprintf("  Borusyak error for %s: %s. Trying minimal...", metric, e$message),
            logfile = LOGFILE)
    tryCatch(
      did_imputation(
        data   = panel_m,
        yname  = log_var,
        gname  = "first_treat_int",
        tname  = "month_id",
        idname = "repo_int"
      ),
      error = function(e2) {
        log_msg(sprintf("  %s FAILED: %s", metric, e2$message), logfile = LOGFILE)
        NULL
      }
    )
  })

  if (!is.null(m)) {
    saveRDS(m, file.path(DIR_MODELS, sprintf("m_secondary_%s.rds", metric)))
    r <- extract_did_imp(m)
    log_result(sprintf("Secondary %s ATT", metric), r$beta, r$se,
               r$ci_lo, r$ci_hi, r$pval, n_valid, n_repos_m)
  }
}

# --- Also run DiD on ca_mean if available ---
if ("ca_mean" %in% names(panel_cc)) {
  log_msg("\n--- ca_mean ---", logfile = LOGFILE)
  panel_ca <- panel_cc %>% filter(!is.na(ca_mean))
  if (nrow(panel_ca) >= 100) {
    panel_ca$log_ca_mean <- log(panel_ca$ca_mean + 1)
    m_ca <- tryCatch({
      did_imputation(
        data = panel_ca, yname = "log_ca_mean",
        gname = "first_treat_int", tname = "month_id", idname = "repo_int",
        first_stage = ~ 0 | repo_int + month_id, cluster_var = "repo_int"
      )
    }, error = function(e) { NULL })
    if (!is.null(m_ca)) {
      saveRDS(m_ca, file.path(DIR_MODELS, "m_secondary_ca_mean.rds"))
      r <- extract_did_imp(m_ca)
      log_result("Secondary ca_mean ATT", r$beta, r$se,
                 r$ci_lo, r$ci_hi, r$pval, nrow(panel_ca), n_distinct(panel_ca$repo_int))
    }
  }
}

log_msg("\n=== 11: Complete ===", logfile = LOGFILE)
