# 09_tool_heterogeneity.R - Exploratory (post-hoc) tool heterogeneity analyses
# Input:  data/processed/panel_monthly.csv
# Output: data/interim/models/m_tool_*.rds, m_signal_*.rds, m_dose_*.rds
#         results/tables/tab_tool_heterogeneity.tex
#         results/figures/fig_tool_forest.pdf
#
# Analyses:
#   9a. Tool-stratified ATT (claude_code, copilot, cursor)
#   9b. Detection-mode sensitivity (file_add, commit_pattern)
#   9c. Dose-response on total_ai_events (terciles + continuous interaction)

source(here::here("src/analysis/utils/helpers.R"))
suppressPackageStartupMessages({
  library(fixest)
  library(didimputation)
})

set.seed(SEED)
LOGFILE <- file.path(DIR_LOGS, "09_tool_heterogeneity.log")
cat("", file = LOGFILE)

log_msg("=== 09: Tool Heterogeneity (Exploratory) ===", logfile = LOGFILE)

# --- Load data ---
panel <- load_panel()
panel_cc <- panel %>% filter(!is.na(asd))

# Add treat_post for TWFE
panel_cc <- panel_cc %>%
  mutate(treat_post = is_treatment * post)

n_repos <- n_distinct(panel_cc$repo_int)
n_obs   <- nrow(panel_cc)
log_msg(sprintf("Data: %d obs, %d repos", n_obs, n_repos), logfile = LOGFILE)

# Controls subset (reused across all subgroup analyses)
controls <- panel_cc %>% filter(is_treatment == 0)
n_ctrl <- n_distinct(controls$repo_int)
log_msg(sprintf("Controls: %d repos, %d obs", n_ctrl, nrow(controls)), logfile = LOGFILE)

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

# Collect all results for table and figure
results <- list()

# =====================================================
# 9a. Tool-stratified ATT
# =====================================================
log_msg("\n--- 9a: Tool-Stratified ATT ---", logfile = LOGFILE)

tools <- c("claude_code", "copilot", "cursor")

for (tool in tools) {
  # Use grepl to match multi-tool repos (e.g., "aider,claude_code")
  tool_repos <- panel_cc %>%
    filter(is_treatment == 1, grepl(tool, tool_type, fixed = TRUE)) %>%
    pull(repo_int) %>%
    unique()

  n_tool <- length(tool_repos)
  log_msg(sprintf("\n  Tool: %s - %d treatment repos", tool, n_tool), logfile = LOGFILE)

  if (n_tool < 5) {
    log_msg(sprintf("  Skipping %s: too few repos (%d)", tool, n_tool), logfile = LOGFILE)
    next
  }

  sub <- panel_cc %>%
    filter(repo_int %in% tool_repos | is_treatment == 0)

  res <- run_borusyak(sub, "log_asd", sprintf("Tool %s ATT", tool))
  if (res$success) {
    saveRDS(res$model, file.path(DIR_MODELS, sprintf("m_tool_%s.rds", tool)))
    results[[paste0("tool_", tool)]] <- list(
      result  = res$result,
      n_treat = n_tool,
      facet   = "By AI Tool",
      label   = gsub("_", " ", tool)
    )
  }
}

# =====================================================
# 9b. Detection-mode sensitivity
# =====================================================
log_msg("\n--- 9b: Detection-Mode Sensitivity ---", logfile = LOGFILE)

signals <- c("file_add", "commit_pattern")

for (sig in signals) {
  sig_repos <- panel_cc %>%
    filter(is_treatment == 1, adoption_signal == sig) %>%
    pull(repo_int) %>%
    unique()

  n_sig <- length(sig_repos)
  log_msg(sprintf("\n  Signal: %s - %d treatment repos", sig, n_sig), logfile = LOGFILE)

  if (n_sig < 5) {
    log_msg(sprintf("  Skipping %s: too few repos (%d)", sig, n_sig), logfile = LOGFILE)
    next
  }

  sub <- panel_cc %>%
    filter(repo_int %in% sig_repos | is_treatment == 0)

  res <- run_borusyak(sub, "log_asd", sprintf("Signal %s ATT", sig))
  if (res$success) {
    saveRDS(res$model, file.path(DIR_MODELS, sprintf("m_signal_%s.rds", sig)))
    results[[paste0("signal_", sig)]] <- list(
      result  = res$result,
      n_treat = n_sig,
      facet   = "By Detection Mode",
      label   = gsub("_", " ", sig)
    )
  }
}

