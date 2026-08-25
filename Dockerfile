# =============================================================================
# DeepSeek Harness (dsh) — Railway deployment image
#
# Nginx terminates HTTP Basic Auth and reverse-proxies (with WebSocket/SSE
# support) to `dsh web`, which listens only on 127.0.0.1 and is never exposed
# directly. All mutable state (cloned repos, git/SSH credentials, harness
# config, session history) lives under /data, which is expected to be backed
# by a Railway persistent Volume mounted at /data.
# =============================================================================
FROM node:20-slim

# ---------------------------------------------------------------------------
# System dependencies
#   - nginx            reverse proxy / Basic Auth termination
#   - apache2-utils     provides `htpasswd` for Basic Auth credential files
#   - gettext-base       provides `envsubst` for rendering the nginx template
#   - git                repository cloning inside the harness workspace
#   - curl               healthchecks / debugging
#   - ca-certificates     TLS trust store for HTTPS git remotes & API calls
#   - openssh-client      cloning private repos over SSH
# ---------------------------------------------------------------------------
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        nginx \
        apache2-utils \
        gettext-base \
        git \
        curl \
        ca-certificates \
        openssh-client \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# DeepSeek Harness — global install
# ---------------------------------------------------------------------------
RUN npm install -g @deepseek-ai/dsh \
    && npm cache clean --force

# ---------------------------------------------------------------------------
# Persistent volume mount target and subdirectories.
# These are created at build time so the image is usable even before a
# volume is attached; once a Railway Volume is mounted at /data, its
# contents take over and persist across redeploys.
# ---------------------------------------------------------------------------
RUN mkdir -p /data/workspace /data/dsh_home

# ---------------------------------------------------------------------------
# Application assets
# ---------------------------------------------------------------------------
COPY nginx.conf /etc/nginx/nginx.conf.template
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

WORKDIR /data/workspace

# Documentation only — Railway injects the actual $PORT at runtime and
# nginx binds to it dynamically via start.sh/envsubst.
EXPOSE 8080

CMD ["/app/start.sh"]
