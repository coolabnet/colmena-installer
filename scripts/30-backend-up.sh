#!/usr/bin/env bash
# Stage 30 -- backend: venv, install, db.create/migrate/seeds, server :8000
# Uses the Makefile (source of truth) for test/seeds, then runs the server directly.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/wait.sh
source "$SCRIPT_DIR/lib/wait.sh"
STAGE_NAME="backend"

# --- helpers (defined first so they're available where called) ---
_create_superadmin_shell() {
  python manage.py shell --settings=colmena.settings.dev <<'PY' >>"$BACKEND_LOG" 2>&1
from django.contrib.auth import get_user_model
from apps.accounts.models import Group
U = get_user_model()
g = Group.objects.filter(name="Superadmin").first()
email = "superadmin@domain.org"
if not U.objects.filter(email=email).exists():
    u = U(email=email, username="superadmin", full_name="Super Admin", is_active=True, is_staff=True, is_superuser=True)
    u.set_password("some-password")
    u.save()
    if g:
        u.groups.add(g)
    print(f"created {email}")
else:
    print(f"{email} already exists")
PY
}

_create_testuser_shell() {
  python manage.py shell --settings=colmena.settings.dev <<'PY' >>"$BACKEND_LOG" 2>&1
from django.contrib.auth import get_user_model
from apps.accounts.models import Group
U = get_user_model()
g = Group.objects.filter(name="User").first()
email = "testuser@domain.org"
if not U.objects.filter(email=email).exists():
    u = U(email=email, username="testuser", full_name="Test User", is_active=True)
    u.set_password("testpassword123")
    u.save()
    if g:
        u.groups.add(g)
    print(f"created {email}")
else:
    print(f"{email} already exists")
PY
}

_setup_testuser_nextcloud() {
  python manage.py shell --settings=colmena.settings.dev <<'PY' >>"$BACKEND_LOG" 2>&1
import sys, requests, os, logging
logger = logging.getLogger(__name__)
from django.contrib.auth import get_user_model
from apps.accounts.models import Group
from apps.organizations.models import Team, Organization, UserTeam
from apps.organizations.resources import team as team_manager
from apps.nextcloud.occ import create_app_password
from apps.nextcloud.resources.files import create_talk_folder, create_projects_folder

def fail(msg):
    print(f"FATAL: {msg}", file=sys.stderr)
    sys.exit(1)

U = get_user_model()
u = U.objects.get(email="testuser@domain.org")
sa = U.objects.get(email="superadmin@domain.org")

NC = "http://localhost:8003"
NC_USER = os.environ["NEXTCLOUD_ADMIN_USER"]
NC_PASS = os.environ["NEXTCLOUD_ADMIN_PASSWORD"]
ADMIN = (NC_USER, NC_PASS)

# 0. Verify superadmin username matches NC admin user
if sa.username != NC_USER:
    fail(f"superadmin.username={sa.username!r} != NEXTCLOUD_ADMIN_USER={NC_USER!r}")

# 1. Ensure superadmin has NC app password (required by team_manager)
if not sa.nc_app_password:
    sa.nc_app_password = create_app_password(NC_USER, NC_PASS)
    sa.save()
    print("Superadmin NC app password set")

# 2. Create NC testuser (idempotent)
r = requests.get(f"{NC}/ocs/v2.php/cloud/users/testuser", auth=ADMIN,
    headers={"OCS-APIRequest": "true"})
if r.status_code == 200:
    print("testuser already exists in Nextcloud")
else:
    r2 = requests.post(f"{NC}/ocs/v2.php/cloud/users", auth=ADMIN,
        headers={"OCS-APIRequest": "true"},
        data={"userid": "testuser", "password": "ColmenaTest2024!"})
    if r2.status_code not in (200, 201):
        fail(f"Failed to create NC user: {r2.status_code} {r2.text[:200]}")
    print(f"Created NC user: {r2.status_code}")

# 3. App password for testuser
if not u.nc_app_password:
    u.nc_app_password = create_app_password("testuser", "ColmenaTest2024!")
    u.save()
    print("testuser app password set")

# 4. Talk folder (idempotent)
try:
    create_talk_folder(u, u.username)
    print("Talk folder ready")
except Exception as e:
    # Non-fatal: "already exists" is fine, other errors are logged but don't block
    print(f"Talk folder note: {e}")

# 5. Projects folder (idempotent)
try:
    create_projects_folder(u, u.username)
    print("Projects folder ready")
except Exception as e:
    print(f"Projects folder note: {e}")

# 6. Organization
org, _ = Organization.objects.get_or_create(
    name="Test Org", defaults={"email": "org@test.org", "created_by": u}
)
print(f"Org ensured: {org.name}")

# 7. Personal workspace
pw = Team.objects.filter(userteam__user=u, is_personal_workspace=True).first()
if not pw:
    team_manager.create_personal_workspace(
        user=u, nextcloud_user_id=u.username,
        team_description="Personal workspace",
    )
    pw = Team.objects.filter(userteam__user=u, is_personal_workspace=True).first()
    print(f"Created personal workspace: {pw.nc_conversation_token}")
else:
    print(f"Personal workspace exists: token={pw.nc_conversation_token}")

# 8. Test team
tt = Team.objects.filter(userteam__user=u, is_personal_workspace=False).first()
if not tt:
    tt = team_manager.create(
        group_name="test-team",
        nextcloud_user_id=u.username,
        organization=org,
        team_name="Test Team",
        user=u,
        team_description="A team for testing",
        team_logo=None,
    )
    print(f"Created Test Team: {tt.nc_conversation_token}")
else:
    print(f"Test Team exists: token={tt.nc_conversation_token}")

# 9. Post-seed assertions
assert sa.nc_app_password, "superadmin has no NC app password"
assert u.nc_app_password, "testuser has no NC app password"
assert pw is not None, "personal workspace not found"
assert pw.nc_conversation_token, "personal workspace has no conversation token"
pw_member = UserTeam.objects.filter(team=pw, user=u).exists()
assert pw_member, "testuser not in personal workspace"
assert tt is not None, "test team not found"
assert tt.nc_conversation_token, "test team has no conversation token"
tt_member = UserTeam.objects.filter(team=tt, user=u).exists()
assert tt_member, "testuser not in test team"

print("All seed assertions passed")
print("Setup complete")
PY
}

