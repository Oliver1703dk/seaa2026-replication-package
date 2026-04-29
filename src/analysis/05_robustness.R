# 05_robustness.R - Callaway & Sant'Anna, placebo, size-stratified
# Input:  data/processed/panel_monthly.csv, data/interim/models/descriptive_objects.rds
# Output: data/interim/models/m_cs.rds, m_placebo.rds, m_size_*.rds, m_es_*.rds

source(here::here("src/analysis/utils/helpers.R"))
suppressPackageStartupMessages({
  library(fixest)
  library(didimputation)
  library(did)
})

set.seed(SEED)
LOGFILE <- file.path(DIR_LOGS, "05_robustness.log")
cat("", file = LOGFILE)

log_msg("=== 05: Robustness Checks ===", logfile = LOGFILE)

# --- Load data ---
panel <- load_panel()
panel_cc <- panel %>% filter(!is.na(asd))
n_repos <- n_distinct(panel_cc$repo_int)
n_obs <- nrow(panel_cc)

# =====================================================
# 5a. Callaway & Sant'Anna
# =====================================================
log_msg("\n--- 5a: Callaway & Sant'Anna ---", logfile = LOGFILE)

m_cs <- tryCatch({
  att_gt(
    yname   = "log_asd",
    tname   = "month_id",
    idname  = "repo_int",
    gname   = "first_treat_int",
    xformla = ~ log_kloc + monthly_contributors,
    data    = as.data.frame(panel_cc),
    est_method = "dr",
    print_details = FALSE,
    allow_unbalanced_panel = TRUE
  )
}, error = function(e) {
  log_msg(sprintf("C&S error: %s", e$message), logfile = LOGFILE)
  log_msg("Trying without covariates...", logfile = LOGFILE)
  tryCatch({
    att_gt(
      yname  = "log_asd",
      tname  = "month_id",
      idname = "repo_int",
      gname  = "first_treat_int",
      data   = as.data.frame(panel_cc),
      est_method = "reg",
      print_details = FALSE,
      allow_unbalanced_panel = TRUE
    )
  }, error = function(e2) {
    log_msg(sprintf("C&S fallback also failed: %s", e2$message), logfile = LOGFILE)
    NULL
  })
})

if (!is.null(m_cs)) {
  m_cs_agg <- aggte(m_cs, type = "simple", na.rm = TRUE)
  saveRDS(list(gt = m_cs, agg = m_cs_agg), file.path(DIR_MODELS, "m_cs.rds"))

  beta_cs <- m_cs_agg$overall.att
  se_cs   <- m_cs_agg$overall.se
  ci_lo_cs <- beta_cs - qnorm(0.975) * se_cs
  ci_hi_cs <- beta_cs + qnorm(0.975) * se_cs
  pval_cs  <- 2 * pnorm(-abs(beta_cs / se_cs))
  log_result("Robustness C&S ATT", beta_cs, se_cs, ci_lo_cs, ci_hi_cs, pval_cs, n_obs, n_repos)
} else {
  log_msg("C&S estimator FAILED - skipping", logfile = LOGFILE)
}

# --- C&S with IPW (single covariate) ---
log_msg("\n--- 5a-bis: C&S with IPW + monthly_contributors ---", logfile = LOGFILE)

m_cs_ipw <- tryCatch({
  att_gt(
    yname   = "log_asd",
    tname   = "month_id",
    idname  = "repo_int",
    gname   = "first_treat_int",
    xformla = ~ monthly_contributors,
    data    = as.data.frame(panel_cc),
    est_method = "ipw",
    print_details = FALSE,
    allow_unbalanced_panel = TRUE
  )
}, error = function(e) {
  log_msg(sprintf("C&S IPW error: %s", e$message), logfile = LOGFILE)
  NULL
})

