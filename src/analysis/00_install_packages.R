# 00_install_packages.R - Bootstrap R environment for Phase 4 analysis
# Run once: Rscript src/analysis/00_install_packages.R
# Or: make install-r

cat("=== Phase 4: Installing R packages ===\n")
cat(sprintf("R version: %s\n", R.version.string))
cat(sprintf("Platform: %s\n", R.version$platform))

# 1. Install renv if needed
if (!requireNamespace("renv", quietly = TRUE)) {
  install.packages("renv", repos = "https://cloud.r-project.org")
}

# 2. Initialize renv (bare = TRUE skips package discovery)
if (!file.exists("renv/activate.R")) {
  renv::init(bare = TRUE)
} else {
  cat("renv already initialized\n")
}

# 3. Use Posit Package Manager for binary packages (avoids compiling C/Fortran)
options(
  repos = c(CRAN = "https://packagemanager.posit.co/cran/latest")
)
# Tell renv to prefer binary
Sys.setenv(RENV_CONFIG_PPM_ENABLED = "TRUE")

# 4. Install packages (individual tidyverse components, not meta-package)
pkgs <- c(
  "dplyr", "tidyr", "readr", "ggplot2", "purrr", "stringr", "forcats", "tibble",
  "here", "yaml", "data.table",
  "fixest", "didimputation", "did", "plm",
  "ggfixest", "patchwork",
  "modelsummary", "kableExtra",
  "broom"
)

cat("Installing packages:", paste(pkgs, collapse = ", "), "\n")

# Try binary install first via install.packages, then fallback to renv
for (pkg in pkgs) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    cat(sprintf("Installing %s...\n", pkg))
    tryCatch({
      install.packages(pkg, type = "binary", repos = "https://cloud.r-project.org",
                       lib = renv::paths$library())
    }, warning = function(w) {
      cat(sprintf("  Binary not available for %s, trying source...\n", pkg))
      tryCatch({
        install.packages(pkg, type = "source", repos = "https://cloud.r-project.org",
                         lib = renv::paths$library())
      }, error = function(e) {
        cat(sprintf("  FAILED to install %s: %s\n", pkg, e$message))
      })
    }, error = function(e) {
      cat(sprintf("  Binary install failed for %s: %s. Trying source...\n", pkg, e$message))
      tryCatch({
        install.packages(pkg, type = "source", repos = "https://cloud.r-project.org",
                         lib = renv::paths$library())
      }, error = function(e2) {
        cat(sprintf("  FAILED to install %s: %s\n", pkg, e2$message))
      })
    })
  } else {
    cat(sprintf("  %s already installed\n", pkg))
  }
}

# 5. Snapshot to create renv.lock
renv::snapshot(prompt = FALSE)

cat("\n=== Package installation complete ===\n")

# 6. Verify key packages load
for (pkg in c("fixest", "didimputation", "did", "here", "dplyr", "ggplot2", "kableExtra")) {
  tryCatch({
    library(pkg, character.only = TRUE)
    cat(sprintf("  %-20s %s OK\n", pkg, packageVersion(pkg)))
  }, error = function(e) {
    cat(sprintf("  %-20s FAILED: %s\n", pkg, e$message))
  })
}