stage 30 "Backend: venv, install, db, server"

cd "$BACKEND_DIR" || exit 1

step "Set up Python 3.10.0 via pyenv"
# Use the absolute binary path, not the shim. On a fresh pyenv install the
# python3.10 shim isn't always created (pyenv rehash only generates shims for
# selected tools), so the venv creation that follows would otherwise fail with
# "python3.10: command not found".
export PATH="$HOME/.pyenv/shims:$HOME/.pyenv/bin:$PATH"
PY310="$HOME/.pyenv/versions/3.10.0/bin/python3.10"
[[ -x "$PY310" ]] || { fail "Python 3.10.0 binary missing at $PY310 (prereqs should have built it)"; exit 1; }

step "Ensure backend .env exists"
if [[ ! -f .env && -f .env.example ]]; then
  cp .env.example .env
  ok "created .env from example"
else
  ok ".env present"
fi

step "Create venv with python 3.10.0"
if [[ ! -d venv ]]; then
  "$PY310" -m venv venv >>"$PREREQ_LOG" 2>&1
  ok "created venv"
else
  ok "venv already exists"
fi

step "Install requirements"
# shellcheck disable=SC1091
source venv/bin/activate
if [[ ! -f venv/.installed.stamp ]]; then
  pip install --quiet -r requirements/base.txt -r requirements/dev.txt -r requirements/test.txt >>"$PREREQ_LOG" 2>&1
  touch venv/.installed.stamp
  ok "pip install (base + dev + test)"
else
  ok "pip install (cached via venv/.installed.stamp)"
fi

step "Lint (black --check)"
if black --check . >>"$BACKEND_LOG" 2>&1; then
  ok "black clean"
else
  warn "black reports drift (see $BACKEND_LOG)"
fi

step "Compile translations"
if python manage.py compilemessages >>"$BACKEND_LOG" 2>&1; then
  ok "translations compiled"
else
  warn "compilemessages had warnings"
fi

step "Generate OpenAPI schema (gitignored)"
if python manage.py spectacular --color --file schema.yaml --validate --fail-on-warn >>"$BACKEND_LOG" 2>&1; then
  ok "OpenAPI schema.yaml generated"
else
  warn "OpenAPI generation had warnings (non-fatal)"
fi

step "Run backend tests (via Makefile, so we use the same flags as dev)"
make test >>"$BACKEND_LOG" 2>&1
TC=$?
if [[ $TC -eq 0 ]]; then
  ok "all backend tests pass"
else
  fail "backend tests failed (exit=$TC); see $BACKEND_LOG"
fi

step "Load backend .env for shell commands"
load_backend_env

step "Create DB (idempotent)"
# Use Django to create the DB (avoids needing psql on PATH).
# .env keys: POSTGRES_USERNAME / POSTGRES_DATABASE (NOT POSTGRES_USER / POSTGRES_DB).
if python -c "
import os, sys
import psycopg2
db = os.environ['POSTGRES_DATABASE']
host = os.environ['POSTGRES_HOSTNAME']
port = int(os.environ.get('POSTGRES_PORT', 5432))
user = os.environ['POSTGRES_USERNAME']
pwd  = os.environ['POSTGRES_PASSWORD']
try:
    conn = psycopg2.connect(host=host, port=port, user=user, password=pwd, dbname='postgres')
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute('SELECT 1 FROM pg_database WHERE datname = %s', (db,))
    if cur.fetchone():
        print(f'DB {db} already exists')
    else:
        cur.execute(f'CREATE DATABASE {db}')
        print(f'created DB {db}')
