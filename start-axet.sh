#!/usr/bin/env bash
# Convenience wrapper: launches axet-gateway as a sidecar (port 4010),
# completes Okta device-flow, and only then launches OpenClaw.
#
# Pre-requisite: a sibling axet-gateway repo with a populated .env
#   ../axet-gateway/.env  ← AXET_GATEWAY_TOKEN, OKTA_*, AXET_*
# Real OKTA_ISSUER + OKTA_CLIENT_ID + AXET_PROJECT_ID are required;
# placeholder values produce a 502 from Okta.
#
# Usage:
#   bash start-axet.sh                              # local config + auth
#   bash start-axet.sh --skip-auth                  # smoke (boots without auth)
#   bash start-axet.sh tui                          # any openclaw subcommand

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
GW_DIR="$(cd "$DIR/../axet-gateway" 2>/dev/null && pwd || true)"
SKIP_AUTH=0

# Filter --skip-auth out of args before passing to start-ollama.sh
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--skip-auth" ]; then SKIP_AUTH=1; continue; fi
  ARGS+=("$arg")
done

if [ -z "$GW_DIR" ] || [ ! -f "$GW_DIR/gateway/axet-ai-gateway.server.cjs" ]; then
  echo "axet-gateway not found at $DIR/../axet-gateway"
  echo "Clone https://github.com/jotajota1302/axet-gateway alongside openclaw"
  exit 1
fi

if [ ! -f "$GW_DIR/.env" ]; then
  echo "axet-gateway/.env missing — copy and fill in:"
  echo "  AXET_GATEWAY_TOKEN, OKTA_ISSUER, OKTA_CLIENT_ID, AXET_PROJECT_ID"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$GW_DIR/.env"
set +a

# openclaw.json's "${AXET_GATEWAY_TOKEN}" placeholder needs the same value
# the sidecar enforces.
export AXET_GATEWAY_TOKEN

# ─── 1. axet-gateway sidecar ──────────────────────────────────────────────────
if curl -fs http://127.0.0.1:4010/v1/health >/dev/null 2>&1; then
  echo "[axet] axet-gateway already running on :4010 — reusing."
  GW_REUSED=1
else
  echo "[axet] starting axet-gateway on :4010..."
  ( cd "$GW_DIR" && node gateway/axet-ai-gateway.server.cjs >"$DIR/.axet-gateway.log" 2>&1 ) &
  AXET_PID=$!
  GW_REUSED=0
  trap 'echo "[axet] stopping axet-gateway (pid '"$AXET_PID"')..."; kill "$AXET_PID" 2>/dev/null || true' EXIT INT TERM
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fs http://127.0.0.1:4010/v1/health >/dev/null 2>&1; then
      echo "[axet] axet-gateway ready."
      break
    fi
    sleep 1
  done
  if ! curl -fs http://127.0.0.1:4010/v1/health >/dev/null 2>&1; then
    echo "[axet] axet-gateway failed to come up — see $DIR/.axet-gateway.log"
    exit 1
  fi
fi

# ─── 2. Okta device-flow ─────────────────────────────────────────────────────
if [ "$SKIP_AUTH" = "1" ]; then
  echo "[axet] --skip-auth: skipping Okta device-flow (inference will fail until you POST /v1/auth/start)."
else
  AUTH_STATUS=$(curl -fs http://127.0.0.1:4010/v1/auth/status 2>/dev/null || echo '{}')
  ALREADY_AUTH=$(echo "$AUTH_STATUS" | node -e "let s='';process.stdin.on('data',c=>s+=c).on('end',()=>{try{console.log(JSON.parse(s).authenticated?'yes':'no')}catch{console.log('no')}})")

  if [ "$ALREADY_AUTH" = "yes" ]; then
    echo "[axet] gateway already authenticated — skipping device-flow."
  else
    echo "[axet] starting Okta device-flow..."
    START_RES=$(curl -fs -X POST http://127.0.0.1:4010/v1/auth/start 2>/dev/null || true)
    if [ -z "$START_RES" ]; then
      echo "[axet] /v1/auth/start failed (Okta unreachable or env vars wrong)."
      echo "       Check OKTA_ISSUER and OKTA_CLIENT_ID in $GW_DIR/.env."
      exit 1
    fi
    USER_CODE=$(echo "$START_RES" | node -e "let s='';process.stdin.on('data',c=>s+=c).on('end',()=>{try{console.log(JSON.parse(s).user_code||'')}catch{console.log('')}})")
    VERIFY_URI=$(echo "$START_RES" | node -e "let s='';process.stdin.on('data',c=>s+=c).on('end',()=>{try{console.log(JSON.parse(s).verification_uri||'')}catch{console.log('')}})")

    echo ""
    echo "  Axet — Okta Device Authorization"
    echo ""
    echo "  Open in your browser:"
    echo "    $VERIFY_URI"
    echo ""
    echo "  Code: $USER_CODE"
    echo ""
    echo "[axet] waiting for authorization (polling /v1/auth/status)..."

    # Poll up to ~10 minutes (Okta default device-code TTL)
    AUTHED=0
    for i in $(seq 1 120); do
      sleep 5
      AUTH_STATUS=$(curl -fs http://127.0.0.1:4010/v1/auth/status 2>/dev/null || echo '{}')
      AUTHED_NOW=$(echo "$AUTH_STATUS" | node -e "let s='';process.stdin.on('data',c=>s+=c).on('end',()=>{try{console.log(JSON.parse(s).authenticated?'yes':'no')}catch{console.log('no')}})")
      if [ "$AUTHED_NOW" = "yes" ]; then
        AUTHED=1
        echo "[axet] authenticated."
        break
      fi
    done
    if [ "$AUTHED" != "1" ]; then
      echo "[axet] authorization timed out — aborting."
      exit 1
    fi
  fi
fi

# Make the trap inert if the sidecar was reused — don't kill someone else's process.
if [ "$GW_REUSED" = "1" ]; then trap - EXIT INT TERM; fi

# Sanity: openclaw.json is local per-machine config (gitignored), so the
# axet provider block has to be pasted in once. Warn instead of failing
# so a half-configured machine still boots — the gateway just won't list
# axet/* models in /api/gateway/models, which is silent at the UI level.
ACTIVE_CFG="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
if [ -f "$ACTIVE_CFG" ] && ! grep -q '"axet"[[:space:]]*:' "$ACTIVE_CFG"; then
  echo ""
  echo "[axet] WARNING: active config has no \"axet\" provider block:"
  echo "         $ACTIVE_CFG"
  echo "       Paste the snippet from $DIR/start-axet.README.md under models.providers,"
  echo "       otherwise axet/gpt-* models won't appear in the work-console agent UI."
  echo ""
fi

echo "[axet] launching openclaw..."
exec "$DIR/start-ollama.sh" "${ARGS[@]}"
