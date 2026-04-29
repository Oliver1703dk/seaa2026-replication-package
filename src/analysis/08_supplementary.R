# 08_supplementary.R - Supplementary analyses addressing reviewer concerns
# Input:  data/processed/panel_monthly.csv
# Output: data/interim/models/m_supp_*.rds, results/tables/tab_supplementary.tex
#
# Analyses:
#   1. DiD on raw smell counts (denominator effect)
#   2. DiD on LOC growth
#   3. Wild cluster bootstrap SEs
#   4. Lee bounds for attrition
#   5. Sensitivity excluding stale repos
#   6. Smells per package (alternative normalization)

source(here::here("src/analysis/utils/helpers.R"))
suppressPackageStartupMessages({
  library(fixest)
  library(didimputation)
})

set.seed(SEED)
LOGFILE <- file.path(DIR_LOGS, "08_supplementary.log")
cat("", file = LOGFILE)

log_msg("=== 08: Supplementary Analyses ===", logfile = LOGFILE)

# --- Load data ---
panel <- load_panel()
panel_cc <- panel %>% filter(!is.na(asd))

# Add supplementary outcome variables
panel_cc <- panel_cc %>%
  mutate(
    log_total_smells  = log(total_smells + 1),
    log_cd_count      = log(cd_count + 1),
    log_ud_count      = log(ud_count + 1),
    log_hl_count      = log(hl_count + 1),
    log_gc_count      = log(gc_count + 1),
    smell_per_pkg     = total_smells / pmax(num_packages, 1),
    log_smell_per_pkg = log(smell_per_pkg + 1),
    treat_post        = is_treatment * post
  )

n_repos <- n_distinct(panel_cc$repo_int)
n_obs   <- nrow(panel_cc)
log_msg(sprintf("Data: %d obs, %d repos", n_obs, n_repos), logfile = LOGFILE)

# --- Helper: run Borusyak imputation with fallback ---
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

# Collect results for the supplementary table
supp <- list()

# =====================================================
# 1. DiD on raw smell counts (denominator check)
# =====================================================
log_msg("\n--- 1: Raw Smell Counts (denominator check) ---", logfile = LOGFILE)
log_msg("If smells constant + LOC grows -> ASD drops mechanically", logfile = LOGFILE)

res <- run_borusyak(panel_cc, "log_total_smells", "Supp raw smells ATT")
if (res$success) {
  saveRDS(res$model, file.path(DIR_MODELS, "m_supp_raw_smells.rds"))
  supp$raw_smells <- res$result
}

# Per smell type (raw counts)
for (smell in c("cd", "ud", "hl", "gc")) {
  yvar  <- paste0("log_", smell, "_count")
  label <- paste0("Supp raw ", toupper(smell), " count ATT")
  r <- run_borusyak(panel_cc, yvar, label)
  if (r$success) {
    saveRDS(r$model, file.path(DIR_MODELS, sprintf("m_supp_raw_%s.rds", smell)))
    supp[[paste0("raw_", smell)]] <- r$result
  }
}

# =====================================================
# 2. DiD on LOC growth
# =====================================================
log_msg("\n--- 2: LOC Growth ---", logfile = LOGFILE)

res <- run_borusyak(panel_cc, "log_kloc", "Supp LOC growth ATT")
if (res$success) {
  saveRDS(res$model, file.path(DIR_MODELS, "m_supp_loc.rds"))
  supp$loc_growth <- res$result
}

# LOC event study
m_loc_es <- tryCatch({
  did_imputation(
    data      = panel_cc,
    yname     = "log_kloc",
    gname     = "first_treat_int",
    tname     = "month_id",
    idname    = "repo_int",
    horizon   = TRUE,
    pretrends = TRUE
  )
}, error = function(e) {
  log_msg(sprintf("  LOC ES error: %s. Trying without pretrends...", e$message),
          logfile = LOGFILE)
  tryCatch(
    did_imputation(
      data    = panel_cc,
      yname   = "log_kloc",
      gname   = "first_treat_int",
      tname   = "month_id",
      idname  = "repo_int",
      horizon = TRUE
    ),
    error = function(e2) { log_msg(sprintf("  LOC ES FAILED: %s", e2$message),
                                   logfile = LOGFILE); NULL }
  )
})

