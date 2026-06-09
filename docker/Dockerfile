FROM ubuntu:24.04
# Ubuntu 24.04 (noble) ships Python 3.12; 22.04 only has 3.10 and would
# need the deadsnakes PPA for 3.11+.  Using 24.04 is simpler and still LTS.

LABEL maintainer="Oliver A. Larsen, Mahyar T. Moghaddam <olar@mmmi.sdu.dk>"
LABEL description="Replication environment for Mining Architectural Quality Under Agentic AI Adoption: A Causal Study of Java Repositories (SEAA 2026 STREAM)"

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-venv python3-pip \
    r-base r-base-dev \
    libcurl4-openssl-dev libssl-dev libxml2-dev libfontconfig1-dev \
    libharfbuzz-dev libfribidi-dev libfreetype6-dev libtiff5-dev \
    libpng-dev libjpeg-dev \
    git curl wget ca-certificates \
    texlive-latex-base texlive-latex-recommended texlive-latex-extra \
    texlive-fonts-recommended latexmk \
    && rm -rf /var/lib/apt/lists/*

# Install uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

# Working directory
WORKDIR /app

# Copy dependency lockfiles first (layer caching)
COPY pyproject.toml uv.lock ./
COPY renv.lock .Rprofile ./

# Install Python dependencies (frozen = exact versions from lockfile)
RUN uv sync --frozen --no-dev

# Install R packages via renv
# Create renv directory structure expected by renv::restore()
RUN mkdir -p renv
COPY renv/activate.R renv/
COPY renv/settings.json renv/
RUN Rscript -e "install.packages('renv', repos='https://cloud.r-project.org')" && \
    Rscript -e "renv::consent(provided=TRUE); renv::restore(prompt=FALSE)"

# Copy source code and config
COPY src/ src/
COPY config/ config/
COPY Makefile .

# Create output directories
RUN mkdir -p results/figures results/tables results/logs \
    data/interim/models data/interim/parsed_smells data/interim/graph_metrics \
    data/processed

# Reproducibility: fix Python hash seed
ENV PYTHONHASHSEED=42

# Default: run analysis phase only (assumes data/processed/panel_monthly.csv is mounted)
CMD ["make", "analyze"]
