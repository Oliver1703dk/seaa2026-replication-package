# helpers.R - Shared utilities for Phase 4 analysis scripts
# Sourced by all scripts: source(here::here("src/analysis/utils/helpers.R"))

# --- renv restore check ---
if (file.exists(here::here("renv.lock")) && !identical(Sys.getenv("RENV_RESTORED"), "1")) {
  message("Checking renv packages...")
  tryCatch(renv::restore(prompt = FALSE), error = function(e) message("renv::restore skipped: ", e$message))
  Sys.setenv(RENV_RESTORED = "1")
}

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(tidyr)
  library(readr)
  library(ggplot2)
  library(purrr)
  library(stringr)
  library(forcats)
  library(yaml)
})

# --- Config ---
cfg <- yaml::read_yaml(here("config/config.yaml"))
SEED <- cfg$study$seed  # 42
ALPHA <- cfg$analysis$alpha  # 0.05

# --- Paths ---
DIR_MODELS  <- here("data/interim/models")
DIR_FIGURES <- here("results/figures")
DIR_TABLES  <- here("results/tables")
DIR_LOGS    <- here("results/logs")
SUMMARY_FILE <- file.path(DIR_LOGS, "analysis_summary.txt")

# --- Conversion helpers ---
month_str_to_id <- function(s) {
  parts <- strsplit(as.character(s), "-")
  sapply(parts, function(p) as.integer(p[1]) * 12L + as.integer(p[2]))
}

id_to_month_str <- function(id) {
  yr <- (id - 1) %/% 12
  mo <- (id - 1) %% 12 + 1
  sprintf("%04d-%02d", yr, mo)
}

# --- Data Loading ---
load_panel <- function() {
  panel <- read_csv(here("data/processed/panel_monthly.csv"), show_col_types = FALSE)

  panel <- panel %>%
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
      log_kloc = log(kloc + 1)
    )

  return(panel)
}

# --- Effect size ---
pct_effect <- function(beta) 100 * (exp(beta) - 1)

# --- Plotting theme ---
theme_paper <- function(base_size = 11) {
  theme_minimal(base_size = base_size) +
    theme(
      panel.grid.minor = element_blank(),
      legend.position = "bottom",
      plot.title = element_text(size = base_size + 1, face = "bold"),
      axis.title = element_text(size = base_size - 1),
      strip.text = element_text(face = "bold")
    )
}

save_fig <- function(p, name, w = 7, h = 5) {
  path <- file.path(DIR_FIGURES, name)
  ggsave(path, p, width = w, height = h, device = "pdf")
  cat("Saved figure:", path, "\n")
}

# --- Logging ---
log_msg <- function(..., logfile = NULL) {
  msg <- paste0(...)
  cat(msg, "\n")
  if (!is.null(logfile)) cat(msg, "\n", file = logfile, append = TRUE)
}

log_result <- function(label, beta, se, ci_lo, ci_hi, pval, n_obs, n_units) {
  line <- sprintf(
    "%s: beta=%.4f, SE=%.4f, 95%%CI=[%.4f, %.4f], p=%.4f, effect=%.1f%%, N=%d obs (%d repos)",
    label, beta, se, ci_lo, ci_hi, pval, pct_effect(beta), as.integer(n_obs), as.integer(n_units)
  )
  cat(line, "\n")
  cat(line, "\n", file = SUMMARY_FILE, append = TRUE)
}

# --- Extract results from did_imputation objects ---
# did_imputation() returns a tibble with columns: lhs, term, estimate, std.error, conf.low, conf.high
# No p.value column - compute from z-statistic
extract_did_imp <- function(m, row = 1) {
  beta  <- m$estimate[row]
  se    <- m$std.error[row]
  ci_lo <- m$conf.low[row]
  ci_hi <- m$conf.high[row]
  pval  <- 2 * pnorm(-abs(beta / se))
  list(beta = beta, se = se, ci_lo = ci_lo, ci_hi = ci_hi, pval = pval)
}

# --- Session info logging (D.8) ---
log_session <- function(script_name) {
  si_file <- file.path(DIR_LOGS, paste0(script_name, "_sessionInfo.txt"))
  writeLines(capture.output(sessionInfo()), si_file)
}
