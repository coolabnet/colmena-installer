#!/usr/bin/env bash
# Stage 90 -- teardown: kill dev servers, stop/clean compose stack
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
STAGE_NAME="teardown"

stage 90 "Teardown"

ALL="${ALL:-0}"
KEEP_DATA="${KEEP_DATA:-1}"
DROPDB="${DROPDB:-0}"

# --all implies DROPDB=1 and KEEP_DATA=0
if [[ "$ALL" == "1" ]]; then
  DROPDB=1
  KEEP_DATA=0
fi

step "Kill backend runserver"
if pkill -f "manage.py runserver" 2>/dev/null; then
  ok "killed runserver"
else
  ok "no runserver to kill"
fi

step "Kill Vite dev server"
if pkill -f "vite" 2>/dev/null; then
  ok "killed vite"
else
  ok "no vite to kill"
fi

step "Kill headless Chrome (from prior browser-harness sessions)"
if pkill -f "google-chrome --headless" 2>/dev/null; then
  ok "killed chrome"
else
  ok "no chrome to kill"
fi

if [[ "$DROPDB" == "1" ]]; then
  step "Drop colmena_dev database (requires Postgres running)"
  cd "$BACKEND_DIR" || exit 1
  # shellcheck disable=SC1091
  source venv/bin/activate
  load_backend_env
  if python bin/postgres.py drop >>"$LOG_DIR/teardown.log" 2>&1; then
    ok "dropped colmena_dev"
  else
    warn "drop failed; is Postgres running? (see $LOG_DIR/teardown.log)"
  fi
fi

if [[ "$KEEP_DATA" == "0" ]]; then
  step "docker compose down (with volumes)"
  cd "$DEVOPS_DIR/devops/local" || exit 1
  if docker compose --env-file ../../.env down --volumes --remove-orphans >>"$LOG_DIR/teardown.log" 2>&1; then
    ok "compose down with volumes"
  else
    warn "compose down failed (see $LOG_DIR/teardown.log)"
  fi
  if [[ "$ALL" == "1" ]]; then
    step "Remove colmena_nextcloud image (forces rebuild)"
    if docker rmi colmena_nextcloud 2>/dev/null; then
      ok "image removed"
    else
      ok "no image to remove"
    fi
  fi
else
  step "docker compose stop (keep volumes)"
  cd "$DEVOPS_DIR/devops/local" || exit 1
  if docker compose --env-file ../../.env stop >>"$LOG_DIR/teardown.log" 2>&1; then
    ok "compose stop (volumes kept)"
  else
    warn "compose stop failed (see $LOG_DIR/teardown.log)"
  fi
fi

finish_stage