# =====================================================
# 9c. Dose-response on total_ai_events
# =====================================================
log_msg("\n--- 9c: Dose-Response (total_ai_events) ---", logfile = LOGFILE)

# Compute tercile boundaries on treatment repos
treat_dose <- panel_cc %>%
  filter(is_treatment == 1) %>%
  distinct(repo_int, total_ai_events)

q_tercile <- quantile(treat_dose$total_ai_events, probs = c(1/3, 2/3))
log_msg(sprintf("  Tercile boundaries: low <= %g, medium <= %g, high > %g",
                q_tercile[1], q_tercile[2], q_tercile[2]), logfile = LOGFILE)

# Assign tercile labels
treat_dose <- treat_dose %>%
  mutate(
    dose_tercile = case_when(
      total_ai_events <= q_tercile[1] ~ "low",
      total_ai_events <= q_tercile[2] ~ "medium",
      TRUE                            ~ "high"
    )
  )

log_msg(sprintf("  Tercile counts: low=%d, medium=%d, high=%d",
                sum(treat_dose$dose_tercile == "low"),
                sum(treat_dose$dose_tercile == "medium"),
                sum(treat_dose$dose_tercile == "high")),
        logfile = LOGFILE)

# Run Borusyak for each tercile
for (terc in c("low", "medium", "high")) {
  terc_repos <- treat_dose %>%
    filter(dose_tercile == terc) %>%
    pull(repo_int)

  n_terc <- length(terc_repos)
  log_msg(sprintf("\n  Tercile: %s - %d treatment repos", terc, n_terc), logfile = LOGFILE)

  sub <- panel_cc %>%
    filter(repo_int %in% terc_repos | is_treatment == 0)

  res <- run_borusyak(sub, "log_asd", sprintf("Dose %s ATT", terc))
  if (res$success) {
    saveRDS(res$model, file.path(DIR_MODELS, sprintf("m_dose_%s.rds", terc)))
    results[[paste0("dose_", terc)]] <- list(
      result  = res$result,
      n_treat = n_terc,
      facet   = "By AI Event Intensity",
      label   = terc
    )
  }
}

# Continuous TWFE interaction
log_msg("\n  Continuous dose-response (TWFE interaction):", logfile = LOGFILE)

panel_dose <- panel_cc %>%
  mutate(
    log_dose      = log(total_ai_events + 1),
    dose_interact = treat_post * log_dose
  )

m_dose_cont <- tryCatch({
  feols(
    log_asd ~ treat_post + dose_interact | repo_int + month_id,
    data = panel_dose,
    vcov = ~repo_int
  )
}, error = function(e) {
  log_msg(sprintf("  Dose continuous TWFE error: %s", e$message), logfile = LOGFILE)
  NULL
})

if (!is.null(m_dose_cont)) {
  saveRDS(m_dose_cont, file.path(DIR_MODELS, "m_dose_continuous.rds"))
  ct <- coeftable(m_dose_cont)
  for (v in rownames(ct)) {
    log_msg(sprintf("  %s: beta=%.4f, SE=%.4f, p=%.4f",
                    v, ct[v, 1], ct[v, 2], ct[v, 4]),
            logfile = LOGFILE)
  }
  # Report dose_interact specifically
  di_beta <- ct["dose_interact", 1]
  di_se   <- ct["dose_interact", 2]
  di_pval <- ct["dose_interact", 4]
  log_msg(sprintf("  Dose interaction: 1-SD increase in log(events) -> %.1f%% change in ASD (p=%.4f)",
                  pct_effect(di_beta), di_pval), logfile = LOGFILE)
}

# =====================================================
# Forest Plot: fig_tool_forest.pdf
# =====================================================
log_msg("\n--- Forest Plot ---", logfile = LOGFILE)

