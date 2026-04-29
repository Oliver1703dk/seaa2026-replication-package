.PHONY: all mine match extract analyze paper clean help

PYTHON := uv run python
RSCRIPT := Rscript

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

all: mine match extract analyze ## Run full pipeline

# Phase 1: Mining
mine: ## Mine GitHub for treatment & control repositories
	$(PYTHON) src/mining/01_search_treatment_repos.py
	$(PYTHON) src/mining/02_collect_repo_metadata.py
	$(PYTHON) src/mining/03_detect_adoption_date.py
	$(PYTHON) src/mining/04_search_control_candidates.py
	$(PYTHON) src/mining/04b_supplement_controls.py
	bash src/mining/05_clone_repos.sh

# Phase 2: Matching
match: ## Propensity score matching
	$(PYTHON) src/matching/01_compute_covariates.py
	$(PYTHON) src/matching/02_propensity_score.py
	$(PYTHON) src/matching/03_assess_balance.py

# Phase 3: Extraction + Arcan
extract: ## Extract monthly snapshots & run Arcan analysis
	bash src/extraction/00_clone_missing_controls.sh
	bash src/extraction/01_extract_snapshots.sh
	bash src/extraction/02_run_arcan.sh
	$(PYTHON) src/extraction/03_parse_arcan_output.py
	$(PYTHON) src/extraction/04_compute_metrics.py
	$(PYTHON) src/extraction/05_build_panel.py

# Phase 4: Statistical analysis
analyze: ## Run diff-in-diff analysis & generate results
	$(RSCRIPT) src/analysis/01_descriptive_stats.R
	$(RSCRIPT) src/analysis/02_main_did.R
	$(RSCRIPT) src/analysis/03_disaggregated_did.R
	$(RSCRIPT) src/analysis/04_event_study.R
	$(RSCRIPT) src/analysis/05_robustness.R
	$(RSCRIPT) src/analysis/06_tables.R
	$(RSCRIPT) src/analysis/07_figures.R
	$(RSCRIPT) src/analysis/08_supplementary.R
	$(RSCRIPT) src/analysis/09_tool_heterogeneity.R
	$(RSCRIPT) src/analysis/10_decomposition_figure.R
	$(RSCRIPT) src/analysis/11_secondary_metrics.R
	$(PYTHON) src/analysis/12_control_contamination.py

# Paper
paper: ## Compile LaTeX paper
	cd paper && latexmk -pdf main.tex

# Utilities
clean: ## Remove generated outputs (keeps raw data)
	rm -rf results/figures/*.pdf results/figures/*.png
	rm -rf results/tables/*.tex
	rm -rf results/logs/*.log
	rm -rf data/interim/parsed_smells/*.csv
	rm -rf data/interim/graph_metrics/*.csv
	rm -rf data/processed/*.csv

install-r: ## Install R packages via renv
	$(RSCRIPT) src/analysis/00_install_packages.R

install-python: ## Install Python dependencies
	uv sync