if (!is.null(m_loc_es)) {
  saveRDS(m_loc_es, file.path(DIR_MODELS, "m_supp_loc_es.rds"))
  log_msg("  LOC event study coefficients:", logfile = LOGFILE)
  for (i in seq_len(nrow(m_loc_es))) {
    pval_i <- 2 * pnorm(-abs(m_loc_es$estimate[i] / m_loc_es$std.error[i]))
    log_msg(sprintf("    h=%s: beta=%.4f, SE=%.4f, p=%.4f, effect=%.1f%%",
                    m_loc_es$term[i], m_loc_es$estimate[i], m_loc_es$std.error[i],
                    pval_i, pct_effect(m_loc_es$estimate[i])),
            logfile = LOGFILE)
  }
}

# Decomposition
if (!is.null(supp$raw_smells) && !is.null(supp$loc_growth)) {
  log_msg("\n  --- Denominator Decomposition ---", logfile = LOGFILE)
  log_msg(sprintf("    ASD effect (primary):    %.1f%%", pct_effect(-0.0698)),
          logfile = LOGFILE)
  log_msg(sprintf("    Raw smells effect:       %.1f%% (p=%.4f)",
                  pct_effect(supp$raw_smells$beta), supp$raw_smells$pval),
          logfile = LOGFILE)
  log_msg(sprintf("    LOC growth effect:       %.1f%% (p=%.4f)",
                  pct_effect(supp$loc_growth$beta), supp$loc_growth$pval),
          logfile = LOGFILE)

  if (supp$raw_smells$pval < ALPHA && supp$raw_smells$beta < 0) {
    log_msg("    VERDICT: GENUINE - raw smell counts also decrease", logfile = LOGFILE)
  } else if (supp$raw_smells$pval >= ALPHA &&
             supp$loc_growth$pval < ALPHA && supp$loc_growth$beta > 0) {
    log_msg("    VERDICT: DENOMINATOR ARTIFACT - smells constant, LOC grows", logfile = LOGFILE)
  } else if (supp$raw_smells$pval < ALPHA && supp$raw_smells$beta > 0) {
    log_msg("    VERDICT: MIXED - smells increase but LOC increases faster", logfile = LOGFILE)
  } else {
    log_msg("    VERDICT: AMBIGUOUS - neither component clearly significant", logfile = LOGFILE)
  }
}

# =====================================================
# 3. Wild cluster bootstrap SEs
# =====================================================
log_msg("\n--- 3: Wild Cluster Bootstrap ---", logfile = LOGFILE)
log_msg("Treatment 2.9x more volatile than control. Testing SE robustness.", logfile = LOGFILE)

# Plain TWFE for bootstrap (sunab not compatible with boottest)
m_plain <- feols(
  log_asd ~ treat_post | repo_int + month_id,
  data = panel_cc,
  vcov = ~repo_int
)

plain_beta <- coef(m_plain)["treat_post"]
plain_se   <- se(m_plain)["treat_post"]
plain_pval <- pvalue(m_plain)["treat_post"]
log_msg(sprintf("  Plain TWFE: beta=%.4f, clustered SE=%.4f, p=%.4f",
                plain_beta, plain_se, plain_pval), logfile = LOGFILE)

boot_done <- FALSE

# Attempt 1: fwildclusterboot
tryCatch({
  if (!requireNamespace("fwildclusterboot", quietly = TRUE)) {
    log_msg("  fwildclusterboot not installed. Run renv::restore() first.", logfile = LOGFILE)
    stop("fwildclusterboot not available")
  }
  suppressPackageStartupMessages(library(fwildclusterboot))

  set.seed(SEED)
  boot_res <- boottest(
    m_plain,
    param   = "treat_post",
    clustid = ~repo_int,
    B       = 9999,
    type    = "webb"
  )

  # Extract results (interface varies by version)
  bp <- tryCatch(pval(boot_res),   error = function(e) boot_res$p_val)
  bci <- tryCatch(boot_res$conf_int, error = function(e) c(NA, NA))

  if (!is.na(bp)) {
    log_msg(sprintf("  Wild bootstrap (Webb, B=9999): p=%.4f, 95%% CI=[%.4f, %.4f]",
                    bp, bci[1], bci[2]), logfile = LOGFILE)
    log_result("Supp wild bootstrap ATT", plain_beta, plain_se,
               bci[1], bci[2], bp, n_obs, n_repos)
    supp$bootstrap <- list(beta = plain_beta, se = plain_se,
                           ci_lo = bci[1], ci_hi = bci[2], pval = bp)
    boot_done <- TRUE
  }
}, error = function(e) {
  log_msg(sprintf("  fwildclusterboot error: %s", e$message), logfile = LOGFILE)
})

