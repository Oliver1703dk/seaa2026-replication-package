# Replication Package: Vibe Coding Meets Architecture

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.20510048.svg)](https://doi.org/10.5281/zenodo.20510048)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Replication package for "Vibe Coding Meets Architecture: A Causal Study of
Agentic AI in Java Repositories", accepted at the SEAA 2026 STREAM Track.

## Study summary

Staggered difference-in-differences mining study measuring whether
observable agentic AI tool adoption changes architectural smell
density (ASD) in open-source Java repositories. The analysis sample
is 151 Java repositories (74 with detectable agentic AI adoption via
configuration files or `Co-Authored-By` commit trailers, 77
propensity-matched controls), drawn from 90 matched pairs after
excluding 24 repositories with zero successful Arcan snapshots.
Monthly ASD is measured via Arcan over a 13-month window (6 pre +
adoption month + 6 post), yielding 1,811 successful snapshots.
Primary estimator: Borusyak et al. (2024) imputation DiD. Finding:
the 6.7% ASD decline post-adoption is a denominator effect; raw smell
counts are essentially unchanged (+1.1%, p=0.82) while LOC grows
+12.8% (p=0.003). Agentic AI tools are architecturally neutral, not
protective.

## Quick start: reproduce all statistical results

### Requirements

- R >= 4.2 (renv.lock pins package versions; the lock records R 4.2.1)
- Python >= 3.11, < 3.13 with [uv](https://docs.astral.sh/uv/) (a few helper
  steps and the `tests/` smoke test use Python)

The Docker path (`open-science/INSTALL.md`, Option A) bundles both and is the
most reproducible way to run this.

### Steps

```bash
# 1. Restore R package versions
Rscript -e 'renv::restore()'

# 2. Run the analysis pipeline against the shipped frozen data
make analyze
```

This executes R scripts 01-11 in order and regenerates all figures in
`results/figures/` and all tables in `results/tables/`. It reads only the
frozen datasets shipped in `data/processed/`; no GitHub token or repo cloning
is needed.

Alternatively, run scripts individually:

```bash
Rscript src/analysis/01_descriptive_stats.R
Rscript src/analysis/02_main_did.R
Rscript src/analysis/03_disaggregated_did.R
Rscript src/analysis/04_event_study.R
Rscript src/analysis/05_robustness.R
Rscript src/analysis/06_tables.R
Rscript src/analysis/07_figures.R
Rscript src/analysis/08_supplementary.R
Rscript src/analysis/09_tool_heterogeneity.R
Rscript src/analysis/10_decomposition_figure.R
Rscript src/analysis/11_secondary_metrics.R
```

`src/analysis/12_control_contamination.py` is part of the full mining/extraction
pipeline (it scans the bare clones in `repos/`, which are not shipped), so it is
NOT part of `make analyze`. Run after a full-pipeline build only.

Two additional sensitivity scripts can be run manually (they emit only log files
under `results/logs/` and do not feed any paper table or figure):

```bash
Rscript src/analysis/10_container_only_sensitivity.R
Rscript src/analysis/12_module_growth.R
```

## Output mapping

### Figures and tables in the paper

| Paper element | Label | Script | Output file |
|---------------|-------|--------|-------------|
| Table (Main DiD) | `tab:main_did` | 06_tables.R | `results/tables/tab_main_did.tex` |
| Table (Supplementary) | `tab:supplementary` | 08_supplementary.R | `results/tables/tab_supplementary.tex` |
| Figure (Forest plot, RQ2) | `fig:rq2_forest_plot` | 07_figures.R | `results/figures/fig_rq2_forest_plot.pdf` |
| Figure (Event study, RQ3) | `fig:rq3_event_study` | 07_figures.R | `results/figures/fig_rq3_event_study.pdf` |
| Figure (Decomposition) | `fig:decomposition_panels` | 10_decomposition_figure.R | `results/figures/fig_decomposition_panels.pdf` |

### Supplementary outputs (in package, not in paper)

| Output file | Script | Description |
|-------------|--------|-------------|
| `tab_descriptive.tex` | 01_descriptive_stats.R | Sample descriptive statistics |
| `tab_attrition.tex` | 01_descriptive_stats.R | Attrition analysis |
| `tab_disaggregated.tex` | 06_tables.R | Per-smell-type DiD estimates |
| `tab_robustness.tex` | 06_tables.R | Alternative estimators |
| `tab_size_stratified.tex` | 06_tables.R | Effects by repo size |
| `tab_combined_results.tex` | 06_tables.R | All estimators combined |
| `tab_tool_heterogeneity.tex` | 09_tool_heterogeneity.R | Effects by AI tool type |
| `fig_distributions.pdf` | 01_descriptive_stats.R | ASD and covariate distributions |
| `fig_placebo.pdf` | 07_figures.R | Placebo event study |
| `fig_size_event_study.pdf` | 07_figures.R | Event study by repo size |
| `fig_tool_forest.pdf` | 09_tool_heterogeneity.R | Forest plot by AI tool |
| `fig_balance_love_plot.pdf` | (matching phase) | Covariate balance love plot |

## Repository structure

```
config/
  config.yaml                  Study parameters: seeds, thresholds, estimators
  repo_lists/
    treatment_final.csv        90 treatment repos with adoption metadata
                               (74 retained after Arcan attrition; 16 dropped
                               with zero successful snapshots)

data/
  processed/
    panel_monthly.csv          Main panel dataset (2,241 repo-months, 33 vars;
                               1,811 with successful Arcan output, 151 repos)
    panel_monthly_container_only.csv  Sensitivity: container-level smells only
    matching.csv               90 matched treatment-control pairs
                               (analysis retains 74T + 77C = 151 after attrition)
    repo_characteristics.csv   Covariates for all 670 candidate repos
  interim/
    snapshot_manifest.csv      Monthly snapshot-to-commit mapping
    parsed_smells_summary.csv  Arcan smell counts per repo-month
    graph_metrics_summary.csv  Coupling metrics per repo-month
    arcan_status.csv           Arcan run success/failure log
    control_contamination.csv  AI contamination check on controls
    models/                    Empty; R scripts write model objects here

src/
  analysis/   R scripts (01-12) for all statistical analyses
  mining/     Python scripts for GitHub repo identification
  matching/   Python scripts for propensity score matching
  extraction/ Python/Shell scripts for Arcan parsing and panel assembly

results/
  figures/    Pre-computed PDF figures (analysis figures regenerated by make
              analyze; fig_balance_love_plot.pdf comes from the matching phase)
  tables/     Pre-computed LaTeX tables (regenerated by make analyze)
  logs/       Analysis summary and software versions
```

## Key variables in panel_monthly.csv

| Variable | Description |
|----------|-------------|
| `repo_id` | Numeric repo identifier |
| `repo_name` | GitHub repo (owner/name) |
| `month` | Calendar month (YYYY-MM) |
| `month_id` | Numeric month index |
| `is_treatment` | 1 = adopted AI tool, 0 = control |
| `first_treat_month` | Month of first AI tool detection. For controls (`is_treatment=0`), set to the matched treatment partner's adoption month to define a common event window; controls are never-treated. |
| `post` | 1 = post-adoption period |
| `time_to_event` | Months relative to adoption (-6 to +6) |
| `cd_count` | Cyclic dependency smell count |
| `ud_count` | Unstable dependency smell count |
| `hl_count` | Hub-like dependency smell count |
| `gc_count` | God component smell count |
| `total_smells` | Sum of all smell counts |
| `num_packages` | Number of Java packages |
| `loc`, `kloc` | Lines of code (absolute and thousands) |
| `asd` | Architectural smell density (smells / KLOC) |
| `cd_density`, `ud_density`, `hl_density`, `gc_density` | Per-KLOC density by type |
| `ce_mean`, `ca_mean` | Mean efferent/afferent coupling |
| `instability_mean` | Mean instability I = Ce/(Ca+Ce) |
| `distance_mean` | Mean distance from main sequence |
| `modularity_q` | Modularity (NaN: unavailable from Arcan CSV) |
| `monthly_commits` | Commits in that month |
| `monthly_contributors` | Unique contributors in that month |
| `stars` | GitHub stars (time-invariant) |
| `repo_age_months` | Repo age at study start |
| `tool_type` | AI tool: copilot, cursor, claude_code, aider, codex; comma-joined when multiple tools are detected (e.g. `aider,claude_code`) |
| `adoption_signal` | Detection method: file_add or commit_pattern |
| `total_ai_events` | Total detected AI signals |

## Full pipeline reproduction

Reproducing the complete pipeline (mining through extraction) requires
additional setup beyond what is needed for analysis reproduction:

- Python >= 3.11 with [uv](https://docs.astral.sh/uv/)
- Docker (for Arcan architectural analysis)
- GitHub API token with public repo access
- ~40 GB disk space for repository clones
- ~20 hours compute time for Arcan analysis across all snapshots

See `open-science/INSTALL.md` for detailed instructions.

The frozen datasets in `data/processed/` guarantee exact reproduction of
all statistical results independent of whether the full pipeline is
re-run. GitHub API results may vary over time as repositories evolve.

## How to cite

If you use this replication package, please cite both the paper and the archive.
Citation metadata is in [`CITATION.cff`](CITATION.cff) (GitHub renders a "Cite
this repository" button from it).

> Larsen, O. A., & Moghaddam, M. T. (2026). *Vibe Coding Meets Architecture: A
> Causal Study of Agentic AI in Java Repositories.* In Proceedings of the 2026
> Euromicro Conference on Software Engineering and Advanced Applications
> (SEAA 2026), STREAM Track.

Archived replication package: **DOI [10.5281/zenodo.20510048](https://doi.org/10.5281/zenodo.20510048)**

## License

Source code is licensed under the **MIT License** ([LICENSE](LICENSE)). The data
in `data/` is licensed under **CC BY 4.0** ([DATA-LICENSE.txt](DATA-LICENSE.txt)).
