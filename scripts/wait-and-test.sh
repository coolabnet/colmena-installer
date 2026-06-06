#!/usr/bin/env bash
# scripts/wait-and-test.sh -- wait for the droplet stack to be ready, then run Playwright
#
# Usage:
#   COLMENA_DOMAIN=example.colmena.network bash scripts/wait-and-test.sh
#   bash scripts/wait-and-test.sh example.colmena.network
#
# Discovers the droplet IP via `terraform -chdir=terraform output -raw droplet_ip`,
# then uses `curl --resolve` to bypass DNS propagation. Runs the e2e suite at the end.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$SCRIPT_DIR/.."
cd "$WORKSPACE_ROOT"

DOMAIN="${1:-${COLMENA_DOMAIN:-}}"
if [[ -z "$DOMAIN" ]]; then
  echo "usage: $0 <domain>  OR  COLMENA_DOMAIN=<domain> $0" >&2
  exit 1
fi

STACK_TIMEOUT="${STACK_TIMEOUT:-300}"   # Phase 1: front door returns 200 (5 min)
API_TIMEOUT="${API_TIMEOUT:-600}"       # Phase 2: API reports ok (10 min)

log()  { printf '\n=== %s\n' "$*"; }
ok()   { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; return 1; }
warn() { printf '  warn %s\n' "$*"; }

# ── 1. Discover droplet IP ────────────────────────────────────────────────────
log "Discover droplet IP from terraform output"
if [[ ! -d "$WORKSPACE_ROOT/terraform" ]]; then
  fail "no terraform/ directory next to scripts/; run terraform apply first"
  exit 1
fi
DROPLET_IP=$(terraform -chdir="$WORKSPACE_ROOT/terraform" output -raw droplet_ip 2>/dev/null || true)
if [[ -z "$DROPLET_IP" || "$DROPLET_IP" == "null" ]]; then
  fail "could not read terraform output 'droplet_ip' -- has terraform apply succeeded?"
  exit 1
fi
ok "droplet_ip=$DROPLET_IP"

# ── 2. Phase 1: wait for the front door to return any HTTP 2xx/3xx (not 502/refused) ──
log "Phase 1: stack readiness (https://$DOMAIN) up to ${STACK_TIMEOUT}s"
SECONDS=0
PHASE1_OK=0
while (( SECONDS < STACK_TIMEOUT )); do
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
    --resolve "$DOMAIN:443:$DROPLET_IP" \
    "https://$DOMAIN/" 2>/dev/null || echo "000")
  case "$CODE" in
    2*|3*|404)  # 404 is fine here: Vite SPA may not be ready; we just want a non-5xx
      PHASE1_OK=1
      ok "phase 1: HTTPS responded with $CODE after ${SECONDS}s"
      break
      ;;
  esac
  sleep 5
done
if [[ "$PHASE1_OK" != "1" ]]; then
  fail "phase 1: stack did not respond after ${STACK_TIMEOUT}s (last code=$CODE)"
  warn "tail the cloud-init log: ssh root@$DROPLET_IP 'tail -n 200 /var/log/colmena-install.log'"
  exit 1
fi

# ── 3. Phase 2: wait for the API to report ok ─────────────────────────────────
log "Phase 2: API readiness (https://$DOMAIN/api/status/) up to ${API_TIMEOUT}s"
SECONDS=0
PHASE2_OK=0
while (( SECONDS < API_TIMEOUT )); do
  BODY=$(curl -sk --max-time 5 \
    --resolve "$DOMAIN:443:$DROPLET_IP" \
    "https://$DOMAIN/api/status/" 2>/dev/null || true)
  if [[ -n "$BODY" ]] && echo "$BODY" | jq -e '.backend.status == "ok"' >/dev/null 2>&1; then
    PHASE2_OK=1
    ok "phase 2: API reports ok after ${SECONDS}s"
    break
  fi
  sleep 5
done
if [[ "$PHASE2_OK" != "1" ]]; then
  fail "phase 2: API never reported ok after ${API_TIMEOUT}s (last body=$BODY)"
  exit 1
fi

# ── 4. Run Playwright e2e ─────────────────────────────────────────────────────
log "Run Playwright e2e (PLAYWRIGHT_BASE_URL=https://$DOMAIN, COLMENA_SERVER_URL=https://$DOMAIN)"
export PLAYWRIGHT_BASE_URL="https://$DOMAIN"
export COLMENA_SERVER_URL="https://$DOMAIN"

cd "$WORKSPACE_ROOT/tests"
if [[ ! -d node_modules ]]; then
  log "Install @playwright/test (one-time)"
  npm install --no-save @playwright/test@1.48.0
fi
npx playwright test --reporter=line,html
TC=$?
if [[ $TC -eq 0 ]]; then
  ok "playwright e2e PASSED"
  echo
  echo "  HTML report: $WORKSPACE_ROOT/tests/playwright-report/index.html"
  echo
  echo "  ⏰  REMINDER: run 'terraform destroy' from $WORKSPACE_ROOT/terraform to drop the droplet (~\$6/mo)."
  exit 0
else
  fail "playwright e2e FAILED (exit=$TC)"
  echo "  HTML report: $WORKSPACE_ROOT/tests/playwright-report/index.html"
  echo "  ⏰  REMINDER: run 'terraform destroy' even on failure to drop the droplet (~\$6/mo)."
  exit $TC
fi
