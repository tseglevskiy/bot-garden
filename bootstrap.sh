#!/usr/bin/env bash
# bootstrap.sh — Fully automated OpenClaw Docker setup (no interactive wizard)
#
# Usage:
#   cp .env.example .env        # fill in your keys
#   ./bootstrap.sh
#
# Or pass vars inline:
#   OPENROUTER_API_KEY=sk-or-... ./bootstrap.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via env vars or a .env file
# ---------------------------------------------------------------------------

# Load .env if present
if [[ -f "$(dirname "$0")/.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "$(dirname "$0")/.env"
  set +a
fi

# Image: use pre-built from GHCR or set OPENCLAW_IMAGE=openclaw:local to build from source
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"

# Gateway
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-$HOME/.openclaw/workspace}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
OPENCLAW_BRIDGE_PORT="${OPENCLAW_BRIDGE_PORT:-18790}"
OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"

# Generate a token if not provided
if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
  else
    OPENCLAW_GATEWAY_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  fi
fi

# AI provider — OpenRouter only
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "ERROR: OPENROUTER_API_KEY is required. Set it in .env or environment." >&2
  exit 1
fi

# Deployment profile: "slack" (default) or "telegram"
#   slack    — Slack channels, no GPU, no Whisper
#   telegram — Telegram channels, GPU + Whisper sidecar
DEPLOY_PROFILE="${DEPLOY_PROFILE:-slack}"
if [[ "$DEPLOY_PROFILE" != "slack" && "$DEPLOY_PROFILE" != "telegram" ]]; then
  echo "ERROR: DEPLOY_PROFILE must be 'slack' or 'telegram' (got: $DEPLOY_PROFILE)" >&2
  exit 1
fi
echo "==> Profile: $DEPLOY_PROFILE"

# ---------------------------------------------------------------------------
# Export for docker-compose
# ---------------------------------------------------------------------------

export OPENCLAW_IMAGE
export OPENCLAW_CONFIG_DIR
export OPENCLAW_WORKSPACE_DIR
export OPENCLAW_GATEWAY_PORT
export OPENCLAW_BRIDGE_PORT
export OPENCLAW_GATEWAY_BIND
export OPENCLAW_GATEWAY_TOKEN

# ---------------------------------------------------------------------------
# Prepare directories
# ---------------------------------------------------------------------------

mkdir -p "$OPENCLAW_CONFIG_DIR/identity"
mkdir -p "$OPENCLAW_CONFIG_DIR/agents/main/agent"
mkdir -p "$OPENCLAW_CONFIG_DIR/agents/main/sessions"
mkdir -p "$OPENCLAW_WORKSPACE_DIR"

# ---------------------------------------------------------------------------
# Pull or build image
# ---------------------------------------------------------------------------

COMPOSE_FILE="$(dirname "$0")/openclaw/docker-compose.yml"

if [[ "$OPENCLAW_IMAGE" == "openclaw:local" ]]; then
  echo "==> Building Docker image: $OPENCLAW_IMAGE"
  BUILD_ARGS=()
  if [[ -n "${OPENCLAW_DOCKER_APT_PACKAGES:-}" ]]; then
    BUILD_ARGS+=(--build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES}")
  fi
  docker build \
    "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}" \
    -t "$OPENCLAW_IMAGE" \
    -f "$(dirname "$0")/openclaw/Dockerfile" \
    "$(dirname "$0")/openclaw"
else
  echo "==> Pulling Docker image: $OPENCLAW_IMAGE"
  docker pull "$OPENCLAW_IMAGE"
fi

# ---------------------------------------------------------------------------
# Fix data-directory permissions (node uid=1000)
# ---------------------------------------------------------------------------

echo "==> Fixing data-directory permissions"
docker compose -f "$COMPOSE_FILE" run --rm --user root --entrypoint sh openclaw-cli -c \
  'find /home/node/.openclaw -xdev -exec chown node:node {} +; \
   [ -d /home/node/.openclaw/workspace/.openclaw ] && chown -R node:node /home/node/.openclaw/workspace/.openclaw || true'

# ---------------------------------------------------------------------------
# Non-interactive onboarding
# ---------------------------------------------------------------------------

echo "==> Running non-interactive onboarding (OpenRouter)"
docker compose -f "$COMPOSE_FILE" run --rm openclaw-cli onboard \
  --non-interactive \
  --accept-risk \
  --mode local \
  --no-install-daemon \
  --auth-choice openrouter-api-key \
  --openrouter-api-key "$OPENROUTER_API_KEY" \
  --gateway-token "$OPENCLAW_GATEWAY_TOKEN" \
  --gateway-bind "$OPENCLAW_GATEWAY_BIND" \
  --gateway-port "$OPENCLAW_GATEWAY_PORT" \
  --skip-health \
  --skip-channels

# Pin gateway mode, bind, and auto-approve web UI devices
docker compose -f "$COMPOSE_FILE" run --rm openclaw-cli config set gateway.mode local
docker compose -f "$COMPOSE_FILE" run --rm openclaw-cli config set gateway.bind "$OPENCLAW_GATEWAY_BIND"
docker compose -f "$COMPOSE_FILE" run --rm openclaw-cli config set gateway.controlUi.dangerouslyDisableDeviceAuth true

# Set tool profile to coding (read/write/exec/web/memory/sessions/cron)
docker compose -f "$COMPOSE_FILE" run --rm openclaw-cli config set tools.profile coding

# Model allowlist — latest-gen models routed through OpenRouter (edit models_allowlist.json to change)
docker compose -f "$COMPOSE_FILE" run --rm openclaw-cli config set agents.defaults.models \
  "$(cat "$(dirname "$0")/models_allowlist.json")" --strict-json

# Enable audio transcription via local Whisper sidecar (telegram profile only)
if [[ "$DEPLOY_PROFILE" == "telegram" ]]; then
  docker compose -f "$COMPOSE_FILE" run --rm openclaw-cli config set tools.media.audio.enabled true
  docker compose -f "$COMPOSE_FILE" run --rm openclaw-cli config set tools.media.audio.models \
    '[{"provider":"openai","model":"Systran/faster-whisper-large-v3","baseUrl":"http://whisper:8000/v1"}]' --strict-json
fi

# Enable session-memory hook (save last 100 messages on /new and /reset)
docker compose -f "$COMPOSE_FILE" run --rm openclaw-cli config set hooks.internal.enabled true
docker compose -f "$COMPOSE_FILE" run --rm openclaw-cli config set hooks.internal.entries.session-memory '{"enabled":true,"messages":100}' --strict-json

# ---------------------------------------------------------------------------
# Start gateway
# ---------------------------------------------------------------------------

echo "==> Restarting gateway (apply config) and starting sidecars ($DEPLOY_PROFILE)"
if [[ "$DEPLOY_PROFILE" == "telegram" ]]; then
  docker compose -f "$COMPOSE_FILE" --profile telegram up -d --force-recreate openclaw-gateway searxng whisper
else
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate openclaw-gateway searxng
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "OpenClaw gateway is running."
echo "  URL:   http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/"
echo "  Token: $OPENCLAW_GATEWAY_TOKEN"
echo ""
echo "Health check:"
echo "  curl -fsS http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/healthz"
echo ""
echo "Logs:"
echo "  docker compose -f $COMPOSE_FILE logs -f openclaw-gateway"