# Attempt 2: pairs cluster bootstrap
if (!boot_done) {
  log_msg("  Falling back to pairs cluster bootstrap (R=999)...", logfile = LOGFILE)
  tryCatch({
    library(boot)

    repo_ids   <- sort(unique(panel_cc$repo_int))
    n_clusters <- length(repo_ids)

    cluster_boot_fn <- function(cluster_vec, indices) {
      sampled <- cluster_vec[indices]
      # Rebuild observation-level data with unique repo IDs per sampled cluster
      pieces <- lapply(seq_along(sampled), function(i) {
        rows <- panel_cc[panel_cc$repo_int == sampled[i], ]
        rows$repo_boot <- i
        rows
      })
      bdata <- do.call(rbind, pieces)
      m <- tryCatch(
        feols(log_asd ~ treat_post | repo_boot + month_id, data = bdata),
        error = function(e) NULL
      )
      if (is.null(m)) return(NA_real_)
      coef(m)["treat_post"]
    }

    set.seed(SEED)
    boot_out    <- boot(repo_ids, cluster_boot_fn, R = 999)
    boot_betas  <- boot_out$t[!is.na(boot_out$t[, 1]), 1]
    n_valid     <- length(boot_betas)

    if (n_valid >= 500) {
      boot_se  <- sd(boot_betas)
      bci      <- quantile(boot_betas, c(0.025, 0.975))
      bp       <- 2 * min(mean(boot_betas >= 0), mean(boot_betas <= 0))

      log_msg(sprintf("  Pairs cluster bootstrap (%d/%d valid): SE=%.4f, p=%.4f, CI=[%.4f, %.4f]",
                      n_valid, 999, boot_se, bp, bci[1], bci[2]),
              logfile = LOGFILE)
      log_result("Supp cluster bootstrap ATT", plain_beta, boot_se,
                 unname(bci[1]), unname(bci[2]), bp, n_obs, n_repos)
      supp$bootstrap <- list(beta = plain_beta, se = boot_se,
                             ci_lo = unname(bci[1]), ci_hi = unname(bci[2]),
                             pval = bp)
      boot_done <- TRUE
    } else {
      log_msg(sprintf("  Only %d valid bootstrap reps - insufficient", n_valid),
              logfile = LOGFILE)
    }
  }, error = function(e) {
    log_msg(sprintf("  Pairs bootstrap error: %s", e$message), logfile = LOGFILE)
  })
}

if (!boot_done) {
  log_msg("  WARNING: All bootstrap approaches failed. Using standard clustered SEs.",
          logfile = LOGFILE)
  supp$bootstrap <- list(
    beta  = plain_beta, se = plain_se,
    ci_lo = plain_beta - qnorm(0.975) * plain_se,
    ci_hi = plain_beta + qnorm(0.975) * plain_se,
    pval  = plain_pval
  )
}

# =====================================================
# 4. Lee bounds for attrition
# =====================================================
log_msg("\n--- 4: Lee Bounds ---", logfile = LOGFILE)

n_t_total <- panel %>% filter(is_treatment == 1) %>% pull(repo_int) %>% n_distinct()
n_c_total <- panel %>% filter(is_treatment == 0) %>% pull(repo_int) %>% n_distinct()
n_t_obs   <- panel_cc %>% filter(is_treatment == 1) %>% pull(repo_int) %>% n_distinct()
n_c_obs   <- panel_cc %>% filter(is_treatment == 0) %>% pull(repo_int) %>% n_distinct()

att_t <- 1 - n_t_obs / n_t_total
att_c <- 1 - n_c_obs / n_c_total

log_msg(sprintf("  Attrition: treatment=%.1f%% (%d/%d), control=%.1f%% (%d/%d)",
                100 * att_t, n_t_total - n_t_obs, n_t_total,
                100 * att_c, n_c_total - n_c_obs, n_c_total),
        logfile = LOGFILE)

