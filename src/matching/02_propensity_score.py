"""1:1 propensity score matching for treatment and control repos.

Fits logistic regression on covariates to estimate propensity scores,
then performs greedy nearest-neighbor matching on the logit of propensity
scores with caliper = 0.2 * SD(logit(PS)) (Austin 2011).
"""

import csv
import logging
import sys
from pathlib import Path

import numpy as np
import yaml
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler

PROJECT_ROOT = Path(__file__).resolve().parents[2]

COVARIATES = ["stars", "size_kb", "forks", "num_commits", "num_contributors", "repo_age_months"]
LOG_TRANSFORM = {"stars", "size_kb", "num_commits", "forks"}


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


def main() -> None:
    cfg = yaml.safe_load((PROJECT_ROOT / "config" / "config.yaml").read_text())
    seed = cfg["study"]["seed"]
    caliper_factor = cfg["matching"]["caliper"]

    np.random.seed(seed)

    log_path = PROJECT_ROOT / cfg["paths"]["logs"] / "02_propensity_score.log"
    setup_logging(log_path)
    logger = logging.getLogger(__name__)

    logger.info("=== Phase 2 Step 2: Propensity Score Matching ===")
    logger.info(f"Config: seed={seed}, caliper={caliper_factor}, covariates={COVARIATES}")

    # Load data
    chars_path = PROJECT_ROOT / "data" / "processed" / "repo_characteristics.csv"
    rows: list[dict] = []
    dropped = 0
    with open(chars_path) as f:
        for row in csv.DictReader(f):
            row["treated"] = int(row["treated"])
            has_missing = False
            for col in COVARIATES:
                try:
                    val = float(row[col])
                    if np.isnan(val):
                        has_missing = True
                        break
                    row[col] = val
                except (ValueError, KeyError):
                    has_missing = True
                    break
            if has_missing:
                logger.debug(f"Dropping {row['full_name']} (missing covariates)")
                dropped += 1
                continue
            rows.append(row)

    if dropped:
        logger.warning(f"Dropped {dropped} repos with missing covariates")

    treatment = [r for r in rows if r["treated"] == 1]
    control = [r for r in rows if r["treated"] == 0]
    logger.info(f"Valid repos: {len(treatment)} treatment, {len(control)} control")

    all_data = treatment + control
    n_t, n_c = len(treatment), len(control)

    # Build feature matrix (raw values for SMD computation later)
    X_raw = np.array([[r[col] for col in COVARIATES] for r in all_data])

    # Log-transform skewed covariates + standardize for logistic regression
    X = X_raw.copy()
    for j, col in enumerate(COVARIATES):
        if col in LOG_TRANSFORM:
            X[:, j] = np.log1p(X[:, j])

    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)
    y = np.array([1] * n_t + [0] * n_c)

    # Fit logistic regression
    lr = LogisticRegression(random_state=seed, max_iter=1000, solver="lbfgs")
    lr.fit(X_scaled, y)

    # Propensity scores
    ps = lr.predict_proba(X_scaled)[:, 1]
    eps = 1e-8
    ps_clip = np.clip(ps, eps, 1 - eps)
    logit_ps = np.log(ps_clip / (1 - ps_clip))

    # Caliper = 0.2 * SD(logit(PS)) - Austin (2011)
    caliper = caliper_factor * np.std(logit_ps)
    logger.info(f"Caliper: {caliper_factor} x {np.std(logit_ps):.4f} = {caliper:.4f}")

    # Report PS distributions
    logger.info(
        f"PS treatment: mean={np.mean(ps[:n_t]):.3f}, "
        f"sd={np.std(ps[:n_t]):.3f}, "
        f"range=[{np.min(ps[:n_t]):.3f}, {np.max(ps[:n_t]):.3f}]"
    )
    logger.info(
        f"PS control:   mean={np.mean(ps[n_t:]):.3f}, "
        f"sd={np.std(ps[n_t:]):.3f}, "
        f"range=[{np.min(ps[n_t:]):.3f}, {np.max(ps[n_t:]):.3f}]"
    )

    # Common support check
    ps_overlap_lo = max(np.min(ps[:n_t]), np.min(ps[n_t:]))
    ps_overlap_hi = min(np.max(ps[:n_t]), np.max(ps[n_t:]))
    if ps_overlap_lo >= ps_overlap_hi:
        logger.error("No common support! PS distributions do not overlap.")
    else:
        n_treat_in_support = np.sum((ps[:n_t] >= ps_overlap_lo) & (ps[:n_t] <= ps_overlap_hi))
        logger.info(
            f"Common support: [{ps_overlap_lo:.3f}, {ps_overlap_hi:.3f}] "
            f"({n_treat_in_support}/{n_t} treatment repos)"
        )

    # Greedy 1:1 matching - Mahalanobis distance in standardized covariate space
    # (provides better per-covariate balance than matching on scalar propensity score)
    X_t = X_scaled[:n_t]
    X_c = X_scaled[n_t:]

    # Mahalanobis distance using standardized features (identity cov = Euclidean on std features)
    dist_matrix = np.sqrt(
        np.sum((X_t[:, np.newaxis, :] - X_c[np.newaxis, :, :]) ** 2, axis=2)
    )

    # Use PS caliper as additional constraint
    logit_t = logit_ps[:n_t]
    logit_c = logit_ps[n_t:]
    ps_dist = np.abs(logit_t[:, np.newaxis] - logit_c[np.newaxis, :])

    # Random treatment ordering for greedy matching
    rng = np.random.RandomState(seed)
    treat_order = rng.permutation(n_t)

    matched: list[tuple[int, int, float]] = []
    used_ctrl: set[int] = set()
    unmatched: list[int] = []

    for t_idx in treat_order:
        dists = dist_matrix[t_idx].copy()
        ps_dists = ps_dist[t_idx].copy()
        for c in used_ctrl:
            dists[c] = np.inf
        # Apply PS caliper as hard constraint
        dists[ps_dists > caliper] = np.inf
        c_idx = int(np.argmin(dists))
        if dists[c_idx] < np.inf:
            matched.append((t_idx, c_idx, float(dists[c_idx])))
            used_ctrl.add(c_idx)
        else:
            unmatched.append(t_idx)
            logger.debug(
                f"No match: {treatment[t_idx]['full_name']} "
                f"(min_dist={dists[c_idx]:.4f} > caliper={caliper:.4f})"
            )

    logger.info(f"Matched: {len(matched)}/{n_t} treatment repos")
    if unmatched:
        logger.warning(f"Unmatched: {len(unmatched)} treatment repos:")
        for t_idx in unmatched:
            logger.warning(f"  {treatment[t_idx]['full_name']} (stars={treatment[t_idx]['stars']:.0f})")

    # Compute SMDs on RAW covariates for matched sample
    matched_t = np.array([p[0] for p in matched])
    matched_c = np.array([p[1] for p in matched])

    smds: dict[str, float] = {}
    for j, col in enumerate(COVARIATES):
        t_vals = X_raw[matched_t, j]
        c_vals = X_raw[matched_c + n_t, j]
        pooled_var = (np.var(t_vals, ddof=1) + np.var(c_vals, ddof=1)) / 2
        smds[col] = float((np.mean(t_vals) - np.mean(c_vals)) / np.sqrt(pooled_var)) if pooled_var > 0 else 0.0

    logger.info("\n=== Covariate Balance (matched sample) ===")
    logger.info(f"{'Covariate':<20} {'SMD':>8}")
    logger.info("-" * 30)
    all_balanced = True
    for col in COVARIATES:
        ok = abs(smds[col]) < 0.1
        if not ok:
            all_balanced = False
        logger.info(f"{col:<20} {smds[col]:>8.4f}  {'OK' if ok else 'IMBALANCED'}")

    if all_balanced:
        logger.info("\nAll covariates balanced (|SMD| < 0.1)")
    else:
        logger.warning("\nSome covariates imbalanced (|SMD| >= 0.1)")

    # Save matching.csv
    out_path = PROJECT_ROOT / "data" / "processed" / "matching.csv"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    fieldnames = ["treatment_repo", "control_repo", "ps_treatment", "ps_control", "distance"]
    fieldnames += [f"smd_{col}" for col in COVARIATES]

    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for t_idx, c_idx, dist in matched:
            row = {
                "treatment_repo": treatment[t_idx]["full_name"],
                "control_repo": control[c_idx]["full_name"],
                "ps_treatment": f"{ps[t_idx]:.6f}",
                "ps_control": f"{ps[n_t + c_idx]:.6f}",
                "distance": f"{dist:.6f}",
            }
            for col in COVARIATES:
                row[f"smd_{col}"] = f"{smds[col]:.4f}"
            writer.writerow(row)

    logger.info(f"\nSaved {len(matched)} matched pairs to {out_path}")

    # Log matched pair quality summary
    distances = [d for _, _, d in matched]
    logger.info(
        f"Match distances: mean={np.mean(distances):.4f}, "
        f"max={np.max(distances):.4f}, "
        f"median={np.median(distances):.4f}"
    )

    logger.info("=== Done ===")


if __name__ == "__main__":
    main()
