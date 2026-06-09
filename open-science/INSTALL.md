# Installation & Reproduction Guide

## Overview

This artifact accompanies the paper "Mining Architectural Quality Under
Agentic AI Adoption: A Causal Study of Java Repositories"
(SEAA 2026 STREAM Track).

It supports reproduction of all four research questions:
- **RQ1:** Overall architectural smell density (ASD) change after agentic AI tool adoption
- **RQ2:** Disaggregated effects by smell type (CD, HL, UD, GC)
- **RQ3:** Dynamic treatment effects over time (event study)
- **RQ4:** Denominator decomposition of the ASD effect (raw smell counts vs. LOC)

## Prerequisites

| Requirement | Version | Notes |
|------------|---------|-------|
| Docker Desktop | >= 24.0 | Enable Rosetta on Apple Silicon |
| Disk space | >= 50 GB | For full pipeline (repos + Arcan output) |
| Disk space | >= 2 GB | For analysis-only reproduction |
| GitHub PAT | -- | Only for Phase 1 (mining). Not needed for analysis-only. |
| Wall-clock time | ~24 hours | Full pipeline. Phase 3 (Arcan) dominates. |
| Wall-clock time | ~5 minutes | Analysis-only reproduction. |

## Option A: Reproduce Analysis Only (Recommended)

This reproduces all statistical results, figures, and tables from the
pre-built panel dataset. No GitHub token or repo cloning required.