if (att_t > att_c) {
  p_trim <- (att_t - att_c) / (1 - att_c)
  n_trim <- ceiling(p_trim * n_t_obs)
  log_msg(sprintf("  Excess attrition: %.1f pp → trim %d treatment repos (%.1f%%)",
                  100 * (att_t - att_c), n_trim, 100 * p_trim),
          logfile = LOGFILE)

  # Rank treatment repos by mean ASD change (post - pre)
  repo_changes <- panel_cc %>%
    filter(is_treatment == 1) %>%
    group_by(repo_int) %>%
    summarise(
      mean_pre  = mean(log_asd[time_to_event < 0], na.rm = TRUE),
      mean_post = mean(log_asd[time_to_event > 0], na.rm = TRUE),
      .groups   = "drop"
    ) %>%
    mutate(change = mean_post - mean_pre) %>%
    filter(!is.na(change)) %>%
    arrange(change)

  log_msg(sprintf("  Treatment repos with computable change: %d", nrow(repo_changes)),
          logfile = LOGFILE)

  if (nrow(repo_changes) > n_trim + 5) {
    # Upper bound: drop most-improved (most negative change)
    drop_upper <- repo_changes %>% head(n_trim) %>% pull(repo_int)
    res_u <- run_borusyak(
      panel_cc %>% filter(!(repo_int %in% drop_upper)),
      "log_asd", "Supp Lee UPPER (pessimistic)"
    )
    if (res_u$success) {
      saveRDS(res_u$model, file.path(DIR_MODELS, "m_supp_lee_upper.rds"))
      supp$lee_upper <- res_u$result
    }

    # Lower bound: drop least-improved (most positive change)
    drop_lower <- repo_changes %>% tail(n_trim) %>% pull(repo_int)
    res_l <- run_borusyak(
      panel_cc %>% filter(!(repo_int %in% drop_lower)),
      "log_asd", "Supp Lee LOWER (optimistic)"
    )
    if (res_l$success) {
      saveRDS(res_l$model, file.path(DIR_MODELS, "m_supp_lee_lower.rds"))
      supp$lee_lower <- res_l$result
    }

    if (res_u$success && res_l$success) {
      log_msg(sprintf("\n  Lee bounds: [%.1f%%, %.1f%%]",
                      pct_effect(res_l$result$beta), pct_effect(res_u$result$beta)),
              logfile = LOGFILE)
      if (res_u$result$beta < 0) {
        log_msg("  → Both bounds negative: attrition CANNOT explain the finding",
                logfile = LOGFILE)
      } else if (res_l$result$beta < 0) {
        log_msg("  → Bounds span zero: attrition COULD partially explain the finding",
                logfile = LOGFILE)
      } else {
        log_msg("  → Both bounds positive: finding reverses under worst-case",
                logfile = LOGFILE)
      }
    }
  } else {
    log_msg("  Not enough treatment repos for Lee trimming", logfile = LOGFILE)
  }
} else {
  log_msg("  No excess treatment attrition - Lee bounds not applicable", logfile = LOGFILE)
}

# =====================================================
# 5. Sensitivity: exclude stale repos
# =====================================================
log_msg("\n--- 5: Exclude Stale Repos ---", logfile = LOGFILE)

stale3 <- panel %>%
  group_by(repo_int) %>%
  summarise(zero_mo = sum(monthly_commits == 0), .groups = "drop") %>%
  filter(zero_mo >= 3) %>% pull(repo_int)

stale6 <- panel %>%
  group_by(repo_int) %>%
  summarise(zero_mo = sum(monthly_commits == 0), .groups = "drop") %>%
  filter(zero_mo >= 6) %>% pull(repo_int)

# Threshold ≥3
p_active3 <- panel_cc %>% filter(!(repo_int %in% stale3))
n3 <- n_distinct(p_active3$repo_int)
n3t <- p_active3 %>% filter(is_treatment == 1) %>% pull(repo_int) %>% n_distinct()
n3c <- p_active3 %>% filter(is_treatment == 0) %>% pull(repo_int) %>% n_distinct()
log_msg(sprintf("  Active (≥3 threshold): %d repos (T=%d, C=%d), %d obs",
                n3, n3t, n3c, nrow(p_active3)), logfile = LOGFILE)