if (!is.null(m_cs_ipw)) {
  m_cs_ipw_agg <- aggte(m_cs_ipw, type = "simple", na.rm = TRUE)
  saveRDS(list(gt = m_cs_ipw, agg = m_cs_ipw_agg), file.path(DIR_MODELS, "m_cs_ipw.rds"))
  beta_ipw <- m_cs_ipw_agg$overall.att
  se_ipw   <- m_cs_ipw_agg$overall.se
  pval_ipw <- 2 * pnorm(-abs(beta_ipw / se_ipw))
  log_result("Robustness C&S IPW ATT", beta_ipw, se_ipw,
             beta_ipw - qnorm(0.975)*se_ipw,
             beta_ipw + qnorm(0.975)*se_ipw,
             pval_ipw, n_obs, n_repos)
} else {
  log_msg("C&S IPW estimator FAILED -- skipping", logfile = LOGFILE)
}

# =====================================================
# 5b. Placebo test (fake adoption 6 months earlier)
# =====================================================
log_msg("\n--- 5b: Placebo Test ---", logfile = LOGFILE)

panel_placebo <- panel_cc %>%
  mutate(
    fake_treat_int = ifelse(is_treatment == 0, 0L, first_treat_int - 6L)
  ) %>%
  filter(month_id < first_treat_int | is_treatment == 0)

log_msg(sprintf("Placebo panel: %d obs, %d repos",
                nrow(panel_placebo), n_distinct(panel_placebo$repo_int)),
        logfile = LOGFILE)

# Placebo test: The pre-trend Wald test (script 04) already validates the design
# (p=0.90, all pre-period coefficients jointly zero).
# Here we run a formal placebo with fake adoption 6 months earlier.
# IMPORTANT: Use panel_placebo (pre-treatment only for treated repos) to avoid
# the real treatment effect bleeding into the fake post-period.
# panel_placebo_full is kept only for reference - NOT used for estimation.
panel_placebo_full <- panel_cc %>%
  mutate(
    fake_treat_int = ifelse(is_treatment == 0, 0L, first_treat_int - 6L)
  )

m_placebo <- tryCatch({
  did_imputation(
    data        = panel_placebo,
    yname       = "log_asd",
    gname       = "fake_treat_int",
    tname       = "month_id",
    idname      = "repo_int",
    first_stage = ~ 0 | repo_int + month_id,
    cluster_var = "repo_int"
  )
}, error = function(e) {
  log_msg(sprintf("Placebo Borusyak error: %s", e$message), logfile = LOGFILE)
  NULL
})

if (!is.null(m_placebo) && !is.na(m_placebo$estimate[1])) {
  saveRDS(m_placebo, file.path(DIR_MODELS, "m_placebo.rds"))
  r_plac <- extract_did_imp(m_placebo)
  beta_p <- r_plac$beta; se_p <- r_plac$se
  ci_lo_p <- r_plac$ci_lo; ci_hi_p <- r_plac$ci_hi; pval_p <- r_plac$pval
  log_result("Robustness Placebo ATT", beta_p, se_p, ci_lo_p, ci_hi_p, pval_p,
             nrow(panel_placebo), n_distinct(panel_placebo$repo_int))
  if (pval_p > ALPHA) {
    log_msg("  -> Placebo is null (p > 0.05). Design validates.", logfile = LOGFILE)
  } else {
    log_msg("  -> WARNING: Placebo is significant. Discuss in threats.", logfile = LOGFILE)
  }
} else {
  log_msg("  Placebo ATT could not be estimated. Pre-trend Wald test (p=0.90) is primary validation.",
          logfile = LOGFILE)

  # Fallback: TWFE-SA placebo with 3-month shift (less aggressive)
  log_msg("  Trying TWFE-SA placebo with 3-month shift...", logfile = LOGFILE)
  panel_placebo_3m <- panel_cc %>%
    mutate(
      fake_treat_sa_3 = ifelse(is_treatment == 0, 100000L, first_treat_sa - 3L)
    )

  m_placebo_sa <- tryCatch({
    feols(
      log_asd ~ sunab(fake_treat_sa_3, month_id) | repo_int + month_id,
      data = panel_placebo_3m %>% filter(month_id < first_treat_sa | is_treatment == 0),
      vcov = ~repo_int
    )
  }, error = function(e) {
    log_msg(sprintf("  TWFE-SA placebo error: %s", e$message), logfile = LOGFILE)
    NULL
  })

  if (!is.null(m_placebo_sa)) {
    s_plac_sa <- summary(m_placebo_sa, agg = "att")
    ct_plac <- coeftable(s_plac_sa)
    saveRDS(m_placebo_sa, file.path(DIR_MODELS, "m_placebo.rds"))
    log_result("Robustness Placebo TWFE-SA (t-3)", ct_plac[1,1], ct_plac[1,2],
               ct_plac[1,1] - qnorm(0.975)*ct_plac[1,2],
               ct_plac[1,1] + qnorm(0.975)*ct_plac[1,2],
               ct_plac[1,4],
               nrow(panel_placebo_3m %>% filter(month_id < first_treat_sa | is_treatment == 0)),
               n_distinct((panel_placebo_3m %>% filter(month_id < first_treat_sa | is_treatment == 0))$repo_int))
    if (ct_plac[1,4] > ALPHA) {
      log_msg("  -> Placebo is null (p > 0.05). Design validates.", logfile = LOGFILE)
    } else {
      log_msg("  -> WARNING: Placebo is significant. Discuss in threats.", logfile = LOGFILE)
    }
  }
}

