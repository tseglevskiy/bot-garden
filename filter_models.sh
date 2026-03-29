#!/usr/bin/env bash
# filter_models.sh — Fetch OpenRouter models, filter to latest gen, output kept/removed lists
#
# Usage:
#   ./filter_models.sh
#
# Outputs:
#   models_kept.tsv    — models that pass all filters (review these)
#   models_removed.tsv — models that were filtered out (review these too)
#   models_allowlist.json — ready to apply to OpenClaw
#
# After review, apply with:
#   source .env && docker compose -f openclaw/docker-compose.yml run --rm openclaw-cli \
#     config set agents.defaults.models "$(jq -c '.' models_allowlist.json)" --strict-json

set -euo pipefail

echo "==> Fetching models from OpenRouter API..."
ALL=$(curl -s https://openrouter.ai/api/v1/models)

# Parse into TSV: id, name, context_length, price_per_input_token
echo "$ALL" | jq -r '.data[] | "openrouter/\(.id)\t\(.name)\t\(.context_length // 0)\t\(.pricing.prompt // "0")"' | sort > /tmp/or_all_models.tsv

TOTAL=$(wc -l < /tmp/or_all_models.tsv)
echo "   Total models on OpenRouter: $TOTAL"

# ---------------------------------------------------------------------------
# FILTER 1: Context window >= 100,000
# ---------------------------------------------------------------------------
awk -F'\t' '$3 >= 100000' /tmp/or_all_models.tsv > /tmp/or_pass1.tsv
F1_KEPT=$(wc -l < /tmp/or_pass1.tsv)
echo "   After context >= 100k: $F1_KEPT"

# ---------------------------------------------------------------------------
# FILTER 2: Only known major providers
# (add providers here to include them)
# ---------------------------------------------------------------------------
PROVIDERS="anthropic|openai|google|deepseek|meta-llama|qwen|mistralai|x-ai|moonshotai|minimax|perplexity|amazon|cohere|openrouter"
grep -E "openrouter/($PROVIDERS)/" /tmp/or_pass1.tsv > /tmp/or_pass2.tsv || true
F2_KEPT=$(wc -l < /tmp/or_pass2.tsv)
echo "   After provider filter: $F2_KEPT"

# ---------------------------------------------------------------------------
# FILTER 3: Remove old generations
# Each line is: "pattern  # reason"
# ---------------------------------------------------------------------------
cat > /tmp/or_remove_patterns.txt << 'PATTERNS'
# --- Anthropic: keep 4.5+ only ---
claude-3-haiku
claude-3\.5-haiku
claude-3\.5-sonnet
claude-3\.7-sonnet
claude-sonnet-4[^.]
claude-opus-4[^.]
claude-opus-4\.1[^0-9]
# --- OpenAI: keep GPT-4.1, latest GPT-5 per specialization, o4, deep-research ---
gpt-4-turbo
gpt-4-1106
gpt-4o-2024
gpt-4o-mini-2024
gpt-4o-audio
gpt-4o-search
gpt-4o:extended
gpt-4o-mini[^-]
gpt-4o[^-]
gpt-audio[^-]
gpt-audio-mini
gpt-oss
# GPT-5.0 base variants (superseded by 5.4/5.3 equivalents)
gpt-5-chat[^0-9]
gpt-5-codex[^0-9]
gpt-5-mini[^0-9]
gpt-5-nano[^0-9]
gpt-5-pro[^0-9]
gpt-5[^.-]
# GPT-5.1 (superseded; keep codex-max/codex-mini as unique)
gpt-5\.1[^-]
gpt-5\.1-chat
gpt-5\.1-codex[^-]
# GPT-5.2 (superseded)
gpt-5\.2[^-]
gpt-5\.2-chat
gpt-5\.2-codex
gpt-5\.2-pro
# GPT-5.3 base (superseded by 5.4; keep chat/codex as latest in their line)
gpt-5\.3[^-]
# o-series: keep o4 + deep-research
o1[^-]
o1-pro
o3[^-]
o3-mini
o3-pro
# --- Google: keep 3.x and 2.5 ---
gemini-2\.0
gemma-
# --- Meta: keep Llama 4 ---
llama-3\.1
llama-3\.2
llama-3\.3
llama-guard
# --- DeepSeek: keep V3.2 and deep-research ---
deepseek-chat[^-]
deepseek-r1-distill
deepseek-r1-0528
deepseek-v3\.1
# --- Mistral: keep latest (Small 4, Medium 3.1, Large 3, Devstral 2) ---
mistral-large-24
mistral-large[^-]
mistral-nemo
pixtral
mistral-small-3\.[12]
mistral-medium-3[^.]
codestral
devstral-small
devstral-medium
ministral
# --- xAI: keep Grok 4.x+ ---
grok-3[^-]
grok-3-beta
grok-3-mini
# --- Moonshot: keep K2.5 ---
kimi-k2[^.]
kimi-k2-0905
kimi-k2-thinking
# --- MiniMax: keep M2.7 ---
minimax-01
minimax-m1[^.]
minimax-m2[^.]
minimax-m2\.1
minimax-m2\.5
# --- Qwen: keep 3.5, coder ---
qwen-turbo
qwen-vl
qwen2\.5
qwq
qwen-plus
qwen3-235b
qwen3-30b
qwen3-max
qwen3-next
qwen3-vl
# --- Amazon: keep Nova 2 ---
nova-lite-v1
nova-micro-v1
nova-premier-v1
nova-pro-v1
# --- Cohere: old ---
command-r-08
command-r-plus
command-r7b
# --- Perplexity: keep deep-research, pro-search, reasoning-pro ---
sonar[^-]
# --- OpenRouter meta-models: keep auto only ---
bodybuilder
free
PATTERNS

# Build grep -E pattern (skip comments and blank lines)
REMOVE_PATTERN=$(grep -v '^#' /tmp/or_remove_patterns.txt | grep -v '^\s*$' | paste -sd'|' -)

# Apply filter
grep -v -E "$REMOVE_PATTERN" /tmp/or_pass2.tsv > /tmp/or_pass3.tsv || true

# Manually ensure deep-research models survive (they match "o3" pattern but should stay)
grep "deep-research" /tmp/or_pass2.tsv >> /tmp/or_pass3.tsv 2>/dev/null || true
sort -u /tmp/or_pass3.tsv > /tmp/or_kept.tsv

F3_KEPT=$(wc -l < /tmp/or_kept.tsv)
echo "   After old-gen removal: $F3_KEPT"

# ---------------------------------------------------------------------------
# Always include openrouter/auto
# ---------------------------------------------------------------------------
if ! grep -q "openrouter/auto" /tmp/or_kept.tsv; then
  echo "openrouter/openrouter/auto	Auto Router	2000000	-1" >> /tmp/or_kept.tsv
  sort -u /tmp/or_kept.tsv -o /tmp/or_kept.tsv
fi

# ---------------------------------------------------------------------------
# Build removed list (everything in pass2 that's NOT in kept)
# ---------------------------------------------------------------------------
comm -23 <(sort /tmp/or_pass2.tsv) <(sort /tmp/or_kept.tsv) > /tmp/or_removed.tsv

# ---------------------------------------------------------------------------
# Output files
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp /tmp/or_kept.tsv "$SCRIPT_DIR/models_kept.tsv"
cp /tmp/or_removed.tsv "$SCRIPT_DIR/models_removed.tsv"

# Build JSON allowlist
(echo '{'; awk -F'\t' 'NR>0 {if(NR>1)printf ","; printf "\"%s\":{}", $1}' /tmp/or_kept.tsv; echo '}') | jq '.' > "$SCRIPT_DIR/models_allowlist.json"

FINAL=$(jq 'keys | length' "$SCRIPT_DIR/models_allowlist.json")
REMOVED=$(wc -l < "$SCRIPT_DIR/models_removed.tsv")

echo ""
echo "==> Done."
echo "   KEPT:    $FINAL models → models_kept.tsv + models_allowlist.json"
echo "   REMOVED: $REMOVED models → models_removed.tsv"
echo ""
echo "Review both files, then apply:"
echo "   source .env && docker compose -f openclaw/docker-compose.yml run --rm openclaw-cli \\"
echo "     config set agents.defaults.models \"\$(jq -c '.' models_allowlist.json)\" --strict-json"
