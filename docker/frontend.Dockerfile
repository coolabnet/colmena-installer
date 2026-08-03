# Colmena frontend — React/Vite dev server (node:20). Build context is the repo
# ROOT. Dev mode keeps the simplest working path (per the PRD): the entrypoint
# waits for the backend schema, runs `npm install` (its `prepare` hook generates
# the OpenAPI client), patches vite allowedHosts for the Caddy proxy, then serves.
FROM node:20-bookworm

WORKDIR /app

# Copy frontend source (node_modules excluded via .dockerignore).
COPY frontend/ .

COPY docker/frontend-entrypoint.sh /usr/local/bin/frontend-entrypoint.sh
RUN chmod +x /usr/local/bin/frontend-entrypoint.sh

EXPOSE 5173
ENTRYPOINT ["frontend-entrypoint.sh"]
