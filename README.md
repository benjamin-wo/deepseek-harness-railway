# DeepSeek Harness on Railway

A production-ready, containerized deployment of [DeepSeek Harness](https://github.com/deepseek-ai) (`@deepseek-ai/dsh`) for [Railway](https://railway.app), fronted by an Nginx reverse proxy with HTTP Basic Auth, backed by a persistent volume, and wired up to [OpenRouter](https://openrouter.ai) as an OpenAI-compatible model provider.

```
Internet ──HTTPS──▶ Railway edge ──HTTP──▶ Nginx :$PORT ──HTTP/WS──▶ dsh web :$DSH_INTERNAL_PORT
                                            (Basic Auth,               (bound to 127.0.0.1 only,
                                             streaming proxy)           never exposed directly)
                                                                              │
                                                                              ▼
                                                                     /data (persistent volume)
                                                                     ├── workspace/   cloned repos
                                                                     └── dsh_home/    harness state
```

## Repository Structure

| File | Purpose |
|---|---|
| `Dockerfile` | Builds a `node:20-slim` image with Nginx, `dsh`, and all runtime dependencies. |
| `nginx.conf` | Template rendered at startup; Basic Auth + streaming-safe reverse proxy. |
| `start.sh` | Container entrypoint: volume setup, auth, env injection, process supervision. |
| `.env.example` | Reference list of required/optional environment variables. |
| `.dockerignore` | Keeps the build context small and secrets out of the image. |
| `README.md` | This file. |

---

## 1. Railway Deployment Steps

### 1.1 Push the repo to GitHub

Fork this repository (or push it as-is) to a GitHub repo you control, then import it into Railway:

1. Go to [railway.app](https://railway.app) → **New Project** → **Deploy from GitHub repo**.
2. Select this repository. Railway will detect the `Dockerfile` automatically and use it to build the image — no other build configuration is needed.

### 1.2 Attach a persistent Volume

The container stores all durable state under `/data`. Without a Volume, that directory is ephemeral and everything is lost on every redeploy/restart.

1. Open your new service in the Railway dashboard.
2. Go to the **Volumes** tab.
3. Click **+ Add Volume**.
4. Set **Mount Path** to `/data`.
5. Save.

> Railway volumes attach to a single service instance. Do not scale this service beyond 1 replica — a second replica cannot share the same volume, and `dsh` is a stateful, single-writer process.

### 1.3 Set environment variables

In the service's **Variables** tab, add:

| Variable | Required | Description |
|---|---|---|
| `AUTH_USER` | ✅ | Basic Auth username for the web UI. |
| `AUTH_PASSWORD` | ✅ | Basic Auth password. Use a long, random value — see [Security Notice](#4-security-notice). |
| `OPENROUTER_API_KEY` | ✅ | Your OpenRouter API key (`sk-or-v1-...`), from [openrouter.ai/keys](https://openrouter.ai/keys). |
| `OPENROUTER_BASE_URL` | optional | Defaults to `https://openrouter.ai/api/v1`. Override only if you're proxying OpenRouter through something else. |
| `NODE_ENV` | optional | Defaults not set by the app; recommended `production`. |
| `PORT` | ❌ do not set | Injected automatically by Railway. Nginx binds to it at startup. |
| `DSH_INTERNAL_PORT` | optional | Internal port `dsh web` listens on behind Nginx. Defaults to `3080`; only change if it conflicts with something. |
| `EXTRA_TRUSTED_HOSTS` | optional | Comma/space-separated extra host(s) for `dsh`'s `/api` browser-trust fence — see [Section 1.4](#14-generate-a-public-domain). Only needed for a custom domain; the generated Railway domain is picked up automatically. |

You can copy `.env.example` as a starting point for local reference — Railway variables are set in the dashboard (or via `railway variables set`), not from a committed `.env` file.

### 1.4 Generate a public domain

1. Go to **Settings → Networking**.
2. Click **Generate Domain**. Railway will issue a public `*.up.railway.app` HTTPS domain and route it to the container's `$PORT`.
3. Visit the generated URL — you'll be prompted for the `AUTH_USER` / `AUTH_PASSWORD` credentials you configured above.

Once the deploy is live, every subsequent `git push` to the deployed branch triggers a new build and redeploy; the `/data` volume persists across all of them.

> **Why this matters beyond just reachability:** `dsh` itself rejects any request whose `Host` header isn't on its own trusted-host allowlist (a browser-trust/anti-DNS-rebinding fence, default loopback-only) — without this, the UI would load but every `/api` call would fail with `403`. `start.sh` reads Railway's auto-injected `RAILWAY_PUBLIC_DOMAIN` variable and passes it to `dsh web --trusted-host` automatically, so a generated domain works with no extra configuration. If you attach a **custom domain** instead (or in addition), add it to the `EXTRA_TRUSTED_HOSTS` variable (Section 1.3) or `dsh` will 403 requests arriving on it the same way.

---

## 2. Persistent Storage Layout

Everything that needs to survive a redeploy or restart lives under the `/data` volume mount:

- **`/data/workspace`** — the working directory `dsh` runs from. All git repositories you clone or the agent creates, along with any code modifications the agent makes, live here. This is effectively the agent's project sandbox.
- **`/data/dsh_home`** — set as `DSH_HOME`. Holds the harness's own configuration, chat/session histories, plugins, and logs, independent of any one project in `workspace/`.
- **`/data`** itself is set as `HOME`. This means `.gitconfig`, SSH keys (`~/.ssh`), credential stores, and shell history also land on the persistent volume — so once you `git config` an identity, add a credential helper, or drop in an SSH deploy key, it's available on every future deploy without repeating the setup.

Because `HOME=/data` and the volume mounts at `/data`, `workspace/` and `dsh_home/` are simply subdirectories alongside your dotfiles/SSH config at the volume root — nothing under `/data` is ever wiped by a redeploy; only removing the Volume itself (or its contents) does.

### Setting up git credentials once

Exec into the running service (via `railway ssh` or the Railway dashboard shell) and configure credentials the same way you would on any machine, e.g.:

```sh
git config --global user.name "Your Agent"
git config --global user.email "agent@example.com"
git config --global credential.helper store   # then clone once with a PAT in the URL to cache it
# or, for SSH:
mkdir -p ~/.ssh && printf '%s\n' "$SSH_PRIVATE_KEY" > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519
```

Since `~` resolves to `/data`, this only needs to be done once — it survives every future redeploy.

---

## 3. OpenRouter Setup & Model Selection

`dsh` speaks the OpenAI Chat Completions API. `start.sh` maps that directly onto OpenRouter, which exposes an OpenAI-compatible endpoint that fans out to many upstream model providers:

```sh
OPENAI_API_KEY="$OPENROUTER_API_KEY"
OPENAI_BASE_URL="https://openrouter.ai/api/v1"   # OpenRouter's OpenAI-compatible endpoint
OPENROUTER_API_KEY="$OPENROUTER_API_KEY"          # kept for any OpenRouter-specific integrations
```

Because the base URL is repointed at OpenRouter, any OpenAI-compatible model identifier that OpenRouter serves can be used — you are not limited to DeepSeek's own models.

**Recommended model identifiers:**

| Model ID | Notes |
|---|---|
| `deepseek/deepseek-r1` | DeepSeek's reasoning model — strong for complex, multi-step coding tasks. |
| `deepseek/deepseek-chat` | DeepSeek-V3 general-purpose chat/coding model, faster and cheaper than R1. |
| `anthropic/claude-3.7-sonnet` | Strong general coding/agentic performance via OpenRouter. |

Get your key at [openrouter.ai/keys](https://openrouter.ai/keys) and browse the full catalog (with live pricing) at [openrouter.ai/models](https://openrouter.ai/models). Set the active model from within the `dsh` web UI's model/session settings, or consult `dsh --help` / `dsh config --help` inside the container for any CLI-level default-model configuration your installed version of `@deepseek-ai/dsh` supports.

---

## 4. Security Notice

- **HTTP Basic Auth is your only public gate.** It stops unauthenticated internet traffic from reaching the harness, but the harness itself operates with full container-level shell execution inside the mounted `/data` volume. Anyone who authenticates can run arbitrary commands, read/write anything on the volume, and use your `OPENROUTER_API_KEY` to spend against your account. Treat `AUTH_PASSWORD` with the same care as a shell login credential — use a long, random value (not the placeholder in `.env.example`), and rotate it if it may have leaked.
- **This is a single-tenant admin tool, not a multi-user product.** Don't share the URL/credentials broadly; anyone with them has effectively the same access as someone with a shell on the box.
- Railway environment variables are encrypted at rest but are visible to anyone with access to the project/service in the Railway dashboard — scope project collaborator access accordingly.
- If you expect to run Railway's HTTP health checks against this service, note that Basic Auth on `/` will make them return `401`; leave the health check path unset (or use TCP-level checks) rather than weakening auth to accommodate it.
- Consider setting spend limits/alerts on your OpenRouter account, since a compromised or misused deployment can generate real API cost.

---

## Local Testing (optional)

You can build and run the image locally with Docker before deploying:

```sh
docker build -t dsh-railway .

docker run --rm -it \
  -p 8080:8080 \
  -v "$(pwd)/.data:/data" \
  -e AUTH_USER=admin \
  -e AUTH_PASSWORD=change_me_locally \
  -e OPENROUTER_API_KEY=sk-or-v1-your-key \
  dsh-railway
```

Then visit `http://localhost:8080` and log in with the Basic Auth credentials above. The bind-mounted `./.data` directory on your host stands in for the Railway Volume.

---

## Troubleshooting

- **502 / connection refused right after deploy** — `dsh web` may still be starting up. Check the service logs; if it consistently needs more than the built-in 2-second grace period, increase the `sleep 2` in `start.sh`.
- **502 that never clears, with deploy logs showing `dsh` crash on boot** (e.g. `Promise.withResolvers is not a function`, `node:zlib does not provide an export named createZstdDecompress`, `node:module does not provide an export named stripTypeScriptTypes`) — `dsh`'s plugin loader needs Node APIs newer than the image provides. This repo's `Dockerfile` already pins `node:24-slim` for this reason; if you've changed the base image, revert to Node 24+ (or newer, if a future `dsh` release needs it) rather than Node 20/22.
- **The UI loads (past Basic Auth) but nothing works — can't add a workspace, model list won't load, etc.** — check the browser's network tab or the deploy logs for `POST /api/host.describe`, `/api/host.listDirectory`, `/api/credentials.describe`, or `GET /api/events.mux` returning `403`. That's `dsh`'s own browser-trust fence rejecting the request's `Host` header, not an Nginx or auth problem. It should be handled automatically (see the note in [Section 1.4](#14-generate-a-public-domain)) — if it's still happening, confirm `RAILWAY_PUBLIC_DOMAIN` matches the domain you're actually visiting, or add that domain to `EXTRA_TRUSTED_HOSTS`.
- **Stuck in an auth prompt loop** — double-check `AUTH_USER` / `AUTH_PASSWORD` are actually set as Railway Variables (not just in a local `.env`), and that you're using the current values (the `.htpasswd` file is regenerated on every container start).
- **Streaming responses appear chunky/delayed instead of token-by-token** — confirm nothing sits in front of Nginx re-buffering the response; the `proxy_buffering off;` and `proxy_http_version 1.1;` settings in `nginx.conf` are required for real-time streaming and should not be removed.
- **Cloned repos / config disappear after a redeploy** — verify a Volume is actually attached at mount path `/data` (Section 1.2). Without it, `/data` is a fresh, empty directory on every deploy.
- **Container fails immediately with "AUTH_USER and AUTH_PASSWORD must both be set"** — one or both variables are missing from the service's Variables tab; the entrypoint refuses to start an unprotected instance by design.
