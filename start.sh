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
#   6. Start `dsh web` in the background, then run Nginx in the foreground
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
# 4. OpenRouter API key injection (OpenAI-compatible provider)
# -----------------------------------------------------------------------------
if [ -z "$OPENROUTER_API_KEY" ]; then
    echo "WARNING: OPENROUTER_API_KEY is not set. The harness will start, but model requests will fail until it is configured." >&2
fi

export OPENAI_API_KEY="${OPENROUTER_API_KEY}"
export OPENAI_BASE_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"
export OPENROUTER_API_KEY="${OPENROUTER_API_KEY}"

# -----------------------------------------------------------------------------
# 5. Render the Nginx config template
# -----------------------------------------------------------------------------
envsubst '${PORT} ${DSH_INTERNAL_PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
echo "start.sh: nginx.conf rendered (public PORT=${PORT}, internal DSH_INTERNAL_PORT=${DSH_INTERNAL_PORT})."

# -----------------------------------------------------------------------------
# 6. Start the harness daemon, then run Nginx in the foreground
# -----------------------------------------------------------------------------
cd /data/workspace

echo "start.sh: launching dsh web on 127.0.0.1:${DSH_INTERNAL_PORT} ..."
dsh web --host 127.0.0.1 --port "${DSH_INTERNAL_PORT}" --no-open &

sleep 2

echo "start.sh: starting nginx on port ${PORT} ..."
exec nginx -g "daemon off;"
