#!/usr/bin/env bash
# Stage 40 -- frontend: npm install (with schema fetch from running backend), then
#   - local mode:  vite dev server on :5173
#   - droplet mode: production build served by Caddy (no Vite dev server)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/wait.sh
source "$SCRIPT_DIR/lib/wait.sh"
STAGE_NAME="frontend"

stage 40 "Frontend: npm install, vite dev"

cd "$FRONTEND_DIR" || exit 1

step "Ensure .env exists"
if [[ ! -f .env && -f .env.example ]]; then
  cp .env.example .env
  ok "created .env from example"
else
  ok ".env present"
fi

step "Override OPENAPI_SCHEMA_LOCATION to local backend"
# .env points at https://backend.dev.colmena.network by default; we need the local one
if grep -q "^OPENAPI_SCHEMA_LOCATION" .env; then
  sed -i "s|^OPENAPI_SCHEMA_LOCATION=.*|OPENAPI_SCHEMA_LOCATION=http://localhost:$BACKEND_PORT/api/schema/|" .env
  ok "OPENAPI_SCHEMA_LOCATION -> http://localhost:$BACKEND_PORT/api/schema/"
else
  echo "OPENAPI_SCHEMA_LOCATION=http://localhost:$BACKEND_PORT/api/schema/" >> .env
  ok "appended OPENAPI_SCHEMA_LOCATION"
fi

step "Lint + prettier check"
if npm run lint:check >>"$FRONTEND_LOG" 2>&1; then
  ok "eslint clean"
else
  warn "eslint reports issues (non-fatal)"
fi

# Vite >= 5 blocks any Host header that isn't localhost by default. When the
# stack is fronted by Caddy (or any reverse proxy) the Host header is the
# public domain, and Vite returns 403 "Blocked request. This host is not
# allowed." Patch vite.config.* to add server.allowedHosts: true so the dev
# server accepts any host. Idempotent.
step "Patch vite.config to allow any host (Caddy reverse_proxy)"
VITE_CFG="$FRONTEND_DIR/vite.config.ts"
[[ ! -f "$VITE_CFG" ]] && VITE_CFG="$FRONTEND_DIR/vite.config.js"
if [[ -f "$VITE_CFG" ]] && ! grep -q 'allowedHosts' "$VITE_CFG"; then
  # Insert a `server: { allowedHosts: true }` block right after the defineConfig(
  # opening. Use node to keep the config syntactically valid (top-level object
  # spread would be brittle for a typescript config).
  node -e "
    const fs = require('fs');
    const f = '$VITE_CFG';
    let s = fs.readFileSync(f, 'utf8');
    if (s.includes('allowedHosts')) { process.exit(0); }
    // Find defineConfig({ ... }) and inject server block as the first key.
    s = s.replace(/(defineConfig\s*\(\s*\{)/, '\$1\n  server: { allowedHosts: true },');
    fs.writeFileSync(f, s);
    console.log('  patched: added server.allowedHosts');
  " 2>>"$FRONTEND_LOG" || warn "could not patch $VITE_CFG (non-fatal)"
  ok "$VITE_CFG patched for Caddy host"
else
  ok "$VITE_CFG already has allowedHosts"
fi

step "npm install (triggers prepare -> openapi-tasks)"
# Export OPENAPI_SCHEMA_LOCATION so the prepare hook's openapi-tasks can find
# the running backend. The .env file was patched above, but npm doesn't source
# it — only the Makefile does.
export OPENAPI_SCHEMA_LOCATION="http://localhost:$BACKEND_PORT/api/schema/"
if [[ ! -d node_modules || ! -f node_modules/.package-lock.json ]]; then
  if npm install >>"$FRONTEND_LOG" 2>&1; then
    ok "npm install completed"
  else
    warn "npm install had issues; see $FRONTEND_LOG"
  fi
else
  ok "node_modules present"
fi

step "Verify generated TypeScript types exist"
if [[ -f src/api/utilities/Definitions.d.ts ]]; then
  ok "Definitions.d.ts present ($(wc -c < src/api/utilities/Definitions.d.ts) bytes)"
else
  warn "Definitions.d.ts missing -- openapi-tasks may have failed"
  quirk "openapi-types" "Definitions.d.ts missing after npm install; check $FRONTEND_LOG"
fi

if [[ "${STACK_MODE:-local}" == "droplet" ]]; then
  # ── Droplet mode: production build, served by Caddy ──
  step "Production build (STACK_MODE=droplet)"
  if npm run build >>"$FRONTEND_LOG" 2>&1; then
    ok "npm run build completed"
  else
    fail "npm run build failed; see $FRONTEND_LOG"
    tail -30 "$FRONTEND_LOG"
  fi

  if [[ -d dist ]]; then
    ok "dist/ directory present ($(du -sh dist | cut -f1))"
  else
    fail "dist/ directory missing after build"
  fi

  # Patch Caddyfile to serve static files from dist/ instead of proxying to Vite
  step "Patch Caddyfile to serve static frontend"
  CADDYFILE="/etc/caddy/Caddyfile"
  STATIC_DIR="/var/www/colmena"
  mkdir -p "$STATIC_DIR"
  cp -r "$FRONTEND_DIR/dist/"* "$STATIC_DIR/"
  if [[ -f "$CADDYFILE" ]]; then
    # Replace the Vite reverse_proxy handle block with static file serving.
    # Keep the /api/* handle block intact.
    node -e "
      const fs = require('fs');
      let c = fs.readFileSync('$CADDYFILE', 'utf8');
      // Replace the catch-all handle block (reverse_proxy to Vite) with static serving.
      // Keep the /api/* handle block intact. Use [\\s\\S] to match across newlines.
      c = c.replace(
        /handle\\s*\\{[\\s\\S]*?reverse_proxy\\s+localhost:$FRONTEND_PORT[\\s\\S]*?\\}/,
        'handle {\\n        root * $STATIC_DIR\\n        try_files {path} /index.html\\n        file_server\\n    }'
      );
      fs.writeFileSync('$CADDYFILE', c);
      console.log('  patched Caddyfile');
    " 2>>"$FRONTEND_LOG" || warn "could not patch Caddyfile"
    systemctl reload caddy && ok "Caddy reloaded with static frontend" || warn "Caddy reload failed"
  else
    warn "Caddyfile not found at $CADDYFILE"
  fi
else
  # ── Local mode: Vite dev server ──
  step "Start Vite dev :$FRONTEND_PORT"
  if (echo > "/dev/tcp/127.0.0.1/$FRONTEND_PORT") 2>/dev/null; then
    warn "port $FRONTEND_PORT busy; killing prior listener"
    lsof -ti tcp:"$FRONTEND_PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    sleep 1
  fi
  setsid nohup npm run dev -- --port "$FRONTEND_PORT" --host "::" >>"$FRONTEND_LOG" 2>&1 </dev/null & disown
  sleep 3

  if wait_for_url "http://localhost:$FRONTEND_PORT/" 20 200; then
    ok "frontend up on :$FRONTEND_PORT (note: Vite binds IPv6 localhost)"
  else
    fail "frontend did not respond on :$FRONTEND_PORT; see $FRONTEND_LOG"
    tail -30 "$FRONTEND_LOG"
  fi

  step "Verify SPA serves index.html"
  HTML=$(curl -sS "http://localhost:$FRONTEND_PORT/" | head -1 || true)
  if echo "$HTML" | grep -qi "<!DOCTYPE html\|<html"; then
    ok "index.html served"
  else
    fail "did not get index.html; first line: $HTML"
  fi
fi

finish_stage
