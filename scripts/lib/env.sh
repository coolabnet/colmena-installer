#!/usr/bin/env bash
# Env + paths
# shellcheck disable=SC2034

WORKSPACE_ROOT="${WORKSPACE_ROOT:-/home/luandro/Dev/coolab/colmena}"
BACKEND_DIR="$WORKSPACE_ROOT/backend"
FRONTEND_DIR="$WORKSPACE_ROOT/frontend"
DEVOPS_DIR="$WORKSPACE_ROOT/colmena-devops"
COLMENA_OS_DIR="$WORKSPACE_ROOT/colmena-os"

# Some background-launch contexts (cloud-init runcmd, nohup from systemd-style
# runners) leave $HOME unset, which would trip `set -u` in any script that
# sources this file. Pin a sane default so the rest of the file can rely on it.
export HOME="${HOME:-/root}"

LOG_DIR="$WORKSPACE_ROOT/.run-logs"
mkdir -p "$LOG_DIR"

# Port map (per-module, not colmena-os defaults)
BACKEND_PORT="${BACKEND_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
PGADMIN_PORT="${PGADMIN_PORT:-5050}"
MAIL_SMTP_PORT="${MAIL_SMTP_PORT:-1025}"
MAIL_WEB_PORT="${MAIL_WEB_PORT:-1080}"
NEXTCLOUD_PORT="${NEXTCLOUD_PORT:-8003}"

# Hostnames for the backend/frontend (used by load_sites_with_hostname and
# ALLOWED_HOSTS patching). In local mode these default to localhost; in droplet
# mode (STACK_MODE=droplet) they should be set to the public domain.
BACKEND_HOSTNAME="${BACKEND_HOSTNAME:-localhost:$BACKEND_PORT}"
FRONTEND_HOSTNAME="${FRONTEND_HOSTNAME:-localhost:$FRONTEND_PORT}"
STACK_MODE="${STACK_MODE:-local}"

# Logs per service
BACKEND_LOG="$LOG_DIR/backend.log"
FRONTEND_LOG="$LOG_DIR/frontend.log"
INFRA_LOG="$LOG_DIR/infra.log"
PREREQ_LOG="$LOG_DIR/prereqs.log"

# pyenv-managed Python (prepend only when present -- supports droplets & CI)
if [[ -d "$HOME/.pyenv/shims" ]]; then
  export PATH="$HOME/.pyenv/shims:$HOME/.pyenv/bin:$PATH"
fi

# Load backend .env into the current shell (manage.py does NOT do this; the Makefile does)
load_backend_env() {
  if [[ -f "$BACKEND_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$BACKEND_DIR/.env"
    set +a
  fi
}

# Load frontend .env into the current shell
load_frontend_env() {
  if [[ -f "$FRONTEND_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$FRONTEND_DIR/.env"
    set +a
  fi
}

# Get the project id from the localStorage-like JSON or return 0
get_saved_server_id() {
  # The frontend stores a server in localStorage; not accessible from shell.
  # For tests we hardcode id=1 because we save only one server in the spec.
  echo 1
}