res5a <- run_borusyak(p_active3, "log_asd",
                      sprintf("Supp active-only (≥3, N=%d)", n3))
if (res5a$success) {
  saveRDS(res5a$model, file.path(DIR_MODELS, "m_supp_active3.rds"))
  supp$active3 <- res5a$result
}

# Threshold ≥6
p_active6 <- panel_cc %>% filter(!(repo_int %in% stale6))
n6 <- n_distinct(p_active6$repo_int)
n6t <- p_active6 %>% filter(is_treatment == 1) %>% pull(repo_int) %>% n_distinct()
n6c <- p_active6 %>% filter(is_treatment == 0) %>% pull(repo_int) %>% n_distinct()
log_msg(sprintf("  Active (≥6 threshold): %d repos (T=%d, C=%d), %d obs",
                n6, n6t, n6c, nrow(p_active6)), logfile = LOGFILE)

res5b <- run_borusyak(p_active6, "log_asd",
                      sprintf("Supp active-only (≥6, N=%d)", n6))
if (res5b$success) {
  saveRDS(res5b$model, file.path(DIR_MODELS, "m_supp_active6.rds"))
  supp$active6 <- res5b$result
}

# =====================================================
# 6. Smells per package (alternative normalization)
# =====================================================
log_msg("\n--- 6: Smells per Package ---", logfile = LOGFILE)
log_msg("Alternative normalization: total_smells / num_packages (not KLOC)", logfile = LOGFILE)

res6 <- run_borusyak(panel_cc, "log_smell_per_pkg", "Supp smells/package ATT")
if (res6$success) {
  saveRDS(res6$model, file.path(DIR_MODELS, "m_supp_per_pkg.rds"))
  supp$per_pkg <- res6$result
}

# =====================================================
# B.3: num_packages sensitivity
# =====================================================
log_msg("\n--- 7: num_packages Sensitivity ---", logfile = LOGFILE)
log_msg("Checking repos that violate min_packages >= 30 inclusion criterion", logfile = LOGFILE)

repo_pkg_stats <- panel_cc %>%
  group_by(repo_name, repo_int) %>%
  summarise(median_packages = median(num_packages, na.rm = TRUE), .groups = "drop")

repos_below_30 <- repo_pkg_stats %>% filter(median_packages < 30)
log_msg(sprintf("  Repos with median packages < 30: %d (%.1f%%)",
                nrow(repos_below_30), 100 * nrow(repos_below_30) / n_distinct(panel_cc$repo_int)),
        logfile = LOGFILE)

panel_pkg30 <- panel_cc %>% filter(!repo_int %in% repos_below_30$repo_int)
n_pkg30 <- n_distinct(panel_pkg30$repo_int)
log_msg(sprintf("  After filtering: %d repos, %d obs", n_pkg30, nrow(panel_pkg30)),
        logfile = LOGFILE)

res_pkg30 <- run_borusyak(panel_pkg30, "log_asd", "Sensitivity packages>=30 ATT")
if (res_pkg30$success) {
  saveRDS(res_pkg30$model, file.path(DIR_MODELS, "m_supp_pkg30.rds"))
  supp$pkg30 <- res_pkg30$result
}

# =====================================================
# B.5: Balanced ASD (equal weight per smell type)
# =====================================================
log_msg("\n--- 8: Balanced ASD ---", logfile = LOGFILE)
log_msg("Equal-weight average of 4 type-specific densities (addresses CD dominance)", logfile = LOGFILE)

panel_cc <- panel_cc %>%
  mutate(balanced_asd = (cd_density + ud_density + hl_density + gc_density) / 4,
         log_balanced_asd = log(balanced_asd + 1))

res_balanced <- run_borusyak(panel_cc, "log_balanced_asd", "Balanced ASD ATT")
if (res_balanced$success) {
  saveRDS(res_balanced$model, file.path(DIR_MODELS, "m_supp_balanced_asd.rds"))
  supp$balanced_asd <- res_balanced$result
}

# =====================================================
# B.10: Outlier sensitivity (kloc < 1)
# =====================================================
log_msg("\n--- 9: Outlier Sensitivity (kloc >= 1) ---", logfile = LOGFILE)