# Load pooled estimate
pooled_model <- readRDS(file.path(DIR_MODELS, "m_borusyak_static.rds"))
pooled_r     <- extract_did_imp(pooled_model)

# Build data frame for plotting
plot_rows <- list()
for (nm in names(results)) {
  r <- results[[nm]]$result
  plot_rows[[nm]] <- tibble(
    name      = nm,
    label     = results[[nm]]$label,
    facet     = results[[nm]]$facet,
    n_treat   = results[[nm]]$n_treat,
    beta      = r$beta,
    se        = r$se,
    ci_lo     = r$ci_lo,
    ci_hi     = r$ci_hi,
    pval      = r$pval,
    pct       = pct_effect(r$beta),
    pct_lo    = pct_effect(r$ci_lo),
    pct_hi    = pct_effect(r$ci_hi)
  )
}

if (length(plot_rows) == 0) {
  log_msg("WARNING: No successful results for forest plot", logfile = LOGFILE)
} else {
  df_plot <- bind_rows(plot_rows)

  # Order facets and labels
  df_plot <- df_plot %>%
    mutate(
      facet = factor(facet, levels = c("By AI Tool", "By Detection Mode",
                                       "By AI Event Intensity")),
      display = sprintf("%s (n=%d)", label, n_treat),
      display = fct_reorder(display, as.numeric(facet) * 100 + row_number())
    )

  # Pooled reference in percentage terms
  pooled_pct <- pct_effect(pooled_r$beta)

  # Assign colors by facet
  facet_colors <- c("By AI Tool" = "#2166AC",
                    "By Detection Mode" = "#4DAF4A",
                    "By AI Event Intensity" = "#FF7F00")

  p <- ggplot(df_plot, aes(x = pct, y = display, color = facet)) +
    geom_vline(xintercept = 0, linetype = "dashed", color = "grey50") +
    geom_vline(xintercept = pooled_pct, linetype = "dotted", color = "grey30",
               linewidth = 0.6) +
    geom_errorbarh(aes(xmin = pct_lo, xmax = pct_hi), height = 0.25,
                   linewidth = 0.7) +
    geom_point(size = 3) +
    facet_grid(facet ~ ., scales = "free_y", space = "free_y") +
    scale_color_manual(values = facet_colors, guide = "none") +
    labs(
      x = "Effect on ASD (%)",
      y = NULL,
      title = "Heterogeneous treatment effects by AI tool, detection mode, and intensity",
      caption = sprintf("Dotted line: pooled ATT = %.1f%%. Exploratory (post-hoc).", pooled_pct)
    ) +
    theme_paper() +
    theme(
      strip.text.y = element_text(angle = 0),
      plot.caption = element_text(size = 8, hjust = 0)
    )

  save_fig(p, "fig_tool_forest.pdf", w = 7, h = 5)
  log_msg("Saved: fig_tool_forest.pdf", logfile = LOGFILE)
}

# =====================================================
# LaTeX Table: tab_tool_heterogeneity.tex
# =====================================================
log_msg("\n--- Generating tab_tool_heterogeneity.tex ---", logfile = LOGFILE)

stars_fn <- function(pval) {
  ifelse(pval < 0.01, "***",
  ifelse(pval < 0.05, "**",
  ifelse(pval < 0.1,  "*", "")))
}

fmt_row <- function(label, r, n_t) {
  if (is.null(r)) return(NULL)
  stars <- stars_fn(r$pval)
  sprintf("%s & %d & %.4f%s & %.4f & [%.4f, %.4f] & %.4f & %.1f\\%% \\\\",
          label, n_t, r$beta, stars, r$se, r$ci_lo, r$ci_hi, r$pval,
          pct_effect(r$beta))
}

# Build rows
tex_rows <- list()

# Section: By AI tool
tex_rows <- c(tex_rows, list(
  "\\midrule",
  "\\multicolumn{7}{l}{\\textit{By AI tool}} \\\\"
))
for (tool in tools) {
  key <- paste0("tool_", tool)
  if (!is.null(results[[key]])) {
    tex_rows <- c(tex_rows, list(fmt_row(
      gsub("_", " ", tool),
      results[[key]]$result,
      results[[key]]$n_treat
    )))
  }
}