# Placebo event study for figure (use pre-treatment-only data)
m_es_placebo <- tryCatch({
  did_imputation(
    data    = panel_placebo,
    yname   = "log_asd",
    gname   = "fake_treat_int",
    tname   = "month_id",
    idname  = "repo_int",
    horizon = TRUE
  )
}, error = function(e) {
  log_msg(sprintf("Placebo ES error: %s", e$message), logfile = LOGFILE)
  NULL
})

if (!is.null(m_es_placebo) && !any(is.na(m_es_placebo$estimate))) {
  saveRDS(m_es_placebo, file.path(DIR_MODELS, "m_es_placebo.rds"))
  log_msg("Saved placebo event study model", logfile = LOGFILE)
} else {
  log_msg("Placebo ES: Borusyak returned NAs. Skipping figure.", logfile = LOGFILE)

  # Fallback: TWFE-SA event study for placebo figure
  log_msg("  Trying TWFE-SA event study for placebo figure...", logfile = LOGFILE)

  # Reuse panel_placebo_3m if already created; otherwise create it
  if (!exists("panel_placebo_3m")) {
    panel_placebo_3m <- panel_cc %>%
      mutate(
        fake_treat_sa_3 = ifelse(is_treatment == 0, 100000L, first_treat_sa - 3L)
      )
  }

  m_es_plac_sa <- tryCatch({
    feols(
      log_asd ~ sunab(fake_treat_sa_3, month_id) | repo_int + month_id,
      data = panel_placebo_3m %>% filter(month_id < first_treat_sa | is_treatment == 0),
      vcov = ~repo_int
    )
  }, error = function(e) {
    log_msg(sprintf("  TWFE-SA placebo ES error: %s", e$message), logfile = LOGFILE)
    NULL
  })
  if (!is.null(m_es_plac_sa)) {
    saveRDS(m_es_plac_sa, file.path(DIR_MODELS, "m_es_placebo.rds"))
    log_msg("  Saved TWFE-SA placebo event study model", logfile = LOGFILE)
  }
}

# =====================================================
# 5c. Size-stratified analysis
# =====================================================
log_msg("\n--- 5c: Size-Stratified Analysis ---", logfile = LOGFILE)

desc <- readRDS(file.path(DIR_MODELS, "descriptive_objects.rds"))
median_kloc <- desc$median_kloc

panel_cc <- panel_cc %>%
  left_join(desc$repo_median_kloc, by = "repo_int") %>%
  mutate(size_group = ifelse(repo_kloc <= median_kloc, "small", "large"))

