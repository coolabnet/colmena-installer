#!/usr/bin/env bash
# Stage 25 -- credential sync: copy postgres creds from colmena-devops/.env to backend/.env
#
# Runs after stage 20 (infra up) so the devops .env exists, and before stage 30 (backend)
# so Django can connect with the right credentials. Idempotent.
#
# If a key already exists in backend/.env with a DIFFERENT value, we warn (and override
# by default; set BACKEND_ENV_PRESERVE=1 to skip overrides).
#
# NOTE: POSTGRES_HOSTNAME is treated specially. The host-side backend talks to the
# published port on localhost, while the devops docker-compose stack uses the
# service-name alias `postgres` for inter-container DNS. These are intentionally
# different, so hostname is skipped by default. Set BACKEND_ENV_SYNC_HOSTNAME=1
# to force the sync.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
STAGE_NAME="credential-sync"

stage 25 "Sync Postgres credentials: devops .env -> backend .env"

[[ -f "$DEVOPS_DIR/.env" ]] || { fail "missing $DEVOPS_DIR/.env (run stage 20 first)"; exit 1; }
[[ -f "$BACKEND_DIR/.env" ]] || {
  fail "missing $BACKEND_DIR/.env (run stage 30 once to bootstrap it)"
  exit 1
}

# shellcheck disable=SC1091
DEVOPS_ENV_VALS="$(set -a; source "$DEVOPS_DIR/.env"; set +a; \
  printf 'POSTGRES_USERNAME=%s\nPOSTGRES_PASSWORD=%s\nPOSTGRES_HOSTNAME=%s\nPOSTGRES_PORT=%s\nPOSTGRES_DATABASE=%s\n' \
    "${POSTGRES_USERNAME:-}" "${POSTGRES_PASSWORD:-}" "${POSTGRES_HOSTNAME:-}" \
    "${POSTGRES_PORT:-5432}" "${POSTGRES_DATABASE:-colmena_dev}")"

PRESERVE="${BACKEND_ENV_PRESERVE:-0}"
SYNC_HOSTNAME="${BACKEND_ENV_SYNC_HOSTNAME:-0}"
SYNC_KEYS=(POSTGRES_USERNAME POSTGRES_PASSWORD POSTGRES_PORT POSTGRES_DATABASE)
if [[ "$SYNC_HOSTNAME" == "1" ]]; then
  SYNC_KEYS+=(POSTGRES_HOSTNAME)
fi
CHANGED=0
PRESERVED=0
SKIPPED_HOSTNAME=0

# Keys whose values must never be printed in plain text (passwords, tokens).
# For these, the diff is shown as "X differs" rather than the actual values.
SECRET_KEYS=(POSTGRES_PASSWORD)

# Returns 0 if the key's value is secret and must be redacted.
is_secret() {
  local k="$1"
  local s
  for s in "${SECRET_KEYS[@]}"; do
    [[ "$k" == "$s" ]] && return 0
  done
  return 1
}

sync_key() {
  local key="$1" new_val="$2"
  local cur_val=""
  if grep -qE "^${key}=" "$BACKEND_DIR/.env"; then
    cur_val=$(grep -E "^${key}=" "$BACKEND_DIR/.env" | tail -1 | cut -d= -f2-)
  fi
  if [[ -n "$cur_val" && "$cur_val" != "$new_val" ]]; then
    if [[ "$PRESERVE" == "1" ]]; then
      if is_secret "$key"; then
        warn "$key differs -- preserved (BACKEND_ENV_PRESERVE=1)"
        quirk "env-override" "$key: values differ (preserved; values redacted)"
      else
        warn "$key differs (devops=$new_val, backend=$cur_val) -- preserved (BACKEND_ENV_PRESERVE=1)"
        quirk "env-override" "$key: devops=$new_val, backend=$cur_val (preserved)"
      fi
      PRESERVED=$((PRESERVED+1))
      return
    fi
    if is_secret "$key"; then
      warn "$key differs -- overriding"
      quirk "env-override" "$key: values differ (overriding; values redacted)"
    else
      warn "$key differs (devops=$new_val, backend=$cur_val) -- overriding"
      quirk "env-override" "$key: backend=$cur_val -> $new_val"
    fi
    sed -i.bak "s|^${key}=.*|${key}=${new_val}|" "$BACKEND_DIR/.env"
    rm -f "$BACKEND_DIR/.env.bak"
    CHANGED=$((CHANGED+1))
  elif [[ -z "$cur_val" ]]; then
    echo "${key}=${new_val}" >> "$BACKEND_DIR/.env"
    if is_secret "$key"; then
      info "appended $key=<redacted>"
    else
      info "appended ${key}=${new_val}"
    fi
    CHANGED=$((CHANGED+1))
  else
    ok "$key already in sync"
  fi
}

step "Read devops .env and reconcile into backend .env"
# `while read` returns non-zero on the last line if there's no trailing newline;
# disable -e around the loop so the script doesn't abort on a successful sync.
set +e
while IFS='=' read -r key new_val; do
  case " ${SYNC_KEYS[*]} " in
    *" $key "*) sync_key "$key" "$new_val" ;;
  esac
done <<< "$DEVOPS_ENV_VALS"
set -e

ok "credential sync done (changed=$CHANGED, preserved=$PRESERVED)"
if [[ "$SYNC_HOSTNAME" != "1" ]]; then
  info "POSTGRES_HOSTNAME not synced (BACKEND_ENV_SYNC_HOSTNAME=1 to force)"
  SKIPPED_HOSTNAME=1
fi
finish_stage
