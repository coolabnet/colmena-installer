# Verbatim Nextcloud integration seed from scripts/30-backend-up.sh
# (_setup_testuser_nextcloud), with ONLY the Nextcloud URL parametrized so it
# works over compose networking (http://nextcloud) instead of host localhost:8003.
# Run via:  python manage.py shell --settings=colmena.settings.dev < docker/seed_nextcloud.py
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
sa = U.objects.get(email=os.environ.get("SUPERADMIN_EMAIL", "superadmin@domain.org"))

NC = os.environ.get("NEXTCLOUD_URL", "http://nextcloud")
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
