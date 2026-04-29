"""Content-based validation for AI tool marker files."""

from __future__ import annotations

import logging

from github import Github, GithubException

logger = logging.getLogger(__name__)

# Marker file paths to probe (flat list for existence checks)
MARKER_PATHS: list[str] = [
    ".cursorrules",
    ".github/copilot-instructions.md",
    "CLAUDE.md",
    "claude.md",
    "AGENTS.md",
    ".aider.conf.yml",
    ".aider.model.settings.yml",
]

# Keywords for content validation
_CLAUDE_MD_KEYWORDS: list[str] = [
    "claude code",
    "anthropic",
    "coding assistant",
    "ai assistant",
    "claude",
    "llm",
    "prompt",
    "codebase",
    "don't",
    "must",
    "rules",
]

_AGENTS_MD_KEYWORDS: list[str] = [
    "codex",
    "copilot",
    "claude",
    "cursor",
    "ai agent",
    "coding agent",
    "openai",
    "anthropic",
    "aider",
    "build",
    "test",
    "run",
]

# Files that always count as genuine (low false-positive risk)
_ALWAYS_VALID: set[str] = {
    ".cursorrules",
    ".aider.conf.yml",
    ".aider.model.settings.yml",
    ".github/copilot-instructions.md",
    "copilot-instructions.md",
}


def validate_marker_content(text: str, file_path: str) -> bool:
    """Check if file content indicates genuine AI tool config.

    Returns True if the content passes validation for the given marker file type.
    For low-false-positive markers (.cursorrules, .aider*, copilot-instructions.md),
    always returns True. For CLAUDE.md, requires >= 2 keyword matches.
    For AGENTS.md, requires >= 1 keyword match.
    """
    basename = file_path.rsplit("/", 1)[-1].lower() if "/" in file_path else file_path.lower()
    full_lower = file_path.lower()

    # Low false-positive files: always valid
    if basename in {p.rsplit("/", 1)[-1].lower() for p in _ALWAYS_VALID}:
        return True
    if full_lower in {p.lower() for p in _ALWAYS_VALID}:
        return True

    text_lower = text.lower()

    # CLAUDE.md / claude.md: need >= 2 keyword matches
    if basename in ("claude.md",):
        matches = sum(1 for kw in _CLAUDE_MD_KEYWORDS if kw in text_lower)
        return matches >= 2

    # AGENTS.md
    if basename == "agents.md":
        matches = sum(1 for kw in _AGENTS_MD_KEYWORDS if kw in text_lower)
        return matches >= 1

    # Unknown marker type - be conservative, accept it
    return True


def detect_ai_markers_from_repo(g: Github, repo_name: str) -> list[str]:
    """Check which AI marker files exist in a repo.

    Uses GET /repos/{owner}/{repo}/contents/{path} via PyGithub.
    For CLAUDE.md and AGENTS.md, also downloads content and validates.

    Returns list of marker file paths that were found (and validated).
    """
    found: list[str] = []
    repo = g.get_repo(repo_name)

    for path in MARKER_PATHS:
        try:
            content_file = repo.get_contents(path)
        except GithubException as e:
            if e.status == 404:
                continue
            logger.warning("API error checking %s in %s: %s", path, repo_name, e)
            continue

        # For CLAUDE.md and AGENTS.md, validate content
        basename = path.rsplit("/", 1)[-1].lower() if "/" in path else path.lower()
        if basename in ("claude.md", "agents.md"):
            try:
                text = content_file.decoded_content.decode("utf-8", errors="replace")
                if validate_marker_content(text, path):
                    found.append(path)
                    logger.debug("Validated %s in %s", path, repo_name)
                else:
                    logger.debug(
                        "Marker %s in %s failed content validation - skipping", path, repo_name
                    )
            except Exception:
                logger.warning("Could not decode %s in %s - skipping", path, repo_name)
        else:
            found.append(path)
            logger.debug("Found %s in %s", path, repo_name)

    return found


def get_marker_reliability() -> dict[str, str]:
    """Return reliability rating for each marker type.

    Ratings:
      - "high": .cursorrules, copilot-instructions.md, .aider*
      - "medium": CLAUDE.md
      - "low": AGENTS.md
    """
    return {
        ".cursorrules": "high",
        ".github/copilot-instructions.md": "high",
        ".aider.conf.yml": "high",
        ".aider.model.settings.yml": "high",
        "CLAUDE.md": "medium",
        "claude.md": "medium",
        "AGENTS.md": "low",
    }
