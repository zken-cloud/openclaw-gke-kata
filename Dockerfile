FROM node:22-slim

# Install utilities for config templating
RUN apt-get update && apt-get install -y \
    gettext-base \
    jq \
    openssl \
    && rm -rf /var/lib/apt/lists/*

# Install OpenClaw
RUN npm install -g openclaw --ignore-scripts

# Create app directory
WORKDIR /app

# Copy template config
COPY openclaw.json.template /app/openclaw.json.template

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
