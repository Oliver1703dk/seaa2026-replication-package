"""Search GitHub for repos containing AI tool config files."""

import csv
import json
import logging
import random
import sys
from pathlib import Path

import yaml
from tqdm import tqdm

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "src"))

from mining.utils.github_api import (  # noqa: E402
    adaptive_code_search,
    check_rate_limit,
    create_client,
)

QUERIES = [
    "filename:.cursorrules",
    "path:.cursor/rules/",
    "filename:copilot-instructions.md path:.github",
    "filename:CLAUDE.md",
    "filename:AGENTS.md",
    "filename:.aider.conf.yml",
    "filename:.aider.model.settings.yml",
]

QUERY_TO_MARKER = {
    "filename:.cursorrules": "cursor",
    "path:.cursor/rules/": "cursor",
    "filename:copilot-instructions.md path:.github": "copilot",
    "filename:CLAUDE.md": "claude_code",
    "filename:AGENTS.md": "codex",
    "filename:.aider.conf.yml": "aider",
    "filename:.aider.model.settings.yml": "aider",
}


def setup_logging(log_path: Path) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    root_logger = logging.getLogger()
    root_logger.setLevel(logging.DEBUG)

    root_logger.handlers.clear()

    console = logging.StreamHandler(sys.stdout)
    console.setLevel(logging.INFO)
    console.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    root_logger.addHandler(console)

    fh = logging.FileHandler(log_path, mode="a")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(
        logging.Formatter("%(asctime)s [%(levelname)s] %(name)s - %(message)s")
    )
    root_logger.addHandler(fh)


def load_completed_queries(jsonl_path: Path) -> set[str]:
    completed: set[str] = set()
    if not jsonl_path.exists():
        return completed
    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
                completed.add(record.get("query", ""))
            except json.JSONDecodeError:
                continue
    return completed


def main() -> None:
    config_path = PROJECT_ROOT / "config" / "config.yaml"
    with open(config_path) as f:
        config = yaml.safe_load(f)

    seed = config["study"]["seed"]
    random.seed(seed)

    log_path = PROJECT_ROOT / config["paths"]["logs"] / "01_search_treatment_repos.log"
    setup_logging(log_path)
    logger = logging.getLogger(__name__)

    jsonl_path = PROJECT_ROOT / "data" / "raw" / "github_metadata" / "code_search_results.jsonl"
    csv_path = PROJECT_ROOT / "config" / "repo_lists" / "treatment_candidates_raw.csv"

    jsonl_path.parent.mkdir(parents=True, exist_ok=True)
    csv_path.parent.mkdir(parents=True, exist_ok=True)

    logger.info("=== Phase 1: Search Treatment Repos ===")
    logger.info(f"Config: seed={seed}")

    g = create_client()
    rl = check_rate_limit(g)
    logger.info(f"Rate limits: {json.dumps(rl)}")

    completed_queries = load_completed_queries(jsonl_path)
    logger.info(f"Already completed queries: {completed_queries or 'none'}")

    all_results: list[dict] = []

    for query in tqdm(QUERIES, desc="Queries"):
        if query in completed_queries:
            logger.info(f"SKIP (already done): {query}")
            continue

        logger.info(f"Running query: {query}")
        results = adaptive_code_search(g, query)
        logger.info(f"  => {len(results)} results for '{query}'")

        with open(jsonl_path, "a") as f:
            for r in results:
                f.write(json.dumps(r) + "\n")

        all_results.extend(results)

        rl = check_rate_limit(g)
        logger.debug(f"Rate limits after query: {json.dumps(rl)}")

    # Reload all results from JSONL for deduplication (includes previous runs)
    logger.info("Loading all results from JSONL for deduplication...")
    all_results_full: list[dict] = []
    if jsonl_path.exists():
        with open(jsonl_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    all_results_full.append(json.loads(line))
                except json.JSONDecodeError:
                    continue

    logger.info(f"Total raw results: {len(all_results_full)}")

    # Deduplicate by repo_full_name
    repo_info: dict[str, dict] = {}
    for r in all_results_full:
        name = r["repo_full_name"]
        marker = QUERY_TO_MARKER.get(r["query"], r["query"])
        if name not in repo_info:
            repo_info[name] = {
                "full_name": name,
                "markers": set(),
                "first_seen_query": r["query"],
            }
        repo_info[name]["markers"].add(marker)

    # Sort by number of markers descending, then name
    repos = sorted(repo_info.values(), key=lambda x: (-len(x["markers"]), x["full_name"]))

    logger.info(f"Unique repos: {len(repos)}")

    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(
            f, fieldnames=["full_name", "markers", "num_markers", "first_seen_query"]
        )
        writer.writeheader()
        for repo in repos:
            writer.writerow({
                "full_name": repo["full_name"],
                "markers": ",".join(sorted(repo["markers"])),
                "num_markers": len(repo["markers"]),
                "first_seen_query": repo["first_seen_query"],
            })

    logger.info(f"Saved {len(repos)} candidates to {csv_path}")
    logger.info("=== Done ===")


if __name__ == "__main__":
    main()
