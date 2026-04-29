"""Assess covariate balance before and after propensity score matching.

Produces:
  - Love plot (PDF): visual comparison of |SMD| before/after matching
  - Balance table (LaTeX): for the paper
  - Console summary of balance diagnostics
"""

import csv
import logging
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import yaml  # noqa: E402

PROJECT_ROOT = Path(__file__).resolve().parents[2]

COVARIATES = ["stars", "size_kb", "forks", "num_commits", "num_contributors", "repo_age_months"]
LABELS = {
    "stars": "Stars",
    "size_kb": "Size (KB)",
    "forks": "Forks",
    "num_commits": "Commits",
    "num_contributors": "Contributors",
    "repo_age_months": "Repo Age (months)",
}


def setup_logging(log_path: Path) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    root.handlers.clear()

    console = logging.StreamHandler(sys.stdout)
    console.setLevel(logging.INFO)
    console.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    root.addHandler(console)

    fh = logging.FileHandler(log_path, mode="w")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(name)s - %(message)s"))
    root.addHandler(fh)


def compute_smd(treat_vals: np.ndarray, ctrl_vals: np.ndarray) -> float:
    """Standardized mean difference (Rubin 2001)."""
    mean_t = np.mean(treat_vals)
    mean_c = np.mean(ctrl_vals)
    pooled_var = (np.var(treat_vals, ddof=1) + np.var(ctrl_vals, ddof=1)) / 2
    if pooled_var < 1e-12:
        return 0.0
    return (mean_t - mean_c) / np.sqrt(pooled_var)