for (sz in c("small", "large")) {
  log_msg(sprintf("\n  Size group: %s", sz), logfile = LOGFILE)
  sub <- filter(panel_cc, size_group == sz)
  n_sub <- n_distinct(sub$repo_int)
  n_obs_sub <- nrow(sub)
  log_msg(sprintf("  N: %d obs, %d repos", n_obs_sub, n_sub), logfile = LOGFILE)

  # Static ATT
  m <- tryCatch({
    did_imputation(
      data        = sub,
      yname       = "log_asd",
      gname       = "first_treat_int",
      tname       = "month_id",
      idname      = "repo_int",
      first_stage = ~ 0 | repo_int + month_id,
      cluster_var = "repo_int"
    )
  }, error = function(e) {
    log_msg(sprintf("  Size %s error: %s", sz, e$message), logfile = LOGFILE)
    did_imputation(
      data   = sub,
      yname  = "log_asd",
      gname  = "first_treat_int",
      tname  = "month_id",
      idname = "repo_int"
    )
  })

  saveRDS(m, file.path(DIR_MODELS, sprintf("m_size_%s.rds", sz)))

  r <- extract_did_imp(m)
  log_result(sprintf("Size-stratified %s ATT", sz), r$beta, r$se, r$ci_lo, r$ci_hi, r$pval, n_obs_sub, n_sub)

  # Event study by size
  m_es <- tryCatch({
    did_imputation(
      data    = sub,
      yname   = "log_asd",
      gname   = "first_treat_int",
      tname   = "month_id",
      idname  = "repo_int",
      horizon = TRUE
    )
  }, error = function(e) {
    log_msg(sprintf("  Size %s ES error: %s", sz, e$message), logfile = LOGFILE)
    NULL
  })

  if (!is.null(m_es)) {
    saveRDS(m_es, file.path(DIR_MODELS, sprintf("m_es_%s.rds", sz)))
  }
}

# =====================================================
# 5d. Sensitivity: exclude single-event treatment repos
# =====================================================
log_msg("\n--- 5d: Exclude Single-Event Treatment Repos ---", logfile = LOGFILE)

treat_meta_path <- here("config/repo_lists/treatment_final.csv")
if (file.exists(treat_meta_path)) {
  treat_meta <- read_csv(treat_meta_path, show_col_types = FALSE)

  if ("total_ai_events" %in% names(treat_meta)) {
    single_event_repos <- treat_meta %>%
      filter(total_ai_events <= 1) %>%
      pull(full_name)

    log_msg(sprintf("  Single-event treatment repos: %d", length(single_event_repos)),
            logfile = LOGFILE)

    # Exclude single-event treatment repos; keep all controls
    panel_multi <- panel_cc %>%
      filter(!(repo_name %in% single_event_repos) | is_treatment == 0)

    n_multi <- n_distinct(panel_multi$repo_int)
    n_multi_t <- panel_multi %>% filter(is_treatment == 1) %>% pull(repo_int) %>% n_distinct()
    n_multi_c <- panel_multi %>% filter(is_treatment == 0) %>% pull(repo_int) %>% n_distinct()
    log_msg(sprintf("  After excluding single-event: %d repos (T=%d, C=%d), %d obs",
                    n_multi, n_multi_t, n_multi_c, nrow(panel_multi)),
            logfile = LOGFILE)

    m_multi <- tryCatch({
      did_imputation(
        data        = panel_multi,
        yname       = "log_asd",
        gname       = "first_treat_int",
        tname       = "month_id",
        idname      = "repo_int",
        first_stage = ~ 0 | repo_int + month_id,
        cluster_var = "repo_int"
      )
    }, error = function(e) {
      log_msg(sprintf("  Error: %s. Trying minimal spec...", e$message), logfile = LOGFILE)
      tryCatch(
        did_imputation(
          data   = panel_multi,
          yname  = "log_asd",
          gname  = "first_treat_int",
          tname  = "month_id",
          idname = "repo_int"
        ),
        error = function(e2) {
          log_msg(sprintf("  Multi-event FAILED: %s", e2$message), logfile = LOGFILE)
          NULL
        }
      )
    })

    if (!is.null(m_multi)) {
      r <- extract_did_imp(m_multi)
      saveRDS(m_multi, file.path(DIR_MODELS, "m_robust_multi_event.rds"))
      log_result("Robustness multi-event ATT", r$beta, r$se, r$ci_lo, r$ci_hi, r$pval,
                 nrow(panel_multi), n_multi)
    }
  } else {
    log_msg("  total_ai_events column not found -- skipping", logfile = LOGFILE)
  }
} else {
  log_msg("  treatment_final.csv not found -- skipping", logfile = LOGFILE)
}