The frozen panel dataset is already included in this package under
`data/processed/`, so no separate download is needed when running from the
cloned repository or the Zenodo archive. (The same archive is published at
Zenodo DOI [10.5281/zenodo.20510048](https://doi.org/10.5281/zenodo.20510048).)

```bash
# 1. Run the analysis (reads the shipped data/processed/panel_monthly.csv)
cd docker
docker-compose run --rm analyze

# 2. Check outputs
ls ../results/figures/   # PDF figures
ls ../results/tables/    # LaTeX tables
cat ../results/logs/analysis_summary.txt  # Key estimates
```

### Expected Key Outputs

| Output | Path | Description |
|--------|------|-------------|
| Main DiD table | `results/tables/tab_main_did.tex` | RQ1: Borusyak + TWFE-SA estimates |
| Disaggregated table | `results/tables/tab_disaggregated.tex` | RQ2: Per-smell-type effects with Holm correction |
| Event study figure | `results/figures/fig_rq3_event_study.pdf` | RQ3: Dynamic effects with SA overlay |
| Decomposition figure | `results/figures/fig_decomposition_panels.pdf` | Key finding: ASD vs LOC decomposition |
| Forest plot | `results/figures/fig_rq2_forest_plot.pdf` | RQ2: Visual comparison |
| Combined results | `results/tables/tab_combined_results.tex` | All estimators in one table |
| Summary | `results/logs/analysis_summary.txt` | All point estimates, SEs, p-values |

### Expected Key Results

| Estimate | Value | Interpretation |
|----------|-------|----------------|
| Borusyak ATT (log ASD) | -0.070 (p=0.004) | -6.7% ASD reduction |
| TWFE-SA ATT (log ASD) | -0.068 (p=0.005) | -6.6% ASD reduction (concordance) |
| Pre-trend Wald p-value | 0.896 | Parallel trends hold |
| Raw smells ATT | +0.011 (p=0.82) | No change in absolute smells |
| LOC growth ATT | +0.120 (p=0.003) | +12.8% code growth (denominator effect) |

## Option B: Full Pipeline Reproduction

Reproduces the entire study from GitHub mining through analysis.

**Warning:** This requires a GitHub Personal Access Token, ~50 GB disk space,
and ~24 hours of compute time. Phase 3 (Arcan analysis) is CPU-intensive.

```bash
# 1. Set your GitHub token
export GITHUB_TOKEN=your_token_here

# 2. Run full pipeline
cd docker
docker-compose run --rm pipeline-full

# Alternatively, run individual phases:
# docker-compose run --rm pipeline-full make mine      # Phase 1: ~4h
# docker-compose run --rm pipeline-full make match     # Phase 2: ~5 min
# docker-compose run --rm pipeline-full make extract   # Phase 3: ~18h
# docker-compose run --rm pipeline-full make analyze   # Phase 4: ~5 min
```

**Note on Phase 3 (Extraction):** Arcan runs as a Docker container inside
the pipeline container (Docker-in-Docker via socket mount). On Apple Silicon
Macs, enable Rosetta in Docker Desktop settings for ~5x speedup over QEMU
emulation.

## Running Without Docker

```bash
# Python setup
uv sync --frozen

# R setup
Rscript -e "renv::restore()"

# Run analysis
make analyze

# Run full pipeline (requires GITHUB_TOKEN)
make all
```

(The paper LaTeX source is not part of this replication package; it is
submitted separately.)

## Arcan Trial License

This study uses the Arcan 2 CLI trial edition for architectural smell detection.

1. **Docker image:** `ghcr.io/arcan-tech/arcan-2-cli-trial` (SHA256 digest pinned in `config/config.yaml`).
2. The trial edition detects all four smell types used in this study: Cyclic Dependency (CD), Unstable Dependency (UD), Hub-Like Dependency (HL), and God Component (GC).
3. **Pre-computed outputs:** The raw per-snapshot Arcan CSVs (`data/raw/arcan_output/`) are NOT shipped (size). Their parsed, analysis-ready summaries ARE included under `data/interim/` (`parsed_smells_summary.csv`, `graph_metrics_summary.csv`, `arcan_status.csv`), and the assembled `data/processed/panel_monthly.csv` is the frozen input that guarantees exact reproduction of all results without running Arcan.
4. To obtain the trial: pull the Docker image from `ghcr.io/arcan-tech/arcan-2-cli-trial`. No registration required.

## Software Versions

See `results/logs/software_versions.txt` for exact versions used in our analysis.

Key versions:
- Python >=3.11,<3.13 (the Docker image uses Python 3.12; the original analysis
  was run on 3.13.5, but the pinned `requires-python` is `>=3.11,<3.13`)
- R 4.2+ with fixest 0.11.2, didimputation 0.3.0, did 2.1.2 (renv.lock records
  R 4.2.1; restoring under a newer R 4.x minor may emit a version-mismatch
  warning, which is expected and safe)
- Arcan 2 CLI (Docker image digest in config/config.yaml)
- See `uv.lock` for Python package versions
- See `renv.lock` for R package versions

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `renv::restore()` fails | Run `Rscript -e "renv::repair()"` then retry |
| Arcan OOM on large repos | Increase Docker memory limit to 8 GB |
| `uv sync --frozen` fails | Run `uv lock` to regenerate lockfile, then `uv sync --frozen` |
| Phase 3 hangs | Arcan JVM can hang at < 6 GB memory. Increase Docker memory. |
| Apple Silicon slow | Enable Rosetta in Docker Desktop > Settings > General |

## Directory Structure

```
.
├── config/              # Configuration (config.yaml, repo lists)
├── data/
│   ├── interim/         # Parsed Arcan summaries, snapshot manifest, models/
│   └── processed/       # Analysis-ready frozen data (panel_monthly.csv, matching.csv, ...)
│                        # (data/raw/ is NOT shipped; regenerate via the full pipeline)
├── docker/              # Dockerfile, docker-compose.yml
├── open-science/        # This file (INSTALL), artifact_abstract.md
├── tests/               # Smoke tests for the shipped panel (pytest)
├── results/
│   ├── figures/         # PDF figures
│   ├── tables/          # LaTeX tables
│   └── logs/            # Execution logs, analysis summary, software versions
├── src/
│   ├── mining/          # Phase 1: GitHub mining scripts
│   ├── matching/        # Phase 2: Propensity score matching
│   ├── extraction/      # Phase 3: Snapshot extraction + Arcan
│   └── analysis/        # Phase 4: R analysis scripts (01-12) + utils
├── CITATION.cff         # Citation metadata
├── .zenodo.json         # Zenodo archive metadata
├── LICENSE              # MIT (source code)
├── DATA-LICENSE.txt     # CC BY 4.0 (data in data/)
├── Makefile             # Pipeline orchestration
├── pyproject.toml       # Python project config
├── uv.lock              # Python dependency lockfile
├── renv.lock            # R dependency lockfile
└── renv/                # renv bootstrap (activate.R, settings.json)
```
(The paper LaTeX source is submitted separately and is not part of this package.)

## Data Availability

Repository names in `panel_monthly.csv` are real GitHub repository identifiers
(e.g., `owner/repo`). These are publicly available open-source projects.
No personal data is collected. See the paper's Data Availability statement
for the Zenodo archive link.
