#!/usr/bin/env bash
# Stage 50 — tests: backend pytest, frontend type check, browser e2e (Playwright)
#
# Mode detection: if PLAYWRIGHT_BASE_URL starts with https://, treat this as a
# remote/droplet run — skip backend test re-run, tsc, and vite build (those run
# on the droplet itself). Only run Playwright against the remote URL.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
STAGE_NAME="tests"

stage 50 "Tests: backend + frontend + E2E"

REMOTE=0
if [[ "${PLAYWRIGHT_BASE_URL:-}" =~ ^https:// ]]; then
  REMOTE=1
fi
info "mode=$([[ $REMOTE == 1 ]] && echo 'remote' || echo 'local') (PLAYWRIGHT_BASE_URL=${PLAYWRIGHT_BASE_URL:-<unset>})"

if [[ $REMOTE -eq 0 ]]; then
  step "Backend Django test suite (re-run via Makefile for parity)"
  cd "$BACKEND_DIR" || exit 1
  # shellcheck disable=SC1091
  source venv/bin/activate
  make test >>"$LOG_DIR/backend-test.log" 2>&1
  TC=$?
  if [[ $TC -eq 0 ]]; then
    ok "backend tests pass"
  else
    fail "backend tests failed (exit=$TC); see $LOG_DIR/backend-test.log"
  fi

  step "Frontend type check (tsc --noEmit)"
  cd "$FRONTEND_DIR" || exit 1
  if timeout 90 npx tsc --noEmit >>"$FRONTEND_LOG" 2>&1; then
    ok "tsc clean"
  else
    warn "tsc reports errors or timed out (90s); see $FRONTEND_LOG"
  fi

  step "Build frontend (production bundle, slow ~45s)"
  if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    if timeout 120 npm run build >>"$FRONTEND_LOG" 2>&1; then
      ok "vite build completed"
    else
      warn "vite build had warnings or timed out (120s); see $FRONTEND_LOG"
    fi
  else
    skip "vite build (SKIP_BUILD=1)"
  fi
else
  skip "backend test suite (remote mode — ran on droplet)"
  skip "frontend tsc check (remote mode — ran on droplet)"
  skip "vite build (remote mode — ran on droplet)"
fi

step "Playwright E2E"
if [[ "${SKIP_PLAYWRIGHT:-0}" == "1" ]]; then
  skip "Playwright E2E (SKIP_PLAYWRIGHT=1)"
  finish_stage
  exit $?
fi

# Install Playwright deps if missing (one-time, slow)
if [[ ! -d "$WORKSPACE_ROOT/tests/node_modules" ]]; then
  cd "$WORKSPACE_ROOT/tests" || exit 1
  if npm install --no-save @playwright/test@1.48.0 >>"$FRONTEND_LOG" 2>&1; then
    ok "installed @playwright/test"
  else
    fail "npm install @playwright/test failed"
    exit 1
  fi
fi
cd "$WORKSPACE_ROOT/tests" || exit 1

# Run the spec
npx playwright test --reporter=line,html >>"$LOG_DIR/playwright.log" 2>&1
TC=$?
if [[ $TC -eq 0 ]]; then
  ok "playwright tests pass"
else
  fail "playwright tests failed (exit=$TC); see $LOG_DIR/playwright.log"
fi

step "Playwright report"
PW_REPORT="$WORKSPACE_ROOT/tests/playwright-report/index.html"
if [[ -f "$PW_REPORT" ]]; then
  ok "playwright-report/index.html generated"
  info "open file://$PW_REPORT"
else
  warn "no playwright-report/index.html"
fi

# Kill any lingering playwright show-report server so the orchestrator exits cleanly
pkill -f "playwright.*show-report" 2>/dev/null || true

finish_stage
