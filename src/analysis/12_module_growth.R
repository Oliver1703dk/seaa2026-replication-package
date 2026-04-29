# 12_module_growth.R - Module (package) growth DiD analysis
# Input:  data/processed/panel_monthly.csv
# Output: data/interim/models/m_num_packages.rds, m_loc_per_package.rds
#
# Tests whether code growth reflects intra-module expansion (num_packages stable)
# or modular restructuring (num_packages grows). Supports the mechanism hypothesis
# in the Discussion section.

source(here::here("src/analysis/utils/helpers.R"))
suppressPackageStartupMessages({
  library(fixest)
  library(didimputation)
})

set.seed(SEED)
LOGFILE <- file.path(DIR_LOGS, "12_module_growth.log")
cat("", file = LOGFILE)

log_msg("=== 12: Module Growth Analysis ===", logfile = LOGFILE)

# --- Load data ---
panel <- load_panel()
panel_cc <- panel %>% filter(!is.na(asd), !is.na(num_packages), num_packages > 0)

# Add outcome variables
panel_cc <- panel_cc %>%
  mutate(
    log_num_packages = log(num_packages + 1),
    loc_per_package  = loc / num_packages,
    log_loc_per_pkg  = log(loc_per_package + 1)
  )

n_repos <- n_distinct(panel_cc$repo_int)
n_obs   <- nrow(panel_cc)
log_msg(sprintf("Data: %d obs, %d repos", n_obs, n_repos), logfile = LOGFILE)

# --- Helper: run Borusyak imputation with fallback (same as 08) ---
run_borusyak <- function(data, yname, label) {
  n_d <- nrow(data)
  n_r <- n_distinct(data$repo_int)
  tryCatch({
    m <- did_imputation(
      data        = data,
      yname       = yname,
      gname       = "first_treat_int",
      tname       = "month_id",
      idname      = "repo_int",
      first_stage = ~ 0 | repo_int + month_id,
      cluster_var = "repo_int"
    )
    r <- extract_did_imp(m)
    log_result(label, r$beta, r$se, r$ci_lo, r$ci_hi, r$pval, n_d, n_r)
    list(model = m, result = r, success = TRUE)
  }, error = function(e) {
    log_msg(sprintf("  %s error: %s. Trying minimal spec...", label, e$message),
            logfile = LOGFILE)
    tryCatch({
      m <- did_imputation(
        data   = data,
        yname  = yname,
        gname  = "first_treat_int",
        tname  = "month_id",
        idname = "repo_int"
      )
      r <- extract_did_imp(m)
      log_result(label, r$beta, r$se, r$ci_lo, r$ci_hi, r$pval, n_d, n_r)
      list(model = m, result = r, success = TRUE)
    }, error = function(e2) {
      log_msg(sprintf("  %s FAILED: %s", label, e2$message), logfile = LOGFILE)
      list(model = NULL, result = NULL, success = FALSE)
    })
  })
}

results <- list()

# =====================================================
# 1. DiD on num_packages (module count)
# =====================================================
log_msg("\n--- 1: Package Count Growth ---", logfile = LOGFILE)
log_msg("If packages stable + LOC grows -> intra-module expansion", logfile = LOGFILE)

res_pkg <- run_borusyak(panel_cc, "log_num_packages", "Module count ATT")
if (res_pkg$success) {
  saveRDS(res_pkg$model, file.path(DIR_MODELS, "m_num_packages.rds"))
  results$num_packages <- res_pkg$result
}

# =====================================================
# 2. DiD on LOC per package (package size)
# =====================================================
log_msg("\n--- 2: LOC per Package Growth ---", logfile = LOGFILE)
log_msg("If LOC/pkg grows -> packages get larger (intra-module expansion)", logfile = LOGFILE)

res_loc_pkg <- run_borusyak(panel_cc, "log_loc_per_pkg", "LOC per package ATT")
if (res_loc_pkg$success) {
  saveRDS(res_loc_pkg$model, file.path(DIR_MODELS, "m_loc_per_package.rds"))
  results$loc_per_package <- res_loc_pkg$result
}

# =====================================================
# Summary
# =====================================================
log_msg("\n=== MODULE GROWTH SUMMARY ===", logfile = LOGFILE)

if (!is.null(results$num_packages)) {
  r <- results$num_packages
  log_msg(sprintf("num_packages: beta=%.4f, effect=%.1f%%, p=%.4f",
                  r$beta, pct_effect(r$beta), r$pval), logfile = LOGFILE)
}

if (!is.null(results$loc_per_package)) {
  r <- results$loc_per_package
  log_msg(sprintf("LOC/package:  beta=%.4f, effect=%.1f%%, p=%.4f",
                  r$beta, pct_effect(r$beta), r$pval), logfile = LOGFILE)
}

log_msg("\nInterpretation:", logfile = LOGFILE)
log_msg("  If num_packages is stable: code growth is intra-module", logfile = LOGFILE)
log_msg("  If LOC/package grows: individual packages get larger", logfile = LOGFILE)
log_msg("  Together: supports the intra-module expansion mechanism", logfile = LOGFILE)

log_session("12_module_growth")
log_msg("\n=== 12: Complete ===", logfile = LOGFILE)