n_outlier <- sum(panel_cc$kloc < 1)
log_msg(sprintf("  Observations with kloc < 1: %d (%.1f%%)",
                n_outlier, 100 * n_outlier / nrow(panel_cc)),
        logfile = LOGFILE)

panel_no_outlier <- panel_cc %>% filter(kloc >= 1)
res_outlier <- run_borusyak(panel_no_outlier, "log_asd", "Sensitivity kloc>=1 ATT")
if (res_outlier$success) {
  saveRDS(res_outlier$model, file.path(DIR_MODELS, "m_supp_outlier.rds"))
  supp$outlier <- res_outlier$result
}

# =====================================================
# Generate supplementary LaTeX table
# =====================================================
log_msg("\n--- Generating tab_supplementary.tex ---", logfile = LOGFILE)

fmt_row <- function(label, r) {
  if (is.null(r)) return(NULL)
  stars <- ifelse(r$pval < 0.01, "***",
           ifelse(r$pval < 0.05, "**",
           ifelse(r$pval < 0.1,  "*", "")))
  sprintf("%s & %.4f%s & %.4f & [%.4f, %.4f] & %.4f & %.1f\\%% \\\\",
          label, r$beta, stars, r$se, r$ci_lo, r$ci_hi, r$pval, pct_effect(r$beta))
}

rows <- Filter(Negate(is.null), list(
  "\\midrule",
  "\\multicolumn{6}{l}{\\textit{Denominator decomposition}} \\\\",
  fmt_row("Raw smell count", supp$raw_smells),
  fmt_row("LOC growth (log KLOC)", supp$loc_growth),
  fmt_row("Smells per package", supp$per_pkg),
  "\\midrule",
  "\\multicolumn{6}{l}{\\textit{Inference robustness}} \\\\",
  fmt_row("Wild cluster bootstrap", supp$bootstrap),
  "\\midrule",
  "\\multicolumn{6}{l}{\\textit{Attrition bounds (Lee 2009)}} \\\\",
  fmt_row("Upper bound (pessimistic)", supp$lee_upper),
  fmt_row("Lower bound (optimistic)", supp$lee_lower),
  "\\midrule",
  "\\multicolumn{6}{l}{\\textit{Sample sensitivity}} \\\\",
  fmt_row(sprintf("Excl.\\ stale ($\\geq$3 zero-mo, N=%d)", n3), supp$active3),
  fmt_row(sprintf("Excl.\\ stale ($\\geq$6 zero-mo, N=%d)", n6), supp$active6),
  fmt_row(sprintf("Packages $\\geq$ 30 (N=%d)", n_pkg30), supp$pkg30),
  fmt_row("Balanced ASD (equal type weight)", supp$balanced_asd),
  fmt_row("Excl.\\ outliers (KLOC $\\geq$ 1)", supp$outlier)
))

tex <- c(
  "\\begin{table}[t]",
  "\\centering",
  "\\caption{Supplementary analyses: denominator decomposition, inference robustness, attrition bounds, and sample sensitivity.}",
  "\\label{tab:supplementary}",
  "\\begin{tabular}{lccccc}",
  "\\toprule",
  "Analysis & ATT ($\\hat{\\beta}$) & SE & 95\\% CI & $p$-value & Effect (\\%) \\\\",
  unlist(rows),
  "\\bottomrule",
  "\\multicolumn{6}{l}{\\footnotesize $^{*}p<0.1$; $^{**}p<0.05$; $^{***}p<0.01$. Primary ASD estimate: $\\hat{\\beta}$=-0.070, $p$=0.004.} \\\\",
  "\\end{tabular}",
  "\\end{table}"
)

writeLines(tex, file.path(DIR_TABLES, "tab_supplementary.tex"))
log_msg("Saved: tab_supplementary.tex", logfile = LOGFILE)

# =====================================================
# 10: Control contamination sensitivity
# =====================================================
log_msg("\n--- 10: Control Contamination Sensitivity ---", logfile = LOGFILE)
log_msg("Excluding contaminated controls (AI markers during study window)", logfile = LOGFILE)