# Section: By detection mode
tex_rows <- c(tex_rows, list(
  "\\midrule",
  "\\multicolumn{7}{l}{\\textit{By detection mode}} \\\\"
))
for (sig in signals) {
  key <- paste0("signal_", sig)
  if (!is.null(results[[key]])) {
    tex_rows <- c(tex_rows, list(fmt_row(
      gsub("_", " ", sig),
      results[[key]]$result,
      results[[key]]$n_treat
    )))
  }
}

# Section: By AI event intensity
tex_rows <- c(tex_rows, list(
  "\\midrule",
  "\\multicolumn{7}{l}{\\textit{By AI event intensity (terciles)}} \\\\"
))
for (terc in c("low", "medium", "high")) {
  key <- paste0("dose_", terc)
  if (!is.null(results[[key]])) {
    tex_rows <- c(tex_rows, list(fmt_row(
      paste0(terc, " intensity"),
      results[[key]]$result,
      results[[key]]$n_treat
    )))
  }
}

# Continuous interaction row
if (!is.null(m_dose_cont)) {
  ct <- coeftable(m_dose_cont)
  di_beta <- ct["dose_interact", 1]
  di_se   <- ct["dose_interact", 2]
  di_pval <- ct["dose_interact", 4]
  di_ci_lo <- di_beta - qnorm(0.975) * di_se
  di_ci_hi <- di_beta + qnorm(0.975) * di_se
  n_treat_all <- n_distinct(panel_cc %>% filter(is_treatment == 1) %>% pull(repo_int))
  stars_di <- stars_fn(di_pval)
  tex_rows <- c(tex_rows, list(
    sprintf("log(events) $\\times$ post & %d & %.4f%s & %.4f & [%.4f, %.4f] & %.4f & %.1f\\%% \\\\",
            n_treat_all, di_beta, stars_di, di_se, di_ci_lo, di_ci_hi, di_pval,
            pct_effect(di_beta))
  ))
}

tex <- c(
  "\\begin{table}[t]",
  "\\centering",
  "\\caption{Exploratory heterogeneity: treatment effects by AI tool, detection mode, and AI event intensity.}",
  "\\label{tab:tool_heterogeneity}",
  "\\begin{tabular}{lrccccc}",
  "\\toprule",
  "Subgroup & $N_T$ & ATT ($\\hat{\\beta}$) & SE & 95\\% CI & $p$-value & Effect (\\%) \\\\",
  unlist(Filter(Negate(is.null), tex_rows)),
  "\\bottomrule",
  "\\multicolumn{7}{l}{\\footnotesize $^{*}p<0.1$; $^{**}p<0.05$; $^{***}p<0.01$. Borusyak imputation estimator.} \\\\",
  "\\multicolumn{7}{l}{\\footnotesize Exploratory (post-hoc). Small subgroups limit power. $N_T$ = treatment repos.} \\\\",
  "\\end{tabular}",
  "\\end{table}"
)

writeLines(tex, file.path(DIR_TABLES, "tab_tool_heterogeneity.tex"))
log_msg("Saved: tab_tool_heterogeneity.tex", logfile = LOGFILE)

# =====================================================
# Final summary
# =====================================================
log_msg("\n=== INTERPRETATION SUMMARY ===", logfile = LOGFILE)

for (nm in names(results)) {
  r <- results[[nm]]$result
  sig_label <- if (r$pval < 0.05) "SIGNIFICANT" else if (r$pval < 0.1) "MARGINAL" else "n.s."
  log_msg(sprintf("  %s: %.1f%% (%s, p=%.4f, n_t=%d)",
                  nm, pct_effect(r$beta), sig_label, r$pval, results[[nm]]$n_treat),
          logfile = LOGFILE)
}

if (!is.null(m_dose_cont)) {
  ct <- coeftable(m_dose_cont)
  di_p <- ct["dose_interact", 4]
  log_msg(sprintf("  dose_continuous: interaction p=%.4f (%s)",
                  di_p, if (di_p < 0.05) "dose-dependent" else "no dose-response"),
          logfile = LOGFILE)
}

log_msg("\n=== 09: Complete ===", logfile = LOGFILE)