except Exception as e:
    print(f'error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>>"$BACKEND_LOG"; then
  ok "DB create check passed"
else
  warn "DB create check failed; see $BACKEND_LOG"
fi

step "Migrate (dev DB)"
if python manage.py migrate --noinput --settings=colmena.settings.dev >>"$BACKEND_LOG" 2>&1; then
  ok "migrations applied"
else
  fail "migrate failed"
fi

step "Load sites (load_sites_with_hostname)"
if python manage.py load_sites_with_hostname "$BACKEND_HOSTNAME" "$FRONTEND_HOSTNAME" --settings=colmena.settings.dev >>"$BACKEND_LOG" 2>&1; then
  ok "sites loaded"
else
  warn "load_sites_with_hostname had issues (non-fatal)"
fi

step "Seed fixtures (db.seeds via Makefile, dev only)"
make db.seeds >>"$BACKEND_LOG" 2>&1
TC=$?
if [[ $TC -eq 0 ]]; then
  ok "fixtures seeded"
else
  warn "db.seeds had issues (may already be loaded); see $BACKEND_LOG"
fi

step "Seed group permissions (db.seeds.groups via Makefile, dev only)"
make db.seeds.groups >>"$BACKEND_LOG" 2>&1
TC=$?
if [[ $TC -eq 0 ]]; then
  ok "group permissions seeded"
else
  warn "db.seeds.groups had issues; see $BACKEND_LOG"
fi

step "Setup superadmin (best-effort; needs Nextcloud)"
if docker inspect -f '{{.State.Status}}' colmena_nextcloud 2>/dev/null | grep -q running; then
  make setup.superadmin >>"$BACKEND_LOG" 2>&1
  TC=$?
  if [[ $TC -eq 0 ]]; then
    ok "superadmin created via Nextcloud"
  else
    warn "superadmin setup failed; falling back to Django shell"
    _create_superadmin_shell
    ok "superadmin created via Django shell"
  fi
else
  warn "Nextcloud not running; creating superadmin via Django shell"
  _create_superadmin_shell
  ok "superadmin created via Django shell"
fi

step "Create testuser (in 'User' group, allowed by ColmenaLoginSerializer)"
_create_testuser_shell
ok "testuser ensured (idempotent)"

step "Setup testuser Nextcloud + teams"
if curl -s --max-time 3 http://localhost:8003 >/dev/null 2>&1; then
  # Wait for NC OCS API and app-password endpoint to be ready
  for i in $(seq 1 12); do
    if curl -s --max-time 5 "http://localhost:8003/ocs/v2.php/cloud/users?search=testuser" \
        -u "${NEXTCLOUD_ADMIN_USER}:${NEXTCLOUD_ADMIN_PASSWORD}" \
        -H "OCS-APIRequest: true" 2>/dev/null | grep -q '<status>ok</status>'; then
      break
    fi
    sleep 5
  done
  if _setup_testuser_nextcloud; then
    ok "testuser Nextcloud + teams configured"
  else
    # Best-effort: log a quirk and continue. The e2e suite's auth flow needs
    # the testuser to exist, but a failure here usually means Nextcloud's
    # OCS API isn't quite ready yet; the runserver below is what serves the
    # app, and we want the stack to come up regardless. Quirk so the user
    # notices in the e2e report.
    warn "testuser Nextcloud setup failed (see $BACKEND_LOG) -- continuing"
    quirk "nextcloud-testuser" "testuser Nextcloud setup failed; e2e login may not work"
  fi
else
  skip "Nextcloud not reachable, skipping testuser Nextcloud setup"
fi

step "Start backend runserver :$BACKEND_PORT"
if (echo > "/dev/tcp/127.0.0.1/$BACKEND_PORT") 2>/dev/null; then
  warn "port $BACKEND_PORT busy; killing prior listener"
  lsof -ti tcp:"$BACKEND_PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
  sleep 1
fi
setsid nohup python manage.py runserver "0.0.0.0:$BACKEND_PORT" --settings=colmena.settings.dev --noreload \
  >>"$BACKEND_LOG" 2>&1 </dev/null & disown
sleep 2

if wait_for_url "http://localhost:$BACKEND_PORT/api/status/" 15 200; then
  ok "backend up on :$BACKEND_PORT"
else
  fail "backend did not respond on :$BACKEND_PORT; see $BACKEND_LOG"
  tail -30 "$BACKEND_LOG"
fi

step "Sanity check API"
STATUS=$(curl -sS "http://localhost:$BACKEND_PORT/api/status/")
info "$STATUS"
if echo "$STATUS" | jq -e '.backend.status == "ok"' >/dev/null; then
  ok "backend reports ok"
else
  fail "backend reports NOT ok: $STATUS"
fi

finish_stage