def main() -> None:
    cfg = yaml.safe_load((PROJECT_ROOT / "config" / "config.yaml").read_text())

    log_path = PROJECT_ROOT / cfg["paths"]["logs"] / "03_assess_balance.log"
    setup_logging(log_path)
    logger = logging.getLogger(__name__)

    logger.info("=== Phase 2 Step 3: Assess Balance ===")

    # Load all repo characteristics
    chars_path = PROJECT_ROOT / "data" / "processed" / "repo_characteristics.csv"
    chars: dict[str, dict] = {}
    with open(chars_path) as f:
        for row in csv.DictReader(f):
            chars[row["full_name"]] = row

    # Load matching results
    matching_path = PROJECT_ROOT / "data" / "processed" / "matching.csv"
    matched_t_names: list[str] = []
    matched_c_names: list[str] = []
    with open(matching_path) as f:
        for row in csv.DictReader(f):
            matched_t_names.append(row["treatment_repo"])
            matched_c_names.append(row["control_repo"])

    n_matched = len(matched_t_names)
    logger.info(f"Matched pairs: {n_matched}")

    # Separate full treatment and control groups (before matching)
    all_treat = [chars[n] for n in chars if chars[n]["treated"] == "1"]
    all_ctrl = [chars[n] for n in chars if chars[n]["treated"] == "0"]
    logger.info(f"Full sample: {len(all_treat)} treatment, {len(all_ctrl)} control")

    # Compute SMDs before and after matching
    smds_before: dict[str, float] = {}
    smds_after: dict[str, float] = {}
    means_t_matched: dict[str, float] = {}
    means_c_matched: dict[str, float] = {}

    for col in COVARIATES:
        # Before matching: all valid treatment vs all valid control
        t_before = np.array([float(r[col]) for r in all_treat if r[col]])
        c_before = np.array([float(r[col]) for r in all_ctrl if r[col]])
        smds_before[col] = compute_smd(t_before, c_before) if len(t_before) and len(c_before) else 0.0

        # After matching
        t_after = np.array([float(chars[n][col]) for n in matched_t_names if chars[n][col]])
        c_after = np.array([float(chars[n][col]) for n in matched_c_names if chars[n][col]])
        smds_after[col] = compute_smd(t_after, c_after) if len(t_after) and len(c_after) else 0.0
        means_t_matched[col] = float(np.mean(t_after)) if len(t_after) else 0.0
        means_c_matched[col] = float(np.mean(c_after)) if len(c_after) else 0.0

    # Print balance table
    logger.info(f"\n{'Covariate':<20} {'Before':>10} {'After':>10} {'Improved':>10} {'Balanced':>10}")
    logger.info("-" * 62)
    n_balanced = 0
    for col in COVARIATES:
        before = smds_before[col]
        after = smds_after[col]
        improved = abs(after) < abs(before)
        balanced = abs(after) < 0.1
        if balanced:
            n_balanced += 1
        logger.info(
            f"{LABELS[col]:<20} {before:>10.4f} {after:>10.4f} "
            f"{'yes':>10} {('OK' if balanced else 'FAIL'):>10}"
        )

    logger.info(f"\nBalanced covariates: {n_balanced}/{len(COVARIATES)}")

    # === Love Plot ===
    fig, ax = plt.subplots(figsize=(7, 5))

    y_pos = np.arange(len(COVARIATES))
    labels = [LABELS[c] for c in COVARIATES]

    before_abs = [abs(smds_before[c]) for c in COVARIATES]
    after_abs = [abs(smds_after[c]) for c in COVARIATES]

    # Lines connecting before and after
    for i in range(len(COVARIATES)):
        ax.plot([before_abs[i], after_abs[i]], [y_pos[i], y_pos[i]],
                color="gray", linewidth=0.8, zorder=1)

    ax.scatter(before_abs, y_pos, marker="o", s=70, color="#e74c3c",
               label="Before matching", zorder=3, edgecolors="white", linewidth=0.5)
    ax.scatter(after_abs, y_pos, marker="s", s=70, color="#2ecc71",
               label="After matching", zorder=3, edgecolors="white", linewidth=0.5)

    ax.axvline(x=0.1, color="black", linestyle="--", linewidth=1, alpha=0.7, label="|SMD| = 0.1")

    ax.set_yticks(y_pos)
    ax.set_yticklabels(labels)
    ax.set_xlabel("|Standardized Mean Difference|")
    ax.set_title("Covariate Balance: Before vs. After Matching")
    ax.legend(loc="lower right", framealpha=0.9)
    ax.grid(axis="x", alpha=0.3)
    ax.set_xlim(left=0)

    fig_path = PROJECT_ROOT / cfg["paths"]["figures"] / "fig_balance_love_plot.pdf"
    fig_path.parent.mkdir(parents=True, exist_ok=True)
    plt.tight_layout()
    plt.savefig(fig_path, dpi=300, bbox_inches="tight")
    plt.close()
    logger.info(f"Saved love plot to {fig_path}")

    # === LaTeX Balance Table ===
    table_path = PROJECT_ROOT / cfg["paths"]["tables"] / "tab_balance.tex"
    table_path.parent.mkdir(parents=True, exist_ok=True)

    with open(table_path, "w") as f:
        f.write("\\begin{table}[t]\n")
        f.write("\\caption{Covariate balance before and after propensity score matching.}\n")
        f.write("\\label{tab:balance}\n")
        f.write("\\centering\\small\n")
        f.write("\\begin{tabular}{lrrrr}\n")
        f.write("\\toprule\n")
        f.write("Covariate & Mean (T) & Mean (C) & SMD (before) & SMD (after) \\\\\n")
        f.write("\\midrule\n")

        for col in COVARIATES:
            label = LABELS[col].replace("(", "\\text{(").replace(")", ")}")
            # Use simple label for LaTeX
            label = LABELS[col]
            mean_t = means_t_matched[col]
            mean_c = means_c_matched[col]

            # Format large numbers
            if mean_t > 1000:
                mt_str = f"{mean_t:,.0f}"
                mc_str = f"{mean_c:,.0f}"
            else:
                mt_str = f"{mean_t:.1f}"
                mc_str = f"{mean_c:.1f}"

            f.write(
                f"{label} & {mt_str} & {mc_str} & "
                f"{smds_before[col]:.3f} & {smds_after[col]:.3f} \\\\\n"
            )

        f.write("\\bottomrule\n")
        f.write("\\end{tabular}\n")
        f.write("\\end{table}\n")

    logger.info(f"Saved balance table to {table_path}")
    logger.info("=== Done ===")


if __name__ == "__main__":
    main()
