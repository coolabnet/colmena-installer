#!/usr/bin/env bash
# Colmena backend container entrypoint.
# Reuses the proven stage-30 (scripts/30-backend-up.sh) sequence, adapted to run
# inside the container with system python (no pyenv/venv) and compose networking
# (Postgres at `postgres`, Nextcloud at `http://nextcloud`). Idempotent: a restart
# re-runs each step safely, then execs the dev server.
set -uo pipefail

SETTINGS="colmena.settings.dev"
PY="python"

echo "[backend] DJANGO_SETTINGS_MODULE=$SETTINGS"
echo "[backend] POSTGRES_HOSTNAME=$POSTGRES_HOSTNAME POSTGRES_DATABASE=$POSTGRES_DATABASE"
echo "[backend] NEXTCLOUD_URL=$NEXTCLOUD_URL"

# 0. Allow container-network Host headers. The frontend fetches the OpenAPI schema
#    via http://backend:8000 (Host: backend:8000) and the browser arrives via Caddy
#    (Host: localhost:8090). dev.py leaves ALLOWED_HOSTS unset (Django default only
#    permits localhost/127.0.0.1), which rejects `backend`. For this local dev
#    container, allow all hosts. Idempotent. (Mirrors the stage-30 droplet patch.)
DEV_PY="colmena/settings/dev.py"
if ! grep -q "ALLOWED_HOSTS" "$DEV_PY"; then
  printf '\n# [compose] allow any Host (container network: backend, localhost:8090, ...)\nALLOWED_HOSTS = ["*"]\n' >> "$DEV_PY"
  echo "[backend] ALLOWED_HOSTS=['*'] appended to dev.py"
fi

# 1. Generate the Nextcloud OpenAPI client from the committed schema.json.
#    Without it Django fails to import apps.nextcloud.* (ModuleNotFoundError).
echo "[backend] generating OpenAPI client"
openapi-python-generator apps/nextcloud/openapi/schema.json apps/nextcloud/openapi/client \
  || echo "[backend] WARN: openapi client generation failed (may already exist)"

# 2. Wait for Postgres (depends_on healthcheck already gates this; double-check).
echo "[backend] waiting for Postgres"
for i in $(seq 1 30); do
  if $PY -c "import psycopg2,os;psycopg2.connect(host=os.environ['POSTGRES_HOSTNAME'],port=int(os.environ.get('POSTGRES_PORT',5432)),user=os.environ['POSTGRES_USERNAME'],password=os.environ['POSTGRES_PASSWORD'],dbname='postgres')" 2>/dev/null; then
    echo "[backend] Postgres ready"; break
  fi
  sleep 2
done

# 3. Create the application database (idempotent).
echo "[backend] creating database"
$PY ./bin/postgres.py CREATE || echo "[backend] WARN: db create reported an issue (may already exist)"

# 4. Migrate.
echo "[backend] migrating"
$PY manage.py migrate --noinput --settings="$SETTINGS" || { echo "[backend] FATAL: migrate failed"; exit 1; }

# 5. Single-domain safety: relax django_site.domain uniqueness (Sites are looked up
#    by NAME, never domain). On a single-host install the two seeded Sites *can*
#    resolve to the same bare host and hit the UNIQUE(domain) constraint, rolling
#    back the whole Sites fixture. With the localhost defaults they usually don't
#    collide, so this is a harmless, idempotent, Postgres-only safety net. (Stage-30.)
echo "[backend] relaxing django_site uniqueness (single-domain)"
$PY manage.py shell --settings="$SETTINGS" <<'PYEOF' || echo "[backend] WARN: could not relax django_site uniqueness"
from django.db import connection
if connection.vendor == "postgresql":
    with connection.cursor() as cur:
        cur.execute(
            "SELECT conname FROM pg_constraint "
            "WHERE conrelid = 'django_site'::regclass AND contype = 'u'"
        )
        for (name,) in cur.fetchall():
            cur.execute(f'ALTER TABLE django_site DROP CONSTRAINT IF EXISTS "{name}"')
        cur.execute(
            "SELECT indexname FROM pg_indexes WHERE tablename = 'django_site' "
            "AND indexdef ILIKE '%unique%' AND indexdef ILIKE '%domain%'"
        )
        for (name,) in cur.fetchall():
            cur.execute(f'DROP INDEX IF EXISTS "{name}"')
