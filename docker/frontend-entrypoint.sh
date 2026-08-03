#!/usr/bin/env bash
# Colmena frontend container entrypoint (Vite dev mode).
# Mirrors scripts/40-frontend-up.sh: fetch the OpenAPI schema from the backend,
# npm install (prepare hook generates the client), patch vite allowedHosts for the
# Caddy reverse proxy, then serve the dev server on all interfaces.
set -uo pipefail

SCHEMA="${OPENAPI_SCHEMA_LOCATION:-http://backend:8000/api/schema/}"
PORT="${FRONTEND_PORT:-5173}"

echo "[frontend] waiting for backend OpenAPI schema at $SCHEMA"
node -e "const u=process.argv[1];(async()=>{for(let i=0;i<80;i++){try{const r=await fetch(u);if(r.ok){console.log('[frontend] schema ready');process.exit(0)}}catch(e){}await new Promise(r=>setTimeout(r,3000))}console.log('[frontend] WARN: schema not ready after wait; continuing');process.exit(0)})()" "$SCHEMA"

# Vite >= 5 blocks any Host header that isn't localhost. Behind Caddy the Host is
# the public host, so allow any host. Verbatim logic from scripts/40-frontend-up.sh.
VITE_CFG="vite.config.ts"
[[ ! -f "$VITE_CFG" ]] && VITE_CFG="vite.config.js"
if [[ -f "$VITE_CFG" ]] && ! grep -q 'allowedHosts' "$VITE_CFG"; then
  node -e "
    const fs = require('fs');
    const f = '$VITE_CFG';
    let s = fs.readFileSync(f, 'utf8');
    if (s.includes('allowedHosts')) { process.exit(0); }
    s = s.replace(/(defineConfig\s*\(\s*\{)/, '\$1\n  server: { allowedHosts: true },');
    fs.writeFileSync(f, s);
    console.log('[frontend] patched: added server.allowedHosts');
  " || echo "[frontend] WARN: could not patch $VITE_CFG (non-fatal)"
else
  echo "[frontend] vite.config already has allowedHosts (or no config file)"
fi

echo "[frontend] npm install (prepare -> openapi-tasks generates the client)"
npm install || echo "[frontend] WARN: npm install had issues"

echo "[frontend] starting vite dev on 0.0.0.0:$PORT"
exec npm run dev -- --host 0.0.0.0 --port "$PORT"
