# Bootstrap Diary

## 2026-03-05

### Cloned openclaw/openclaw

Cloned the main OpenClaw repo from GitHub into `openclaw/`.

### Docker Support Investigation

Docker support is fully prepared. Summary:

**Files:**
- `Dockerfile` — builds from `node:22-bookworm`, pnpm + Bun, runs as non-root `node` user, port `18789`, built-in `HEALTHCHECK`. Optional build args:
  - `OPENCLAW_DOCKER_APT_PACKAGES` — extra apt packages baked into image
  - `OPENCLAW_INSTALL_BROWSER` — bakes in Chromium/Playwright (~+300MB)
  - `OPENCLAW_INSTALL_DOCKER_CLI` — adds Docker CLI for agent sandboxing (~+50MB)
- `docker-compose.yml` — two services: `openclaw-gateway` (server) and `openclaw-cli` (shares gateway network namespace). Configured via `.env`.
- `docker-setup.sh` — one-stop setup: builds image (or pulls pre-built), runs onboarding wizard, generates token, starts gateway.
- `Dockerfile.sandbox`, `Dockerfile.sandbox-browser` — sandbox isolation images.
- `docs/install/docker.md` — full guide.

**Pre-built images:** `ghcr.io/openclaw/openclaw` — tags: `latest`, `main`, per-version (e.g. `2026.2.26`).

**Quickest way to run:**

```bash
# Option A: build from source
./docker-setup.sh

# Option B: use pre-built image (skip local build)
export OPENCLAW_IMAGE="ghcr.io/openclaw/openclaw:latest"
./docker-setup.sh
```

Then open `http://127.0.0.1:18789/` and paste in the generated token.

### Non-Interactive (Automated) Onboarding

The `onboard` command has a fully non-interactive mode — no wizard, no prompts. Everything is passed as CLI flags.

**Required flags:**
- `--non-interactive` — skips all prompts
- `--accept-risk` — required acknowledgement for headless setup
- `--mode local` — local gateway mode
- `--no-install-daemon` — Docker manages the process, not a system daemon

**Auth choices** (`--auth-choice <value>`): `anthropic-api-key`, `openai-api-key`, `openrouter-api-key`, `gemini-api-key`, `mistral-api-key`, `litellm-api-key`, `custom-api-key`, `setup-token`, `openai-codex`, `github-copilot`, `skip`, and many more.

**Corresponding key flags:**
| Flag | Provider |
|---|---|
| `--anthropic-api-key` | Anthropic |
| `--openai-api-key` | OpenAI |
| `--openrouter-api-key` | OpenRouter |
| `--gemini-api-key` | Google Gemini |
| `--mistral-api-key` | Mistral |
| `--litellm-api-key` | LiteLLM |
| `--custom-base-url` + `--custom-api-key` + `--custom-model-id` | Custom OpenAI-compat |

**Other useful flags:** `--gateway-token`, `--gateway-bind`, `--gateway-port`, `--skip-health`, `--skip-channels`, `--json`

**Minimal example:**
```bash
docker compose run --rm openclaw-cli onboard \
  --non-interactive \
  --accept-risk \
  --mode local \
  --no-install-daemon \
  --auth-choice anthropic-api-key \
  --anthropic-api-key "$ANTHROPIC_API_KEY" \
  --gateway-token "$OPENCLAW_GATEWAY_TOKEN" \
  --gateway-bind lan \
  --gateway-port 18789 \
  --skip-health \
  --skip-channels
```

See `bootstrap.sh` for a ready-to-use automated setup script.

### Setup Files Created

- `.env.example` — template with all vars and instructions where to get each key
- `.env` — actual secrets (gitignored)
- `.gitignore` — ignores `.env` and `data/`
- `bootstrap.sh` — fully automated setup script

### Two-Step Deployment Plan

**Step 1 — bootstrap.sh:** sets up AI provider + gateway, starts container.
**Step 2 — configure Slack:** after gateway is running, configure Slack via `openclaw config set`. No need to touch `--skip-channels` — Slack auto-enables from env vars at runtime (detected in `plugin-auto-enable.ts` and `slack/accounts.ts`). Gateway just needs `SLACK_BOT_TOKEN` + `SLACK_APP_TOKEN` in its environment.

### Container Contents

Base image `node:22-bookworm`. Included: Node 22, npm, pnpm, Bun, git, curl, find, grep, sed, awk.
Missing by default: Python, jq, make, unzip, ripgrep.

