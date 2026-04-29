# 10_container_only_sensitivity.R - Container-only (package-level) smell sensitivity
# Input:  data/processed/panel_monthly_container_only.csv
# Output: results/logs/10_container_only.log

source(here::here("src/analysis/utils/helpers.R"))
suppressPackageStartupMessages({
  library(fixest)
  library(didimputation)
})

set.seed(SEED)
LOGFILE <- file.path(DIR_LOGS, "10_container_only.log")
cat("", file = LOGFILE)

log_msg("=== 10: Container-Only Sensitivity Analysis ===", logfile = LOGFILE)

# --- Load container-only panel ---
panel_co <- read_csv(
  here("data/processed/panel_monthly_container_only.csv"),
  show_col_types = FALSE
)

panel_co <- panel_co %>%
  select(-any_of("modularity_q")) %>%
  arrange(repo_name, month) %>%
  mutate(
    log_asd = log(asd + 1),
    log_cd  = log(cd_density + 1),
    log_ud  = log(ud_density + 1),
    log_hl  = log(hl_density + 1),
    log_gc  = log(gc_density + 1),
    repo_int = as.integer(factor(repo_name)),
    first_treat_int = ifelse(
      is_treatment == 0, 0L,
      month_str_to_id(first_treat_month)
    ),
    first_treat_sa = ifelse(
      is_treatment == 0, 100000L,
      month_str_to_id(first_treat_month)
    ),
    log_kloc = log(kloc + 1),
    log_total_smells = log(total_smells + 1)
  )

panel_cc <- panel_co %>% filter(!is.na(asd))
n_repos <- n_distinct(panel_cc$repo_int)
n_obs <- nrow(panel_cc)
log_msg(sprintf("Container-only data: %d obs, %d repos", n_obs, n_repos), logfile = LOGFILE)

# --- Compare descriptive stats ---
log_msg("\n--- Descriptive Stats (Container-Only) ---", logfile = LOGFILE)
log_msg(sprintf("ASD mean: %.3f  (original was ~5.6)", mean(panel_cc$asd, na.rm=TRUE)), logfile = LOGFILE)
log_msg(sprintf("Total smells mean: %.1f  (original was ~275)", mean(panel_cc$total_smells, na.rm=TRUE)), logfile = LOGFILE)
log_msg(sprintf("CD mean: %.1f", mean(panel_cc$cd_count, na.rm=TRUE)), logfile = LOGFILE)
log_msg(sprintf("HL mean: %.1f", mean(panel_cc$hl_count, na.rm=TRUE)), logfile = LOGFILE)
log_msg(sprintf("UD mean: %.1f  (should be same - always CONTAINER)", mean(panel_cc$ud_count, na.rm=TRUE)), logfile = LOGFILE)
log_msg(sprintf("GC mean: %.1f  (should be same - always CONTAINER)", mean(panel_cc$gc_count, na.rm=TRUE)), logfile = LOGFILE)

# ============================================================
# 1. PRIMARY: Borusyak imputation on container-only ASD
# ============================================================
log_msg("\n--- 1. Borusyak: Container-Only ASD ---", logfile = LOGFILE)

m_co_static <- tryCatch({
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
  did_imputation(
    data   = panel_cc,
    yname  = "log_asd",
    gname  = "first_treat_int",
    tname  = "month_id",
    idname = "repo_int"
  )
})

r <- extract_did_imp(m_co_static)
log_result("Container-Only ASD (Borusyak)", r$beta, r$se, r$ci_lo, r$ci_hi, r$pval, n_obs, n_repos)

# ============================================================
# 2. TWFE-SA on container-only ASD
# ============================================================
log_msg("\n--- 2. TWFE-SA: Container-Only ASD ---", logfile = LOGFILE)

m_co_twfe <- feols(
  log_asd ~ sunab(first_treat_sa, month_id) | repo_int + month_id,
  data = panel_cc,
  vcov = ~repo_int
)

s_twfe <- summary(m_co_twfe, agg = "att")
beta_tw <- s_twfe$coefficients[1]
se_tw   <- s_twfe$se[1]
pval_tw <- s_twfe$coeftable[1, "Pr(>|t|)"]
ci_tw   <- beta_tw + c(-1, 1) * qnorm(0.975) * se_tw
log_result("Container-Only ASD (TWFE-SA)", beta_tw, se_tw, ci_tw[1], ci_tw[2], pval_tw, n_obs, n_repos)

# ============================================================
# 3. Decomposition: raw smells vs LOC
# ============================================================
log_msg("\n--- 3. Decomposition: Container-Only ---", logfile = LOGFILE)

