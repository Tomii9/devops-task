# =============================================================================
# Production Dockerfile for helloapp
# =============================================================================
#
# TECHNOLOGY CHOICE: Docker with multi-stage builds
#
#   Docker is the industry standard for containerization, with the largest
#   ecosystem of tooling, registries, and CI/CD integrations. buildah is a
#   valid rootless/daemonless alternative, but Docker is more universally
#   understood and better supported by GitHub Actions, GitLab CI, etc.
#
# BASE IMAGE: python:3.11-slim
#
#   - Debian-based — full glibc compatibility means all pip wheels work
#     natively (unlike Alpine/musl which often needs compilation).
#   - "slim" strips man pages, docs, and extras: ~150 MB vs ~900 MB full.
#   - Python 3.11: modern, well-supported, significant performance gains
#     over 3.9/3.10 (10-25% faster CPython via specializing interpreter).
#
# DESIGN DECISIONS:
#
#   - Multi-stage: only runtime artifacts in the final image (~120 MB).
#   - Non-root user: eliminates container-escape-to-root risk.
#   - Precompiled bytecode: removes first-request JIT overhead (~10-20ms).
#   - Env-configurable Gunicorn: different Helm profiles tune worker count,
#     worker class (sync/gevent), threads, timeouts — all via env vars.
#   - gevent included: the scalability profile uses async workers, but we
#     ship one image for all profiles. Worker class is selected at runtime.
#
# =============================================================================

# ── Stage 1: Build ──────────────────────────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /build

COPY requirements.txt .

# Install app dependencies into a dedicated prefix for clean multi-stage copy.
# --no-cache-dir: don't store pip's download cache (smaller layer).
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Install gevent for async worker support (used by the scalability profile).
# Included in the base image so ALL profiles use the same immutable image —
# the worker class is selected at runtime via GUNICORN_WORKER_CLASS env var.
RUN pip install --no-cache-dir --prefix=/install gevent


# ── Stage 2: Runtime ────────────────────────────────────────────────────────────
FROM python:3.11-slim

# Apply OS security patches
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*

# Create a non-root user with fixed UID/GID.
# Why: running as root inside a container is a well-known attack surface.
# A container escape as root = root on the host (without user namespaces).
RUN groupadd --gid 1000 appuser && \
    useradd --uid 1000 --gid 1000 --no-create-home appuser

WORKDIR /app

# Copy only the installed Python packages from the builder stage.
COPY --from=builder /install /usr/local

# Remove build/packaging tools from runtime. They are not needed to run the app
# and setuptools bundles vendored libraries (jaraco.context, wheel) with known CVEs.
RUN rm -rf /usr/local/lib/python3.11/site-packages/setuptools* \
           /usr/local/lib/python3.11/site-packages/pip* \
           /usr/local/bin/pip*

# Copy application source code.
COPY helloapp/ ./helloapp/

# Pre-compile all Python bytecode at build time.
# This eliminates the ~10-20ms JIT compilation overhead on first import.
# The -q flag suppresses output; -b writes .pyc next to .py files.
RUN python -m compileall -q /usr/local/lib/python3.11/ /app/

# Switch to non-root user for all runtime operations.
USER appuser

EXPOSE 8080

# ── Gunicorn configuration via environment variables ────────────────────────────
# Each Helm values profile overrides these to tune for its optimization target.
#
#   GUNICORN_WORKERS:         Number of worker processes.
#   GUNICORN_WORKER_CLASS:    sync (default), gevent (scalability), etc.
#   GUNICORN_THREADS:         Threads per worker (latency profile uses 4).
#   GUNICORN_KEEP_ALIVE:      Keep-alive timeout in seconds.
#   GUNICORN_TIMEOUT:         Worker timeout (0 = no timeout, for debugging).
#   GUNICORN_GRACEFUL_TIMEOUT: Time to finish in-flight requests on shutdown.
ENV GUNICORN_WORKERS=2 \
    GUNICORN_WORKER_CLASS=sync \
    GUNICORN_THREADS=1 \
    GUNICORN_KEEP_ALIVE=5 \
    GUNICORN_TIMEOUT=30 \
    GUNICORN_GRACEFUL_TIMEOUT=30

# Docker-level health check.
# Also useful as a fallback when running outside Kubernetes (e.g., docker-compose).
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/')" || exit 1

# Shell form (not exec form) is required for environment variable expansion.
# The exec form ["gunicorn", ...] does NOT expand $VARS.
CMD exec gunicorn --bind 0.0.0.0:8080 \
    -w ${GUNICORN_WORKERS} \
    -k ${GUNICORN_WORKER_CLASS} \
    --threads ${GUNICORN_THREADS} \
    --keep-alive ${GUNICORN_KEEP_ALIVE} \
    --timeout ${GUNICORN_TIMEOUT} \
    --graceful-timeout ${GUNICORN_GRACEFUL_TIMEOUT} \
    --access-logfile - \
    helloapp.app:app