**Fix:** build from source with `OPENCLAW_DOCKER_APT_PACKAGES`. Set in `.env`:
```
OPENCLAW_IMAGE=openclaw:local
OPENCLAW_DOCKER_APT_PACKAGES="python3 python3-pip jq make unzip ripgrep"
```
`bootstrap.sh` passes this as `--build-arg` automatically.

### Persistent Storage

Config and data are mapped to host folders (not Docker volumes) for easy inspection:
- Default: `~/.openclaw/` and `~/.openclaw/workspace/`
- Local to project: set `OPENCLAW_CONFIG_DIR=./data` in `.env`

### Web UI & First Login

First access: `http://127.0.0.1:18789/` — paste `OPENCLAW_GATEWAY_TOKEN` to log in.

The browser shows a **device pairing** screen on first visit. To approve:

```bash
# Load env vars first (required for docker compose to have correct paths)
set -a; source .env; set +a

# List pending devices
docker compose -f openclaw/docker-compose.yml run --rm openclaw-cli devices list

# Approve the pending request ID shown in the table
docker compose -f openclaw/docker-compose.yml run --rm openclaw-cli devices approve <requestId>
```

Then refresh the browser.

### Env Vars Gotcha

`OPENCLAW_CONFIG_DIR` and `OPENCLAW_WORKSPACE_DIR` must be explicitly set in `.env` — docker-compose.yml has no defaults for them. If unset, docker compose fails with `invalid spec: :/home/node/.openclaw: empty section between colons`.

Also: always `set -a; source .env; set +a` before running docker compose commands directly (bootstrap.sh does this automatically).

### Data Directories

Config and workspace are mapped to local folders for easy inspection:
```
OPENCLAW_CONFIG_DIR=/Users/igor/p/83_openclaw_bootstrap/docker_config
OPENCLAW_WORKSPACE_DIR=/Users/igor/p/83_openclaw_bootstrap/docker_workspace
```
Both folders must exist before running bootstrap (create with `mkdir docker_config docker_workspace`).

### Production Deployment Plan

Target: dedicated Kubernetes cluster with read-only `gcloud` + `kubectl` access.
Users: infra team, access controlled via Tailscale ACLs.
Primary UI: Slack (individual DM sessions per user, private history).
Web UI: shared/admin view only.

### Tailscale in Kubernetes

Plan: **manual sidecar** (not the Tailscale Kubernetes operator).

- Add `tailscale/tailscale` container to the OpenClaw pod
- Pass Tailscale auth key via a Kubernetes Secret
- Run in **serve mode** so Tailscale proxies traffic and injects `tailscale-user-login` / `tailscale-user-name` headers
- Enable "Gateway Auth Allow Tailscale Identity" in OpenClaw settings so those headers are trusted for auth
- Access control via Tailscale ACLs — restrict which Tailnet members can reach the pod port

This gives teammates passwordless access (no token sharing) while keeping non-members out at the network level.

### Gateway Bind Mode: tailnet

OpenClaw has a `tailnet` bind mode (`--bind tailnet`) that binds the gateway exclusively to the Tailscale IPv4 address (`100.x.x.x` range) — not localhost, not LAN. The port is completely invisible outside of Tailnet.

For Kubernetes: set `--bind tailnet` + Tailscale sidecar in serve mode. No firewall rules needed, no accidental exposure. Access only via `100.x.x.x:18789` on the Tailnet.





Making a bot from manifest:

```
{
  "display_information": {
    "name": "IfraClaw",
    "description": "InfraClaw AI Agent",
    "background_color": "#000000"
  },
  "features": {
    "app_home": {
      "home_tab_enabled": false,
      "messages_tab_enabled": true,
      "messages_tab_read_only_enabled": false
    },
    "bot_user": {
      "display_name": "OpenClaw",
      "always_online": true
    }
  },
  "oauth_config": {
    "scopes": {
"bot": [
    "app_mentions:read",
    "channels:history",
    "channels:read",
    "chat:write",
    "groups:history",
    "groups:read",
    "im:history",
    "im:read",
    "im:write",
    "mpim:history",
    "mpim:read",
    "pins:read",
    "reactions:read"
]
    }
  },
  "settings": {
    "event_subscriptions": {
      "bot_events": [
        "app_mention",
        "message.channels",
        "message.groups",
        "message.im",
        "message.mpim",
        "reaction_added",
        "reaction_removed",
        "member_joined_channel",
        "member_left_channel",
        "channel_rename",
        "pin_added",
        "pin_removed"
      ]
    },
    "interactivity": {
      "is_enabled": true
    },
    "org_deploy_enabled": false,
    "socket_mode_enabled": true,
    "token_rotation_enabled": false
  }
}

```