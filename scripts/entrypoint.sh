#!/bin/sh
set -e

# Substitute environment variables in the template

export MODEL_PRIMARY="${MODEL_PRIMARY:-litellm/gemini-3.1-pro-preview}"
export MODEL_FALLBACKS="${MODEL_FALLBACKS:-[\"litellm/gemini-3.1-flash-lite-preview\"]}"
export GATEWAY_AUTH_TOKEN="${GATEWAY_AUTH_TOKEN:-}"

envsubst '$MODEL_PRIMARY,$MODEL_FALLBACKS,$GATEWAY_AUTH_TOKEN' < /app/openclaw.json.template > /app/openclaw.json

# Use persistent state dir on PVC so pairings survive pod restarts
STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
umask 077
mkdir -p "$STATE_DIR"

# Always deploy the latest config from the template
cp /app/openclaw.json "$STATE_DIR/openclaw.json"

# Safety check: gateway.bind MUST be "lan" for ILB and node host connectivity.
# "auto" resolves to loopback-only which breaks kube-proxy forwarding.
# "all" is not a valid OpenClaw value and causes CrashLoopBackOff.
BIND_VALUE=$(jq -r '.gateway.bind // "missing"' "$STATE_DIR/openclaw.json")
if [ "$BIND_VALUE" != "lan" ]; then
  echo "FATAL: gateway.bind is '$BIND_VALUE', must be 'lan' for ILB connectivity. Fixing."
  jq '.gateway.bind = "lan"' "$STATE_DIR/openclaw.json" > "$STATE_DIR/openclaw.json.tmp" \
    && mv "$STATE_DIR/openclaw.json.tmp" "$STATE_DIR/openclaw.json"
fi

# Configure exec approvals for auto-approve on gateway side
if [ ! -f "$STATE_DIR/exec-approvals.json" ] || ! grep -q '"security": "full"' "$STATE_DIR/exec-approvals.json" 2>/dev/null; then
  cat > "$STATE_DIR/exec-approvals.json" << 'EOFEA'
{
  "version": 1,
  "defaults": {
    "security": "full",
    "ask": "off",
    "askFallback": "full"
  },
  "agents": {
    "main": {
      "security": "full",
      "ask": "off"
    }
  }
}
EOFEA
fi

# Also symlink from default location for CLI commands
if [ "$STATE_DIR" != "$HOME/.openclaw" ]; then
  ln -sfn "$STATE_DIR" "$HOME/.openclaw"
fi

# Start OpenClaw
GLOBAL_ROOT=$(npm root -g)

# Background: auto-approve pending node-host device pairings.
# Checks every 15s for pending requests with role=node and approves them.
# This enables fully automated pairing without manual intervention.
(
  sleep 30  # wait for gateway to be ready
  while true; do
    # List pending requests, extract request IDs for node-role devices
    pending=$(node "$GLOBAL_ROOT/openclaw/dist/entry.js" devices list --json 2>/dev/null || echo '{}')
    echo "$pending" | jq -r '.pending[]? | select(.role == "node") | .requestId' 2>/dev/null | while read -r req_id; do
      if [ -n "$req_id" ]; then
        echo "[auto-pair] approving node device: $req_id"
        node "$GLOBAL_ROOT/openclaw/dist/entry.js" devices approve "$req_id" 2>/dev/null || true
      fi
    done
    sleep 15
  done
) &

node "$GLOBAL_ROOT/openclaw/dist/entry.js" gateway --port 18789
