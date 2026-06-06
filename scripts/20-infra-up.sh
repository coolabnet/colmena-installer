#!/usr/bin/env bash
# Stage 20 -- infra: docker compose up Postgres, pgAdmin, Mailcrab (Nextcloud best-effort)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/wait.sh
source "$SCRIPT_DIR/lib/wait.sh"
STAGE_NAME="infra"

stage 20 "Bring up infra services"

cd "$DEVOPS_DIR/devops/local" || exit 1

step "Ensure .env exists"
if [[ ! -f "$DEVOPS_DIR/.env" && -f "$DEVOPS_DIR/.env.example" ]]; then
  cp "$DEVOPS_DIR/.env.example" "$DEVOPS_DIR/.env"
  ok "created colmena-devops/.env from example"
else
  ok ".env already present"
fi

step "Tear down any prior infra (best-effort)"
try "docker compose down" "$INFRA_LOG" docker compose --env-file ../../.env down --remove-orphans || true

step "Start Postgres, pgAdmin, Mailcrab"
try "docker compose up -d postgres pgadmin mail" "$INFRA_LOG" \
  docker compose --env-file ../../.env up -d postgres pgadmin mail

step "Wait for Postgres"
# The compose file has no healthcheck, so use port-based wait
if wait_for_port localhost "$POSTGRES_PORT" 30; then
  ok "Postgres reachable on :$POSTGRES_PORT"
else
  fail "Postgres not reachable on :$POSTGRES_PORT after 30s; see $INFRA_LOG"
fi

step "Wait for pgAdmin"
if wait_for_port localhost "$PGADMIN_PORT" 15; then
  ok "pgAdmin reachable on :$PGADMIN_PORT"
else
  warn "pgAdmin not reachable on :$PGADMIN_PORT (non-fatal)"
fi

step "Wait for Mailcrab SMTP"
if wait_for_port localhost "$MAIL_SMTP_PORT" 15; then
  ok "Mailcrab SMTP on :$MAIL_SMTP_PORT"
else
  warn "Mailcrab SMTP not reachable (non-fatal)"
fi

step "Start Nextcloud"
if [[ "${SKIP_NEXTCLOUD:-0}" == "1" ]]; then
  skip "Nextcloud (SKIP_NEXTCLOUD=1)"
else
  docker compose --env-file ../../.env up -d nextcloud >>"$INFRA_LOG" 2>&1 || true
  if wait_for_port localhost "$NEXTCLOUD_PORT" 60; then
    ok "Nextcloud port open on :$NEXTCLOUD_PORT"
  else
    warn "Nextcloud port not reachable on :$NEXTCLOUD_PORT after 60s"
  fi
  # Wait for NC to fully initialize (port opens before app is ready)
  step "Wait for Nextcloud OCS API readiness"
  NC_READY=0
  for i in $(seq 1 24); do
    if curl -s --max-time 5 "http://localhost:$NEXTCLOUD_PORT/status.php" 2>/dev/null | grep -q "installed"; then
      NC_READY=1
      ok "Nextcloud fully initialized (status.php reports installed)"
      break
    fi
    sleep 5
  done
  if [[ "$NC_READY" == "0" ]]; then
    warn "Nextcloud status.php not responding after 2min (may still be initializing)"
  fi
fi

finish_stage