# Raw smell count
m_co_smells <- tryCatch({
  did_imputation(
    data       = panel_cc,
    yname      = "log_total_smells",
    gname      = "first_treat_int",
    tname      = "month_id",
    idname     = "repo_int",
    first_stage = ~ 0 | repo_int + month_id,
    cluster_var = "repo_int"
  )
}, error = function(e) {
  did_imputation(
    data   = panel_cc,
    yname  = "log_total_smells",
    gname  = "first_treat_int",
    tname  = "month_id",
    idname = "repo_int"
  )
})

r_s <- extract_did_imp(m_co_smells)
log_result("Container-Only Raw Smells (Borusyak)", r_s$beta, r_s$se, r_s$ci_lo, r_s$ci_hi, r_s$pval, n_obs, n_repos)

# LOC (should be identical to original - same denominator)
m_co_loc <- tryCatch({
  did_imputation(
    data       = panel_cc,
    yname      = "log_kloc",
    gname      = "first_treat_int",
    tname      = "month_id",
    idname     = "repo_int",
    first_stage = ~ 0 | repo_int + month_id,
    cluster_var = "repo_int"
  )
}, error = function(e) {
  did_imputation(
    data   = panel_cc,
    yname  = "log_kloc",
    gname  = "first_treat_int",
    tname  = "month_id",
    idname = "repo_int"
  )
})

r_l <- extract_did_imp(m_co_loc)
log_result("Container-Only LOC (Borusyak)", r_l$beta, r_l$se, r_l$ci_lo, r_l$ci_hi, r_l$pval, n_obs, n_repos)

# ============================================================
# 4. Event study (pre-trends)
# ============================================================
log_msg("\n--- 4. Event Study: Container-Only ---", logfile = LOGFILE)

m_co_es <- tryCatch({
  did_imputation(
    data       = panel_cc,
    yname      = "log_asd",
    gname      = "first_treat_int",
    tname      = "month_id",
    idname     = "repo_int",
    first_stage = ~ 0 | repo_int + month_id,
    cluster_var = "repo_int",
    horizon    = TRUE
  )
}, error = function(e) {
  did_imputation(
    data   = panel_cc,
    yname  = "log_asd",
    gname  = "first_treat_int",
    tname  = "month_id",
    idname = "repo_int",
    horizon = TRUE
  )
})

log_msg("Event study coefficients:", logfile = LOGFILE)
es_df <- as.data.frame(m_co_es)
for (i in seq_len(nrow(es_df))) {
  h <- es_df$term[i]
  b <- es_df$estimate[i]
  s <- es_df$std.error[i]
  p <- es_df$p.value[i]
  log_msg(sprintf("  h=%s: beta=%.4f (SE=%.4f, p=%.4f) -> %.1f%%", h, b, s, p, pct_effect(b)), logfile = LOGFILE)
}

# Pre-trend Wald test
pre_rows <- es_df %>% filter(as.numeric(gsub(".*=", "", term)) < -1)
if (nrow(pre_rows) > 0) {
  wald_chi2 <- sum((pre_rows$estimate / pre_rows$std.error)^2)
  wald_df <- nrow(pre_rows)
  wald_p <- pchisq(wald_chi2, df = wald_df, lower.tail = FALSE)
  log_msg(sprintf("Pre-trend Wald: chi2=%.2f, df=%d, p=%.3f", wald_chi2, wald_df, wald_p), logfile = LOGFILE)
}

# ============================================================
# 5. Summary comparison
# ============================================================
log_msg("\n=== COMPARISON: Original vs Container-Only ===", logfile = LOGFILE)
log_msg(sprintf("Original ASD:       beta=-0.0698, SE=0.0239, p=0.004 -> -6.7%%"), logfile = LOGFILE)
log_msg(sprintf("Container-Only ASD: beta=%.4f, SE=%.4f, p=%.4f -> %.1f%%",
                r$beta, r$se, r$pval, pct_effect(r$beta)), logfile = LOGFILE)
log_msg(sprintf("Original smells:    beta=+0.0108, p=0.82 -> +1.1%%"), logfile = LOGFILE)
log_msg(sprintf("Container smells:   beta=%.4f, p=%.4f -> %.1f%%",
                r_s$beta, r_s$pval, pct_effect(r_s$beta)), logfile = LOGFILE)
log_msg(sprintf("LOC (should match): beta=%.4f, p=%.4f -> %.1f%%",
                r_l$beta, r_l$pval, pct_effect(r_l$beta)), logfile = LOGFILE)

log_msg("\nDone.", logfile = LOGFILE)
