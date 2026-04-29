"""GitHub API wrapper with rate limiting and retry."""

import logging
import time
from pathlib import Path

from github import Auth, Github, GithubRetry
from github.GithubException import GithubException

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parents[3]


def load_token() -> str:
    env_path = PROJECT_ROOT / ".env"
    if not env_path.exists():
        raise FileNotFoundError(f".env not found at {env_path}")
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if line.startswith("GITHUB_TOKEN="):
            return line.split("=", 1)[1].strip()
    raise ValueError("GITHUB_TOKEN not found in .env")


def create_client(token: str | None = None) -> Github:
    if token is None:
        token = load_token()
    retry = GithubRetry(total=10, secondary_rate_wait=60)
    return Github(auth=Auth.Token(token), per_page=100, retry=retry)


def _search_with_retry(g: Github, query: str, max_retries: int = 3):
    """Execute search_code with explicit 429 retry and backoff."""
    for attempt in range(max_retries + 1):
        time.sleep(7)  # stay under 10 req/min
        try:
            results = g.search_code(query)
            total = results.totalCount
            return results, total
        except GithubException as e:
            if e.status == 429 or (hasattr(e, "data") and "429" in str(e.data)):
                wait = 65 * (attempt + 1)
                logger.warning(f"429 rate limited on '{query}', waiting {wait}s (attempt {attempt + 1})")
                time.sleep(wait)
            else:
                logger.error(f"API error for query '{query}': {e}")
                return None, 0
    logger.error(f"Exhausted retries for '{query}'")
    return None, 0


def adaptive_code_search(
    g: Github,
    base_query: str,
    size_lo: int = 0,
    size_hi: int = 384000,
) -> list[dict]:
    size_qualifier = f" size:{size_lo}..{size_hi}" if size_hi < 384000 or size_lo > 0 else ""
    query = base_query + size_qualifier
    logger.info(f"Searching: {query}")

    results, total = _search_with_retry(g, query)
    if results is None:
        return []

    logger.info(f"  -> {total} results for size:{size_lo}..{size_hi}")

    if total == 0:
        return []

    if total >= 1000:
        if size_lo >= size_hi:
            logger.warning(
                f"Cannot partition further (size={size_lo}..{size_hi}), "
                f"collecting first 1000 of {total}"
            )
        else:
            mid = (size_lo + size_hi) // 2
            logger.info(f"  -> Partitioning: {size_lo}..{mid} and {mid + 1}..{size_hi}")
            left = adaptive_code_search(g, base_query, size_lo, mid)
            right = adaptive_code_search(g, base_query, mid + 1, size_hi)
            return left + right

    collected: list[dict] = []
    page_num = 0
    while True:
        time.sleep(7)
        try:
            page = results.get_page(page_num)
        except GithubException as e:
            if e.status == 429:
                logger.warning(f"429 on page {page_num}, waiting 65s...")
                time.sleep(65)
                try:
                    page = results.get_page(page_num)
                except GithubException:
                    logger.error(f"Retry failed for page {page_num} of '{query}'")
                    break
            else:
                logger.error(f"Error fetching page {page_num} for '{query}': {e}")
                break

        if not page:
            break

        for item in page:
            collected.append({
                "repo_full_name": item.repository.full_name,
                "file_path": item.path,
                "file_name": item.name,
                "sha": item.sha,
                "html_url": item.html_url,
                "query": base_query,
            })

        page_num += 1
        logger.debug(f"  Page {page_num}: {len(collected)} results so far")

        if len(collected) >= total:
            break

    logger.info(f"  -> Collected {len(collected)} results for '{query}'")
    return collected


def check_rate_limit(g: Github) -> dict:
    rl = g.get_rate_limit()
    res = rl.resources
    return {
        "core": {"remaining": res.core.remaining, "limit": res.core.limit},
        "search": {"remaining": res.search.remaining, "limit": res.search.limit},
        "code_search": {"remaining": res.code_search.remaining, "limit": res.code_search.limit},
    }