# =====================================================
# B.2a: C&S with individual covariates
# =====================================================
log_msg("\n--- 5e: C&S with Individual Covariates ---", logfile = LOGFILE)
log_msg("  Isolating which covariate causes collinearity in DR spec", logfile = LOGFILE)

for (xvar in c("monthly_contributors", "log_kloc")) {
  m_cs_ind <- tryCatch({
    att_gt(
      yname = "log_asd", tname = "month_id", idname = "repo_int",
      gname = "first_treat_int",
      xformla = as.formula(paste("~", xvar)),
      data = as.data.frame(panel_cc),
      est_method = "dr", print_details = FALSE,
      allow_unbalanced_panel = TRUE
    )
  }, error = function(e) {
    log_msg(sprintf("  C&S DR with %s error: %s", xvar, e$message), logfile = LOGFILE)
    NULL
  })
  if (!is.null(m_cs_ind)) {
    agg <- aggte(m_cs_ind, type = "simple", na.rm = TRUE)
    beta_i <- agg$overall.att
    se_i <- agg$overall.se
    pval_i <- 2 * pnorm(-abs(beta_i / se_i))
    log_result(sprintf("C&S DR (%s)", xvar), beta_i, se_i,
               beta_i - qnorm(0.975) * se_i,
               beta_i + qnorm(0.975) * se_i,
               pval_i, n_obs, n_repos)
  }
}

# =====================================================
# B.2b: Bacon decomposition (requires balanced panel)
# =====================================================
log_msg("\n--- 5f: Bacon Decomposition ---", logfile = LOGFILE)