PYEOF

# 6. Load sites for this hostname.
echo "[backend] loading sites"
$PY manage.py load_sites_with_hostname "$BACKEND_HOSTNAME" "$FRONTEND_HOSTNAME" --settings="$SETTINGS" \
  || echo "[backend] WARN: load_sites_with_hostname had issues (non-fatal)"

# 7. Seed JSON fixtures (equivalent of Makefile db.seeds, dev only).
echo "[backend] seeding fixtures"
for i in $(find . -path "*/seeds/*.json" -type f -exec basename {} \; | sort); do
  find . -name "$i" -exec $PY manage.py loaddata {} --settings="$SETTINGS" \;
done

# 8. Seed group permissions (Makefile db.seeds.groups, dev only).
echo "[backend] seeding group permissions"
$PY manage.py setup_group_permissions --settings="$SETTINGS" \
  || echo "[backend] WARN: setup_group_permissions had issues"

# 9. Superadmin (via Nextcloud; fall back to a pure-Django create).
echo "[backend] creating superadmin"
if ! $PY manage.py create_superadmin "$SUPERADMIN_EMAIL" "$SUPERADMIN_PASSWORD" \
      "$NEXTCLOUD_ADMIN_USER" "$NEXTCLOUD_ADMIN_PASSWORD" --settings="$SETTINGS" 2>/dev/null; then
  echo "[backend] create_superadmin failed; using Django-shell fallback"
  $PY manage.py shell --settings="$SETTINGS" < docker/create_users.py \
    || echo "[backend] WARN: user creation reported an issue"
else
  # Still ensure the testuser exists (create_superadmin only makes the superadmin).
  $PY manage.py shell --settings="$SETTINGS" < docker/create_users.py \
    || echo "[backend] WARN: testuser creation reported an issue"
fi

# 10. Wait for the Nextcloud OCS API.
echo "[backend] waiting for Nextcloud OCS API"
for i in $(seq 1 24); do
  if curl -fsS --max-time 5 "$NEXTCLOUD_URL/status.php" 2>/dev/null | grep -q '"installed":true'; then
    echo "[backend] Nextcloud ready"; break
  fi
  sleep 5
done

# 11. Ensure Talk (spreed) is enabled. The nextcloud image's post-install hook runs
#     `occ app:install spreed`, which needs apps.nextcloud.com reachable. When the
#     app store is down/slow, fall back to injecting the release tarball straight
#     into the shared nextcloud_data volume (mounted at /nextcloud_data, see
#     docker-compose.yml) and enabling it via the OCS Provisioning API -- this
#     automates the manual `docker cp` workaround documented in TASK.md.
SPREED_VERSION="${SPREED_VERSION:-18.0.11}"
NC_ADMIN_AUTH="$NEXTCLOUD_ADMIN_USER:$NEXTCLOUD_ADMIN_PASSWORD"
ocs_spreed_enabled() {
  # --retry covers Nextcloud returning transient 503s right after first boot
  # (still finishing background init even though status.php already says
  # installed:true) -- without it a single 503 here reads as "spreed absent"
  # and wrongly triggers the tarball fallback even when the app store's own
  # `occ app:install spreed` already succeeded.
  curl -fsS --retry 6 --retry-delay 5 --retry-connrefused --max-time 10 \
    -u "$NC_ADMIN_AUTH" -H "OCS-APIRequest: true" \
    "$NEXTCLOUD_URL/ocs/v2.php/cloud/apps?filter=enabled&format=json" 2>/dev/null | grep -q '"spreed"'
}
ocs_enable_spreed() {
  curl -fsS --retry 6 --retry-delay 5 --retry-connrefused --max-time 30 \
    -u "$NC_ADMIN_AUTH" -H "OCS-APIRequest: true" \
    -X POST "$NEXTCLOUD_URL/ocs/v2.php/cloud/apps/spreed?format=json" >/dev/null 2>&1
}
echo "[backend] checking Talk (spreed) app status"
if ocs_spreed_enabled; then
  echo "[backend] spreed already enabled"
