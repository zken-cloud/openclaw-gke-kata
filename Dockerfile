FROM node:22-slim

# Install utilities for config templating
RUN apt-get update && apt-get install -y \
    gettext-base \
    jq \
    openssl \
    && rm -rf /var/lib/apt/lists/*

# Install OpenClaw and apply patches:
# 1. throwOnLoadError: prevent crashes from optional plugin deps
# 2. Gateway call timeout: increase from 10s to 60s for Kata VM overhead
# 3. RPC CLI default timeout: increase from 10s to 60s
RUN npm install -g openclaw --ignore-scripts \
    && LOADER=$(ls /usr/local/lib/node_modules/openclaw/dist/runtime-registry-loader-*.js 2>/dev/null | head -1) \
    && [ -n "$LOADER" ] && sed -i 's/throwOnLoadError: true/throwOnLoadError: false/g' "$LOADER" || true \
    && CALL_JS=$(ls /usr/local/lib/node_modules/openclaw/dist/call-*.js 2>/dev/null | head -1) \
    && [ -n "$CALL_JS" ] && sed -i 's/timeoutValue) ? timeoutValue : 1e4/timeoutValue) ? timeoutValue : 6e4/g' "$CALL_JS" || true \
    && CONN_JS=$(ls /usr/local/lib/node_modules/openclaw/dist/connect-options-*.js 2>/dev/null | head -1) \
    && [ -n "$CONN_JS" ] && sed -i 's/connectTimeoutMs : 15e3/connectTimeoutMs : 6e4/g' "$CONN_JS" || true \
    && RPC_JS=$(ls /usr/local/lib/node_modules/openclaw/dist/rpc-*.js 2>/dev/null | head -1) \
    && [ -n "$RPC_JS" ] && sed -i 's/timeoutMs ?? 1e4/timeoutMs ?? 6e4/g' "$RPC_JS" || true

# Create app directory
WORKDIR /app

# Copy template config and workspace seed files
COPY openclaw.json.template /app/openclaw.json.template
COPY workspace/ /app/workspace-seed/

# Create non-root user and directories
RUN groupadd -r -g 10001 openclaw && useradd -r -u 10001 -g openclaw -d /app -s /bin/sh openclaw \
    && mkdir -p /app/workspace /var/log/openclaw \
    && chown -R openclaw:openclaw /app /var/log/openclaw

# Expose port
EXPOSE 18789

# Copy entrypoint script
COPY scripts/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

USER openclaw

ENTRYPOINT ["/app/entrypoint.sh"]