tryCatch({
  suppressPackageStartupMessages(library(bacondecomp))

  # Balance the panel by filling missing months
  all_months <- sort(unique(panel_cc$month_id))
  all_repos <- unique(panel_cc$repo_int)

  panel_balanced <- panel_cc %>%
    tidyr::complete(repo_int = all_repos, month_id = all_months) %>%
    group_by(repo_int) %>%
    tidyr::fill(is_treatment, first_treat_int, first_treat_sa, repo_name, .direction = "downup") %>%
    ungroup() %>%
    filter(!is.na(log_asd)) %>%
    mutate(treat_post = as.integer(month_id >= first_treat_int & is_treatment == 1))

  # Check if balanced now
  obs_per_repo <- panel_balanced %>% group_by(repo_int) %>% summarise(n = n(), .groups = "drop")
  max_n <- max(obs_per_repo$n)
  balanced_repos <- obs_per_repo %>% filter(n == max_n) %>% pull(repo_int)

  panel_bacon <- panel_balanced %>% filter(repo_int %in% balanced_repos)
  log_msg(sprintf("  Balanced panel: %d repos with %d periods each, %d obs",
                  length(balanced_repos), max_n, nrow(panel_bacon)), logfile = LOGFILE)

  if (length(balanced_repos) >= 50) {
    bacon_out <- bacon(log_asd ~ treat_post, data = as.data.frame(panel_bacon),
                       id_var = "repo_int", time_var = "month_id")

    saveRDS(bacon_out, file.path(DIR_MODELS, "bacon_decomp.rds"))

    bacon_summary <- bacon_out %>%
      group_by(type) %>%
      summarise(
        total_weight = sum(weight),
        weighted_est = weighted.mean(estimate, weight),
        n_comparisons = n(),
        .groups = "drop"
      )

    log_msg("  Bacon decomposition results:", logfile = LOGFILE)
    for (i in seq_len(nrow(bacon_summary))) {
      row <- bacon_summary[i, ]
      log_msg(sprintf("    %s: weight=%.3f, estimate=%.4f, n=%d",
                      row$type, row$total_weight, row$weighted_est, row$n_comparisons),
              logfile = LOGFILE)
    }

    good_weight <- bacon_summary %>%
      filter(type == "Treated vs Untreated") %>%
      pull(total_weight)
    good_est <- bacon_summary %>%
      filter(type == "Treated vs Untreated") %>%
      pull(weighted_est)

    if (length(good_weight) > 0) {
      cat(sprintf("Bacon Treated-vs-Untreated: weight=%.3f, estimate=%.4f\n",
                  good_weight, good_est),
          file = SUMMARY_FILE, append = TRUE)
      log_msg(sprintf("  -> %.1f%% of TWFE weight from 'good' (treated vs untreated) comparisons",
                      100 * good_weight), logfile = LOGFILE)
    }
  } else {
    log_msg(sprintf("  Only %d balanced repos - insufficient for Bacon decomposition",
                    length(balanced_repos)), logfile = LOGFILE)
  }
}, error = function(e) {
  log_msg(sprintf("  Bacon decomposition error: %s", e$message), logfile = LOGFILE)
  log_msg("  Skipping Bacon decomposition", logfile = LOGFILE)
})

# =====================================================
# B.7: Size x Treatment interaction test
# =====================================================
log_msg("\n--- 5g: Size x Treatment Interaction ---", logfile = LOGFILE)

# Use simple TWFE with treat_post * large_repo interaction (avoids sunab collinearity)
tryCatch({
  panel_cc_size <- panel_cc %>%
    mutate(
      treat_post = as.integer(is_treatment == 1 & month_id >= first_treat_int),
      large_repo = as.integer(kloc > median(kloc, na.rm = TRUE))
    )

  m_interaction <- feols(
    log_asd ~ treat_post * large_repo | repo_int + month_id,
    data = panel_cc_size, vcov = ~repo_int
  )

  ct <- coeftable(m_interaction)
  log_msg("  Interaction model coefficients:", logfile = LOGFILE)
  for (i in seq_len(nrow(ct))) {
    log_msg(sprintf("    %s: beta=%.4f, SE=%.4f, p=%.4f",
                    rownames(ct)[i], ct[i, 1], ct[i, 2], ct[i, 4]),
            logfile = LOGFILE)
  }

  interaction_row <- grep("treat_post:large_repo", rownames(ct))
  if (length(interaction_row) > 0) {
    int_beta <- ct[interaction_row[1], 1]
    int_se <- ct[interaction_row[1], 2]
    int_pval <- ct[interaction_row[1], 4]
    log_msg(sprintf("  Size x Treatment interaction: beta=%.4f, SE=%.4f, p=%.4f",
                    int_beta, int_se, int_pval), logfile = LOGFILE)
    cat(sprintf("Size x Treatment interaction: beta=%.4f, p=%.4f\n",
                int_beta, int_pval),
        file = SUMMARY_FILE, append = TRUE)
    if (int_pval > ALPHA) {
      log_msg("  -> No significant size heterogeneity", logfile = LOGFILE)
    } else {
      log_msg("  -> Significant size heterogeneity detected", logfile = LOGFILE)
    }
  }
}, error = function(e) {
  log_msg(sprintf("  Size interaction error: %s", e$message), logfile = LOGFILE)
})

log_session("05_robustness")
log_msg("\n=== 05: Complete ===", logfile = LOGFILE)
