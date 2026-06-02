# Artifact Abstract

## Paper Title
Vibe Coding Meets Architecture: A Causal Study of Agentic AI in Java
Repositories

## Artifact Summary

This artifact provides the complete replication package for our SEAA
2026 STREAM Track paper studying whether observable agentic AI tool
adoption changes architectural quality in open-source Java
repositories.

### Contents

| Component | Description | Location |
|-----------|-------------|----------|
| Mining scripts | GitHub API queries for treatment/control repos | `src/mining/` |
| Matching scripts | Propensity score matching pipeline | `src/matching/` |
| Extraction scripts | Monthly snapshot extraction + Arcan analysis | `src/extraction/` |
| Analysis scripts | Diff-in-diff estimation, tables, figures | `src/analysis/` |
| Panel dataset | 2,241 repo-month observations (1,811 with complete metrics) across 151 analysis repos (74 treatment, 77 control) | `data/processed/panel_monthly.csv` |
| Configuration | All parameters, repo lists, thresholds | `config/` |
| Docker environment | Reproducible execution environment | `docker/` |
| R lockfile | 148 R packages pinned | `renv.lock` |
| Python lockfile | 134 Python packages pinned | `uv.lock` |
| Paper source | Full LaTeX source | *(submitted separately)* |

### Claims Supported

The artifact supports reproduction of all paper claims:

1. **RQ1 (Main effect):** Observable agentic AI adoption is associated
   with a 6.7% decrease in architectural smell density (Borusyak ATT =
   -0.070, p=0.004). Concordant with TWFE-SA (ATT = -0.068, p=0.005).
2. **RQ2 (By smell type):** Hub-Like Dependency density decreases (-5.0%,
   Holm-adjusted p=0.003). Cyclic Dependency is marginal after Holm
   correction (raw p=0.023, adjusted p=0.070). Unstable Dependency and
   God Component show null effects.
3. **RQ3 (Dynamic effects):** The effect grows monotonically from 0%
   at adoption to -9.5% at 6 months post-adoption. Pre-trend Wald test
   (p=0.896) validates the parallel trends assumption.
4. **Decomposition:** The ASD decrease is a denominator artifact: raw
   smell counts are unchanged (+1.1%, p=0.82) while LOC grows 12.8%
   (p=0.003). Agentic AI tools are architecturally neutral, not
   protective.
5. **Robustness:** Results are robust to covariate adjustment (TWFE-SA
   + monthly_contributors: -0.068, p=0.004), wild cluster bootstrap
   (p=0.010), and Lee attrition bounds ([-9.9%, -2.3%]). C&S diverges
   (specification sensitivity). Multi-event sensitivity (excluding 22
   single-event repos) confirms the result (-0.071, p=0.020).

### Badges Targeted

- [x] **Publicly Shared:** Zenodo archive with DOI
- [x] **Verified Execution:** Docker-based reproduction with documented steps
- [x] **Documented & Functional:** INSTALL.md with prerequisites and commands
- [x] **Reproducible Results:** `make analyze` reproduces all figures/tables
- [x] **Reusable:** Modular pipeline, config-driven, documented API

## How to Use

### Quick reproduction (5 minutes):
```bash
cd docker && docker-compose run --rm analyze
```

### Full pipeline (24 hours):
```bash
export GITHUB_TOKEN=your_token
cd docker && docker-compose run --rm pipeline-full
```

See `open-science/INSTALL.md` for detailed instructions.

## Requirements

- Docker Desktop >= 24.0
- 2 GB disk (analysis only) or 50 GB (full pipeline)
- GitHub PAT (full pipeline only)
