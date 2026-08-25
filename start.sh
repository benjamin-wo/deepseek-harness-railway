#!/bin/sh
# =============================================================================
# start.sh — container entrypoint for the DeepSeek Harness Railway deployment
#
# Lifecycle:
#   1. Initialize ports & ensure persistent volume directories exist
#   2. Redirect HOME / DSH_HOME onto the persistent volume
#   3. Generate the Nginx Basic Auth credential file
#   4. Inject the OpenRouter API key as an OpenAI-compatible provider
#   5. Render the Nginx config template
#   6. Determine trusted hosts for dsh's /api browser-trust fence
#   7. Start `dsh web` in the background, then run Nginx in the foreground
# =============================================================================
set -e

# -----------------------------------------------------------------------------
# 1. Port & path initialization
# -----------------------------------------------------------------------------
export PORT="${PORT:-8080}"
export DSH_INTERNAL_PORT="${DSH_INTERNAL_PORT:-3080}"

mkdir -p /data/workspace
mkdir -p /data/dsh_home

# -----------------------------------------------------------------------------
# 2. Environment redirection to the persistent volume
#
#    DSH_HOME  -> harness config, plugins, session state
#    HOME      -> .gitconfig, SSH keys (~/.ssh), shell history, etc.
#    Both live under /data so they survive redeploys and restarts.
# -----------------------------------------------------------------------------
export DSH_HOME="/data/dsh_home"
export HOME="/data"

# -----------------------------------------------------------------------------
# 3. Basic Auth generation
# -----------------------------------------------------------------------------
if [ -z "$AUTH_USER" ] || [ -z "$AUTH_PASSWORD" ]; then
    echo "ERROR: AUTH_USER and AUTH_PASSWORD must both be set. Refusing to start with an unprotected endpoint." >&2
    exit 1
fi

htpasswd -bc /etc/nginx/.htpasswd "$AUTH_USER" "$AUTH_PASSWORD"
echo "start.sh: Basic Auth credentials written for user '${AUTH_USER}'."

# -----------------------------------------------------------------------------
# 4. OpenRouter API key injection
#
#    dsh's built-in "deepseek-official" provider route (@deepseek-ai/dsh-llm-deepseek)
#    is a chat-completions adapter whose endpoint is fully redirectable — it
#    resolves its API key from the $DEEPSEEK_API_KEY env var (ctx.credentials,
#    i.e. the web Models page, takes precedence if set there instead) and its
#    base URL from $DEEPSEEK_BASE_URL, defaulting to api.deepseek.com only
#    when unset. Pointing both at OpenRouter routes every request through
#    OpenRouter's OpenAI-compatible gateway. The route still displays as
#    "deepseek-official" in the UI/logs regardless of the actual endpoint —
#    that's expected. dsh does NOT read OPENAI_API_KEY/OPENAI_BASE_URL; they
#    are exported too only as a courtesy for any other OpenAI-SDK-convention
#    tooling that might run inside the container.
# -----------------------------------------------------------------------------
if [ -z "$OPENROUTER_API_KEY" ]; then
    echo "WARNING: OPENROUTER_API_KEY is not set. The harness will start, but model requests will fail until it is configured." >&2
fi

export DEEPSEEK_API_KEY="${OPENROUTER_API_KEY}"
export DEEPSEEK_BASE_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"
export OPENAI_API_KEY="${OPENROUTER_API_KEY}"
export OPENAI_BASE_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"
export OPENROUTER_API_KEY="${OPENROUTER_API_KEY}"

# -----------------------------------------------------------------------------
# 5. Render the Nginx config template
# -----------------------------------------------------------------------------
envsubst '${PORT} ${DSH_INTERNAL_PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
echo "start.sh: nginx.conf rendered (public PORT=${PORT}, internal DSH_INTERNAL_PORT=${DSH_INTERNAL_PORT})."

# -----------------------------------------------------------------------------
# 6. Trusted hosts for dsh's /api browser-trust fence
#
#    dsh's web server rejects any request whose Host header isn't in its
#    trusted-host allowlist (default: loopback only) — every /api call
#    403s even though the UI itself loads fine, since Nginx forwards the
#    original public Host header straight through. RAILWAY_PUBLIC_DOMAIN
#    is injected automatically by Railway once a public domain exists, so
#    this needs no manual configuration in the normal case; EXTRA_TRUSTED_HOSTS
#    (comma/space-separated) covers a custom domain or any additional host.
# -----------------------------------------------------------------------------
set -- --host 127.0.0.1 --port "${DSH_INTERNAL_PORT}" --no-open

if [ -n "$RAILWAY_PUBLIC_DOMAIN" ]; then
    set -- "$@" --trusted-host "$RAILWAY_PUBLIC_DOMAIN"
fi

if [ -n "$EXTRA_TRUSTED_HOSTS" ]; then
    for host in $(echo "$EXTRA_TRUSTED_HOSTS" | tr ',' ' '); do
        set -- "$@" --trusted-host "$host"
    done
fi

# -----------------------------------------------------------------------------
# 7. Start the harness daemon, then run Nginx in the foreground
# -----------------------------------------------------------------------------
cd /data/workspace

echo "start.sh: launching dsh web on 127.0.0.1:${DSH_INTERNAL_PORT} (trusted hosts: ${RAILWAY_PUBLIC_DOMAIN:-none} ${EXTRA_TRUSTED_HOSTS}) ..."
dsh web "$@" &

sleep 2

echo "start.sh: starting nginx on port ${PORT} ..."
exec nginx -g "daemon off;"