elif ocs_enable_spreed && ocs_spreed_enabled; then
  echo "[backend] spreed installed via app store"
else
  echo "[backend] app store install unavailable; injecting spreed v$SPREED_VERSION from GitHub releases"
  TARBALL="/tmp/spreed-v${SPREED_VERSION}.tar.gz"
  # -C - resumes across retries instead of restarting from byte 0 -- on a slow/
  # rate-limited link a single --max-time can't land the ~40MB asset in one shot,
  # but each retry keeps the bytes already downloaded (curl skips ahead via Range).
  # Deliberately NOT deleting a partial $TARBALL on failure: it lives in the
  # container's /tmp, so a plain `docker compose restart backend` (no rebuild)
  # re-runs this step and resumes from wherever the last attempt left off,
  # instead of losing all progress and starting the ~40MB download over.
  if curl -fsSL -C - --retry 10 --retry-delay 5 --max-time 90 \
       "https://github.com/nextcloud-releases/spreed/releases/download/v${SPREED_VERSION}/spreed-v${SPREED_VERSION}.tar.gz" \
       -o "$TARBALL"; then
    # curl exiting 0 means the transfer completed, but a completed transfer can
    # still be a corrupt/truncated archive (e.g. a proxy served an error page
    # as 200). Validate before extracting: extracting a bad archive can partially
    # write custom_apps/spreed, and if we then kept the file, the NEXT restart's
    # `curl -C -` would request a range past EOF on an already-"complete" file,
    # get HTTP 416, and fail before ever retrying the download from scratch.
    if tar -tzf "$TARBALL" >/dev/null 2>&1 \
       && mkdir -p /nextcloud_data/custom_apps \
       && tar -xzf "$TARBALL" -C /nextcloud_data/custom_apps \
       && chown -R 33:33 /nextcloud_data/custom_apps/spreed; then
      rm -f "$TARBALL"
      ocs_enable_spreed
      if ocs_spreed_enabled; then
        echo "[backend] spreed enabled via tarball fallback"
      else
        echo "[backend] WARN: spreed still not enabled after tarball fallback"
      fi
    else
      # Archive is corrupt/truncated or extraction failed outright -- remove it
      # so the next restart starts a fresh full download instead of resuming
      # (via Range) into a file curl already considers complete.
      rm -f "$TARBALL"
      echo "[backend] WARN: spreed tarball was corrupt or failed to extract (removed, will re-download on next restart) -- Talk will be unavailable"
    fi
  else
    echo "[backend] WARN: spreed tarball download failed (partial download kept at $TARBALL for resume) -- Talk will be unavailable"
  fi
fi

# 12. Disable the Circles app. Colmena doesn't use it (grep confirms zero
#     references), and its async hook (`POST /apps/circles/async/<uuid>/`)
#     races the group-membership OCS call fired by the seed step below,
#     making `add_user_to_group` return an inner `[996] Internal Server Error`
#     despite an outer HTTP 200 -- reproduced on repeated clean boots.
#     Disabling it here sidesteps the race entirely. Idempotent + non-fatal:
#     if it's already disabled or the call fails, the seed still runs.
echo "[backend] disabling Circles app (avoids group-membership race, see TASK-4)"
curl -fsS --retry 6 --retry-delay 5 --retry-connrefused --max-time 30 \
  -u "$NC_ADMIN_AUTH" -H "OCS-APIRequest: true" \
  -X DELETE "$NEXTCLOUD_URL/ocs/v2.php/cloud/apps/circles?format=json" >/dev/null 2>&1 \
  && echo "[backend] circles disabled" \
  || echo "[backend] WARN: could not disable circles (non-fatal, continuing)"

# 13. Seed Nextcloud testuser + teams.
echo "[backend] seeding Nextcloud testuser + teams"
$PY manage.py shell --settings="$SETTINGS" < docker/seed_nextcloud.py \
  || echo "[backend] WARN: Nextcloud seed failed (e2e login may not work) -- continuing"

# 14. Serve.
echo "[backend] starting runserver 0.0.0.0:8000"
exec $PY manage.py runserver 0.0.0.0:8000 --settings="$SETTINGS"