contam_file <- here::here("data/interim/control_contamination.csv")
if (file.exists(contam_file)) {
  contam <- read.csv(contam_file)
  contam_repos <- contam %>% filter(contaminated == "yes") %>% pull(repo_name)
  n_contam <- length(contam_repos)
  log_msg(sprintf("  Contaminated controls: %d", n_contam), logfile = LOGFILE)

  panel_no_contam <- panel_cc %>% filter(!repo_name %in% contam_repos)
  n_nc <- n_distinct(panel_no_contam$repo_int)
  log_msg(sprintf("  After exclusion: %d repos, %d obs", n_nc, nrow(panel_no_contam)),
          logfile = LOGFILE)

  res_nc <- run_borusyak(panel_no_contam, "log_asd",
                         sprintf("Sensitivity excl. contaminated controls (N=%d)", n_nc))
  if (res_nc$success) {
    saveRDS(res_nc$model, file.path(DIR_MODELS, "m_supp_no_contam.rds"))
    supp$no_contam <- res_nc$result
  }
} else {
  log_msg("  control_contamination.csv not found, skipping", logfile = LOGFILE)
}

# =====================================================
# 11: log(ASD) strict sensitivity (no +1 offset)
# =====================================================
log_msg("\n--- 11: log(ASD) Strict Sensitivity ---", logfile = LOGFILE)
log_msg("Validates decomposition: log(ASD) without +1 offset (drop zeros)", logfile = LOGFILE)

panel_pos <- panel_cc %>% filter(asd > 0)
panel_pos$log_asd_strict <- log(panel_pos$asd)
n_pos <- n_distinct(panel_pos$repo_int)
n_dropped <- nrow(panel_cc) - nrow(panel_pos)
log_msg(sprintf("  Dropped %d zero-ASD observations, %d repos remain",
                n_dropped, n_pos), logfile = LOGFILE)

res_strict <- run_borusyak(panel_pos, "log_asd_strict",
                           sprintf("Sensitivity log(ASD) no +1 (N=%d)", n_pos))
if (res_strict$success) {
  saveRDS(res_strict$model, file.path(DIR_MODELS, "m_supp_strict_log.rds"))
  supp$strict_log <- res_strict$result
}

# =====================================================
# Final summary
# =====================================================
log_msg("\n=== INTERPRETATION SUMMARY ===", logfile = LOGFILE)

if (!is.null(supp$raw_smells) && !is.null(supp$loc_growth)) {
  s_sig <- supp$raw_smells$pval < ALPHA
  l_sig <- supp$loc_growth$pval < ALPHA
  s_neg <- supp$raw_smells$beta < 0
  l_pos <- supp$loc_growth$beta > 0
  if (s_sig && s_neg)                  log_msg("DENOMINATOR: GENUINE improvement",     logfile = LOGFILE)
  else if (!s_sig && l_sig && l_pos)   log_msg("DENOMINATOR: ARTIFACT (LOC growth)",   logfile = LOGFILE)
  else if (s_sig && !s_neg)            log_msg("DENOMINATOR: MIXED (smells up, LOC up faster)", logfile = LOGFILE)
  else                                 log_msg("DENOMINATOR: AMBIGUOUS",               logfile = LOGFILE)
}

if (!is.null(supp$bootstrap)) {
  if (supp$bootstrap$pval < ALPHA) log_msg("BOOTSTRAP: ROBUST",  logfile = LOGFILE)
  else                             log_msg("BOOTSTRAP: FRAGILE - standard SEs too liberal", logfile = LOGFILE)
}

if (!is.null(supp$lee_upper)) {
  if (supp$lee_upper$beta < 0) log_msg("ATTRITION: ROBUST (both bounds negative)", logfile = LOGFILE)
  else                         log_msg("ATTRITION: BOUNDS SPAN ZERO",              logfile = LOGFILE)
}

if (!is.null(supp$per_pkg)) {
  if (supp$per_pkg$pval < ALPHA && supp$per_pkg$beta < 0)
    log_msg("NORMALIZATION: ROBUST (smells/pkg also decreases)", logfile = LOGFILE)
  else
    log_msg("NORMALIZATION: SENSITIVE (effect depends on normalization)", logfile = LOGFILE)
}

log_session("08_supplementary")
log_msg("\n=== 08: Complete ===", logfile = LOGFILE)
