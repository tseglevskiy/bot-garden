# OpenClaw Bootstrap

Automated setup for [OpenClaw](https://github.com/openclaw/openclaw) — a self-hosted AI agent with Slack, Telegram, and web UI channels.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  docker compose                                 │
│                                                 │
│  ┌──────────────────┐  ┌──────────┐  ┌───────┐ │
│  │ openclaw-gateway  │  │ searxng   │  │whisper│ │
│  │ (Node.js agent)   │  │ (search)  │  │(CUDA) │ │
│  │ port 18789        │  │ port 8080 │  │  8000 │ │
│  └──────────────────┘  └──────────┘  └───────┘ │
│         │                                       │
│  ┌──────────────────┐                           │
│  │ openclaw-cli      │  (one-shot config cmds)  │
│  └──────────────────┘                           │
└─────────────────────────────────────────────────┘
```

## Quick Start

```bash
# 1. Clone this repo
git clone <this-repo> openclaw-bootstrap && cd openclaw-bootstrap

# 2. Clone OpenClaw source (from main branch)
git clone git@github.com:openclaw/openclaw.git openclaw

# 3. Copy env template and fill in keys
cp .env.example .env
# Edit .env: set OPENROUTER_API_KEY, SLACK/TELEGRAM tokens, DEPLOY_PROFILE

# 4. Run bootstrap
./bootstrap.sh
```

### Updating OpenClaw

```bash
cd openclaw && git pull && cd ..
# Rebuild image
docker build --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=python3 python3-pip jq make unzip ripgrep" \
  -t openclaw:local -f openclaw/Dockerfile openclaw
# Restart gateway
set -a; source .env; set +a
docker compose -f docker-compose.yml restart openclaw-gateway
```

## Deployment Profiles

Set `DEPLOY_PROFILE` in `.env`:

| Profile | Channels | GPU | Whisper | Use case |
|---|---|---|---|---|
| `slack` (default) | Slack + Web UI | No | No | Desktop/server, Slack primary |
| `telegram` | Telegram + Web UI | NVIDIA | Yes (CUDA) | GPU server, voice messages |

Both profiles include SearXNG (web search sidecar) and all shared config.

## What bootstrap.sh Does

1. **Builds** Docker image (`openclaw:local`) with extra packages (python3, jq, ripgrep, etc.)
2. **Onboards** with OpenRouter as AI provider (non-interactive)
3. **Configures:**
   - Gateway: local mode, LAN bind, device auto-approval
   - Tool profile: `coding` (read/write/exec/web/memory/sessions/cron)
   - Models: curated allowlist of latest-gen models via OpenRouter (edit `models_allowlist.json`)
   - Audio: Whisper transcription (telegram profile only)
   - Hooks: session-memory (saves last 100 messages on `/new` or `/reset`)
4. **Starts** gateway + sidecars

## Files

### Configuration (committed)

| File | Purpose |
|---|---|
| `bootstrap.sh` | Automated setup script |
| `.env.example` | Template with all env vars and docs |
| `models_allowlist.json` | Curated model list for OpenRouter |
| `filter_models.sh` | Script to regenerate model list from OpenRouter API |
| `searxng_config/` | SearXNG configuration (engines, settings) |
| `docker_workspace/` | Agent workspace seed files (AGENTS.md, SOUL.md, etc.) |

### Agent Workspace Files

| File | Purpose | Modified by |
|---|---|---|
| `AGENTS.md` | Agent behavior rules, memory system, heartbeat protocol | Human + Agent |
| `SOUL.md` | Personality, values, boundaries | Human (agent may evolve) |
| `BOOTSTRAP.md` | First-boot onboarding flow (deleted after use) | Agent deletes |
| `IDENTITY.md` | Agent name/vibe/emoji (filled during onboarding) | Agent |
| `USER.md` | Info about the human (learned over time) | Agent |
| `TOOLS.md` | Local services (SearXNG, Whisper) + environment notes | Human |
| `HEARTBEAT.md` | Periodic task checklist | Agent |

### Per-Machine (gitignored)

| File | Purpose |
|---|---|
| `.env` | Secrets (API keys, tokens) |
| `docker_config/` | OpenClaw config, sessions, identity |
| `openclaw/` | Cloned OpenClaw source |

## Key Decisions

### AI Provider: OpenRouter Only
All models routed through OpenRouter (`openrouter/<provider>/<model>`). No direct provider keys needed. Model allowlist in `models_allowlist.json` — regenerate with `./filter_models.sh`.

### Security
- **Exec approvals**: Agent cannot execute commands without human approval
- **No skill installation**: Agent cannot install skills from ClawHub (rule in AGENTS.md)
- **Secrets**: Only in `.env`, never in committed files. Containers see them as env vars.
- **Device auth**: Disabled for web UI (`dangerouslyDisableDeviceAuth`) since running locally

### Memory System (3 layers)
1. **Session transcripts** — full JSONL logs, auto-archived on `/new` (always)
2. **`memory/` files** — last 100 messages saved by session-memory hook (on `/new`/`/reset`)
3. **`MEMORY.md`** — curated long-term memory, maintained by agent during heartbeats

### Web Search: SearXNG Sidecar
Local metasearch engine aggregating DuckDuckGo + Brave + Bing. Agent uses `web_fetch` to query `http://searxng:8080/search?q=QUERY&format=json`. No API keys needed.

### Audio: Whisper Sidecar (telegram profile)
`faster-whisper-server` with CUDA. OpenAI-compatible API. Automatically transcribes Telegram voice messages. Requires NVIDIA GPU + `nvidia-container-toolkit` on host.

## Common Operations

```bash
# Source env before any docker compose command
set -a; source .env; set +a

# View logs
docker compose -f docker-compose.yml logs -f openclaw-gateway

# Restart gateway (after manual config changes)
docker compose -f docker-compose.yml restart openclaw-gateway

# Run CLI commands
docker compose -f docker-compose.yml run --rm openclaw-cli <command>

# Examples:
# ... config get agents.defaults.model
# ... config set tools.profile coding
# ... pairing list telegram
# ... pairing approve telegram <CODE>
# ... hooks list
# ... security audit

# Stop everything
docker compose -f docker-compose.yml down

# Rebuild image (after openclaw/ repo update)
docker build --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=python3 python3-pip jq make unzip ripgrep" \
  -t openclaw:local -f openclaw/Dockerfile openclaw

# Refresh model allowlist
./filter_models.sh
# Review models_kept.tsv and models_removed.tsv, then:
docker compose -f docker-compose.yml run --rm openclaw-cli \
  config set agents.defaults.models "$(jq -c '.' models_allowlist.json)" --strict-json
docker compose -f docker-compose.yml restart openclaw-gateway
```

## Chat Commands

| Command | What it does |
|---|---|
| `/new` | Start fresh session (saves memory via hook) |
| `/reset` | Reset current session |
| `/model <name>` | Switch model for this session |
| `/model` | Show current model |
| `/models` | List available providers |
| `/models <provider>` | List provider's models |
| `/status` | Session status (tokens, cost, model) |

## Setting Up a New Machine

1. Clone this repo + OpenClaw source
2. Copy `.env.example` → `.env`, set `DEPLOY_PROFILE` and tokens
3. Run `./bootstrap.sh`
4. For Telegram: approve pairing with `openclaw-cli pairing approve telegram <CODE>`

## Diary

See `DIARY.md` for the full session diary from initial setup (2026-03-05).
