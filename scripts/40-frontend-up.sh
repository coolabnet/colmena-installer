#!/usr/bin/env bash
# Stage 40 — frontend: npm install (with schema fetch from running backend), vite dev :5173
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

step "npm install (triggers prepare -> openapi-tasks)"
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
  warn "Definitions.d.ts missing — openapi-tasks may have failed"
  quirk "openapi-types" "Definitions.d.ts missing after npm install; check $FRONTEND_LOG"
fi

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

finish_stage
