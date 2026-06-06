#!/usr/bin/env bash
# run-stack.sh -- one-shot orchestrator for the Colmena per-module stack
#
# Stages:
#   05 clone         -- ensure all repos are present (clone if missing, checkout branch)
#   10 prereqs       -- verify (or install) pyenv/python3.10/node/docker/playwright
#   20 infra         -- docker compose up Postgres, pgAdmin, Mailcrab, Nextcloud
#   25 credential-sync -- reconcile devops .env credentials into backend .env
#   30 backend       -- venv, install, db.create/migrate/seeds, server :8000
#   40 frontend      -- npm install, vite dev :5173
#   50 tests         -- backend tests, tsc, vite build, Playwright E2E
#   90 teardown      -- kill processes, docker compose down
#
# Usage:
#   bash run-stack.sh           # full run
#   bash run-stack.sh up        # stages 05..40 only (no 25 to preserve manual control)
#   bash run-stack.sh test      # stage 50 only (assumes stack is up)
#   bash run-stack.sh down      # teardown only
#   bash run-stack.sh droplet   # self-bootstrap on a cloud VM (05 10 20 25 30 40; no 50/90)
#   bash run-stack.sh 30 40     # explicit stages
#
# Env overrides:
#   BACKEND_PORT, FRONTEND_PORT (defaults 8000, 5173)
#   KEEP_DATA=0                 # teardown removes volumes
#   DROPDB=1                    # teardown drops colmena_dev
#   SKIP_NEXTCLOUD=1            # don't even try Nextcloud
#   SKIP_PLAYWRIGHT=1           # skip stage 50 browser tests
#   INSTALL_MISSING=1           # prereqs will install missing tools
#   SKIP_DEV_TOOLS=1            # prereqs will skip browser-harness + playwright CLI
#   STACK_MODE=droplet          # informational; consumed by stages
#   COLMENA_CLONE_PROTO=https   # clone repos via HTTPS (no SSH keys needed)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WORKSPACE_ROOT="$SCRIPT_DIR"
# shellcheck source=scripts/lib/log.sh
source "$SCRIPT_DIR/scripts/lib/log.sh"
# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/scripts/lib/env.sh"

mkdir -p "$LOG_DIR"

# Initialize quirk log (overwrite on each run)
reset_quirk_log

# Banner
printf '\n%s%sColmena stack -- per-module run%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
printf '%sworkspace: %s%s\n' "$C_DIM" "$WORKSPACE_ROOT" "$C_RESET"
printf '%slogs:      %s%s\n' "$C_DIM" "$LOG_DIR" "$C_RESET"
printf '%squirks:    %s%s\n' "$C_DIM" "$QUIRK_LOG" "$C_RESET"
printf '%sstarted:   %s%s\n' "$C_DIM" "$(ts)" "$C_RESET"

# Map stage numbers to scripts
declare -A STAGE_SCRIPTS=(
  [05]="$SCRIPT_DIR/scripts/05-clone.sh"
  [10]="$SCRIPT_DIR/scripts/10-prereqs.sh"
  [20]="$SCRIPT_DIR/scripts/20-infra-up.sh"
  [25]="$SCRIPT_DIR/scripts/25-credential-sync.sh"
  [30]="$SCRIPT_DIR/scripts/30-backend-up.sh"
  [40]="$SCRIPT_DIR/scripts/40-frontend-up.sh"
  [50]="$SCRIPT_DIR/scripts/50-tests.sh"
  [90]="$SCRIPT_DIR/scripts/90-teardown.sh"
)

# Parse command line
ALL="${ALL:-0}"
STAGES=()
case "${1:-}" in
  "")
    STAGES=(05 10 20 25 30 40 50 90)
    ;;
  up)
    STAGES=(05 10 20 25 30 40)
    shift
    ;;
  droplet)
    # Self-bootstrap mode for a fresh cloud VM (e2e runs from the local machine).
    # Installs missing toolchain, skips dev-only checks, no local teardown at the end.
    export INSTALL_MISSING="${INSTALL_MISSING:-1}"
    export SKIP_DEV_TOOLS="${SKIP_DEV_TOOLS:-1}"
    export STACK_MODE=droplet
    STAGES=(05 10 20 25 30 40)
    shift
    ;;
  test)
    STAGES=(50)
    shift
    ;;
  down)
    STAGES=(90)
    shift
    if [[ "${1:-}" == "--all" ]]; then
      ALL=1
      shift
    fi
    ;;
  --all)
    ALL=1
    shift
    STAGES=(05 10 20 25 30 40 50 90)
    ;;
  *)
    for arg in "$@"; do
      if [[ "$arg" =~ ^[0-9]+$ ]]; then
        STAGES+=("$arg")
      else
        fail "unknown argument: $arg"
        exit 1
      fi
    done
    shift "$#"
    ;;
esac

if [[ $# -gt 0 ]]; then
  fail "unexpected extra argument(s): $*"
  exit 1
fi

# Run requested stages
EXIT_CODE=0
STAGE_PASS=0
STAGE_FAIL=0
for s in "${STAGES[@]}"; do
  script="${STAGE_SCRIPTS[$s]:-}"
  if [[ -z "$script" ]]; then
    fail "unknown stage: $s"
    EXIT_CODE=1
    STAGE_FAIL=$((STAGE_FAIL+1))
    continue
  fi
  if [[ ! -f "$script" ]]; then
    fail "script missing: $script"
    EXIT_CODE=1
    STAGE_FAIL=$((STAGE_FAIL+1))
    continue
  fi
  printf '\n'
  if ! ALL="${ALL:-0}" bash "$script"; then
    EXIT_CODE=1
    STAGE_FAIL=$((STAGE_FAIL+1))
  else
    STAGE_PASS=$((STAGE_PASS+1))
  fi
done

# Finalize quirk log
finalize_quirk_log "$STAGE_PASS" "$STAGE_FAIL"

printf '\n'
printf '%s%sStage Summary%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
printf '  passed: %s%d%s\n' "$C_GREEN" "$STAGE_PASS" "$C_RESET"
printf '  failed: %s%d%s\n' "$C_RED" "$STAGE_FAIL" "$C_RESET"
printf '  quirks: %s%s%s\n' "$C_MAGENTA" "$QUIRK_LOG" "$C_RESET"

if [[ $EXIT_CODE -ne 0 ]]; then
  fail "one or more stages failed; see $LOG_DIR"
  exit 1
fi
ok "stack run complete"
