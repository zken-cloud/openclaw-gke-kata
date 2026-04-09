#!/bin/bash
# OpenClaw Linux Node Host Setup
# Installs openclaw and configures per-developer node hosts
# that connect back to each developer's gateway pod via Internal Load Balancer.
# Gateway auth token is fetched from GCP Secret Manager at runtime.

set -euo pipefail

TLS_FINGERPRINT='${tls_fingerprint}'
DEVELOPERS_JSON='${developers_json}'

# ── Install Node.js ─────────────────────────────────────────────────────────

NODE_VERSION="22.15.0"

if ! command -v node &>/dev/null; then
    echo "Installing Node.js $NODE_VERSION..."
    curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz" \
      -o /tmp/node.tar.xz
    tar -xf /tmp/node.tar.xz -C /usr/local --strip-components=1
    rm -f /tmp/node.tar.xz
    echo "Node.js installed: $(node --version)"
else
    echo "Node.js already installed: $(node --version)"
fi

# ── Install openclaw globally ───────────────────────────────────────────────

echo "Installing/updating openclaw to latest..."
npm install -g openclaw@latest 2>&1

# Patch: allow node host to start even if optional extension plugins fail to load.
# The gateway (entry.js gateway) uses throwOnLoadError:false but the node CLI
# defaults to true, causing startup failures when optional deps like @buape/carbon
# are missing. This patch makes node host behaviour consistent with the gateway.
GLOBAL_ROOT=$(npm root -g)
LOADER_FILE=$(ls "$GLOBAL_ROOT"/openclaw/dist/runtime-registry-loader-*.js 2>/dev/null | head -1)
if [ -n "$LOADER_FILE" ]; then
  sed -i 's/throwOnLoadError: true/throwOnLoadError: false/' "$LOADER_FILE"
  echo "Patched throwOnLoadError in $(basename "$LOADER_FILE")"
fi

OPENCLAW_VER=$(npx openclaw --version 2>&1 || true)
echo "openclaw version: $OPENCLAW_VER"

# ── Install jq if not present ───────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
    echo "Installing jq..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq jq
    elif command -v yum &>/dev/null; then
        yum install -y -q jq
    else
        curl -fsSL -o /usr/local/bin/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
        chmod +x /usr/local/bin/jq
    fi
fi

# ── Fetch gateway token from Secret Manager ─────────────────────────────────

echo "Fetching gateway auth token from Secret Manager..."
GATEWAY_TOKEN=$(gcloud secrets versions access latest --secret="openclaw-gateway-token" --quiet 2>&1)
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to fetch gateway token from Secret Manager: $GATEWAY_TOKEN"
    exit 1
fi
echo "Gateway token retrieved from Secret Manager."

# ── Set up state directory ──────────────────────────────────────────────────

STATE_DIR="/opt/openclaw/state"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# Disable exec approvals on node host (auto-approve all commands)
# Node host runs as root and uses /root/.openclaw/ for exec-approvals.json
OPENCLAW_STATE_DIR="$STATE_DIR" npx openclaw config set tools.exec.security full 2>&1 || true
OPENCLAW_STATE_DIR="$STATE_DIR" npx openclaw config set tools.exec.ask off 2>&1 || true
# Also pre-seed /root/.openclaw/ which the node host process auto-creates
mkdir -p /root/.openclaw
if [ ! -f /root/.openclaw/exec-approvals.json ] || [ "$(jq -r '.defaults.security // empty' /root/.openclaw/exec-approvals.json 2>/dev/null)" = "" ]; then
  if [ -f /root/.openclaw/exec-approvals.json ]; then
    jq '. * {"defaults":{"security":"full","ask":"off","askFallback":"full"},"agents":{"main":{"security":"full","ask":"off"}}}' \
      /root/.openclaw/exec-approvals.json > /tmp/ea.json && mv /tmp/ea.json /root/.openclaw/exec-approvals.json
  else
    echo '{"version":1,"defaults":{"security":"full","ask":"off","askFallback":"full"},"agents":{"main":{"security":"full","ask":"off"}}}' > /root/.openclaw/exec-approvals.json
  fi
fi

# ── Register per-developer node hosts ───────────────────────────────────────

NODES_DIR="/opt/openclaw/nodes"
mkdir -p "$NODES_DIR"

# Parse developers JSON
DEV_NAMES=$(echo "$DEVELOPERS_JSON" | jq -r 'keys[]')

for DEV_NAME in $DEV_NAMES; do
    ACTIVE=$(echo "$DEVELOPERS_JSON" | jq -r --arg d "$DEV_NAME" '.[$d].active')
    GATEWAY_IP=$(echo "$DEVELOPERS_JSON" | jq -r --arg d "$DEV_NAME" '.[$d].gateway_ip')
    SERVICE_NAME="openclaw-node-$DEV_NAME"

    if [ "$ACTIVE" != "true" ]; then
        # Stop and disable inactive developer's node host
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            systemctl stop "$SERVICE_NAME"
            systemctl disable "$SERVICE_NAME"
            echo "Stopped node host for inactive developer: $DEV_NAME"
        fi
        continue
    fi

    echo "Setting up node host for $DEV_NAME -> gateway at $GATEWAY_IP:18789"

    DEV_STATE_DIR="/opt/openclaw/state/$DEV_NAME"
    mkdir -p "$DEV_STATE_DIR" "/root/.openclaw"

    # Pre-seed exec-approvals.json before node host starts
    EA_CONTENT='{"version":1,"defaults":{"security":"full","ask":"off","askFallback":"full"},"agents":{"main":{"security":"full","ask":"off"}}}'
    echo "$EA_CONTENT" > "$DEV_STATE_DIR/exec-approvals.json"
    echo "$EA_CONTENT" > "/root/.openclaw/exec-approvals.json"

    # Clean stale device identity so the node host re-pairs on every VM restart
    for CLEAN_DIR in "$DEV_STATE_DIR" "$STATE_DIR"; do
        for SUB_DIR in devices identity; do
            if [ -d "$CLEAN_DIR/$SUB_DIR" ]; then
                rm -rf "$CLEAN_DIR/$SUB_DIR"
                echo "Cleaned stale $SUB_DIR from $CLEAN_DIR"
            fi
        done
    done

    # Create systemd service for each developer's node host
    cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOFSVC
[Unit]
Description=OpenClaw Node Host for $DEV_NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
Environment=OPENCLAW_STATE_DIR=$DEV_STATE_DIR
Environment=OPENCLAW_GATEWAY_TOKEN=$GATEWAY_TOKEN
ExecStartPre=/bin/mkdir -p $DEV_STATE_DIR
ExecStart=$(which npx) openclaw node run --host $GATEWAY_IP --port 18789 --tls --tls-fingerprint $TLS_FINGERPRINT --display-name "linux-$DEV_NAME"

[Install]
WantedBy=multi-user.target
EOFSVC

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    echo "Node host started for $DEV_NAME (service: $SERVICE_NAME)"
done

echo "OpenClaw Linux node host setup complete."
