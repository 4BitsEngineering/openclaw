#!/usr/bin/env bash
# Convenience wrapper: launches OpenClaw with the content-generation
# overlay config. Equivalent to:
#   OPENCLAW_CONFIG_PATH=~/.openclaw/content/openclaw.json \
#   OPENCLAW_STATE_DIR=~/.openclaw/content \
#     bash start-ollama.sh

DIR="$(cd "$(dirname "$0")" && pwd)"
export OPENCLAW_CONFIG_PATH="$HOME/.openclaw/content/openclaw.json"
export OPENCLAW_STATE_DIR="$HOME/.openclaw/content"
exec "$DIR/start-ollama.sh" "$@"
