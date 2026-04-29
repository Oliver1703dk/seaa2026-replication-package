# 02_main_did.R - Primary diff-in-diff estimation (RQ1)
# Input:  data/processed/panel_monthly.csv
# Output: data/interim/models/m_borusyak_static.rds, m_twfe_sa.rds

source(here::here("src/analysis/utils/helpers.R"))
suppressPackageStartupMessages({
  library(fixest)
  library(didimputation)
})

set.seed(SEED)
LOGFILE <- file.path(DIR_LOGS, "02_main_did.log")
cat("", file = LOGFILE)

log_msg("=== 02: Main DiD (RQ1) ===", logfile = LOGFILE)

# --- Load and prepare data ---
panel <- load_panel()
panel_cc <- panel %>% filter(!is.na(asd))

n_repos <- n_distinct(panel_cc$repo_int)
n_obs <- nrow(panel_cc)
n_cohorts <- n_distinct(panel_cc$first_treat_int[panel_cc$first_treat_int > 0])
log_msg(sprintf("Data: %d obs, %d repos, %d cohorts", n_obs, n_repos, n_cohorts),
        logfile = LOGFILE)

# --- Primary: Borusyak imputation ---
log_msg("\n--- Borusyak Imputation ---", logfile = LOGFILE)

m_static <- tryCatch({
  did_imputation(
    data       = panel_cc,
    yname      = "log_asd",
    gname      = "first_treat_int",
    tname      = "month_id",
    idname     = "repo_int",
    first_stage = ~ 0 | repo_int + month_id,
    cluster_var = "repo_int"
  )
}, error = function(e) {
  log_msg(sprintf("Borusyak error: %s", e$message), logfile = LOGFILE)
  log_msg("WARNING: Falling back to unclustered SEs. P-values may be anti-conservative.", logfile = LOGFILE)
  did_imputation(
    data   = panel_cc,
    yname  = "log_asd",
    gname  = "first_treat_int",
    tname  = "month_id",
    idname = "repo_int"
  )
})

saveRDS(m_static, file.path(DIR_MODELS, "m_borusyak_static.rds"))

# Extract and log results (did_imputation returns a tibble directly)
log_msg("Borusyak results:", logfile = LOGFILE)
print(m_static)

r_b <- extract_did_imp(m_static)
beta_b  <- r_b$beta
se_b    <- r_b$se
ci_lo_b <- r_b$ci_lo
ci_hi_b <- r_b$ci_hi
pval_b  <- r_b$pval

log_result("RQ1 Borusyak ATT", beta_b, se_b, ci_lo_b, ci_hi_b, pval_b, n_obs, n_repos)

# --- Secondary: TWFE with Sun & Abraham ---
log_msg("\n--- TWFE Sun & Abraham ---", logfile = LOGFILE)

m_twfe <- feols(
  log_asd ~ sunab(first_treat_sa, month_id) | repo_int + month_id,
  data = panel_cc,
  vcov = ~repo_int
)

saveRDS(m_twfe, file.path(DIR_MODELS, "m_twfe_sa.rds"))

# Extract aggregate ATT from sunab
s_twfe <- summary(m_twfe, agg = "att")
log_msg("TWFE-SA results:", logfile = LOGFILE)
print(s_twfe)

beta_t <- coeftable(s_twfe)[1, 1]
se_t   <- coeftable(s_twfe)[1, 2]
ci_lo_t <- beta_t - qnorm(0.975) * se_t
ci_hi_t <- beta_t + qnorm(0.975) * se_t
pval_t  <- coeftable(s_twfe)[1, 4]

log_result("RQ1 TWFE-SA ATT", beta_t, se_t, ci_lo_t, ci_hi_t, pval_t, n_obs, n_repos)

# --- Concordance check ---
log_msg(sprintf("\nConcordance: Borusyak=%.4f, TWFE-SA=%.4f, same sign=%s",
                beta_b, beta_t, ifelse(sign(beta_b) == sign(beta_t), "YES", "NO")),
        logfile = LOGFILE)

# --- Sensitivity: with time-varying covariate ---
log_msg("\n--- Covariate Sensitivity (monthly_contributors) ---", logfile = LOGFILE)
m_cov <- feols(
  log_asd ~ sunab(first_treat_sa, month_id) + monthly_contributors
    | repo_int + month_id,
  data = panel_cc, vcov = ~repo_int
)
saveRDS(m_cov, file.path(DIR_MODELS, "m_twfe_sa_cov.rds"))
s_cov <- summary(m_cov, agg = "att")
log_msg("TWFE-SA with covariates:", logfile = LOGFILE)
print(s_cov)
ct_cov <- coeftable(s_cov)
log_result("RQ1 TWFE-SA+cov ATT", ct_cov[1,1], ct_cov[1,2],
           ct_cov[1,1] - qnorm(0.975)*ct_cov[1,2],
           ct_cov[1,1] + qnorm(0.975)*ct_cov[1,2],
           ct_cov[1,4], n_obs, n_repos)

log_session("02_main_did")
log_msg("\n=== 02: Complete ===", logfile = LOGFILE)
