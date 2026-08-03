# Verbatim superadmin + testuser creation from scripts/30-backend-up.sh
# (_create_superadmin_shell + _create_testuser_shell). Idempotent.
# Run via:  python manage.py shell --settings=colmena.settings.dev < docker/create_users.py
import os
from django.contrib.auth import get_user_model
from apps.accounts.models import Group

U = get_user_model()

# Superadmin (username MUST equal NEXTCLOUD_ADMIN_USER — the NC seed asserts it).
sa_email = os.environ.get("SUPERADMIN_EMAIL", "superadmin@domain.org")
sa_pass = os.environ.get("SUPERADMIN_PASSWORD", "some-password")
nc_user = os.environ.get("NEXTCLOUD_ADMIN_USER", "superadmin")
g = Group.objects.filter(name="Superadmin").first()
if not U.objects.filter(email=sa_email).exists():
    u = U(email=sa_email, username=nc_user, full_name="Super Admin",
          is_active=True, is_staff=True, is_superuser=True)
    u.set_password(sa_pass)
    u.save()
    if g:
        u.groups.add(g)
    print(f"created {sa_email}")
else:
    print(f"{sa_email} already exists")

# Testuser — credentials MUST match the e2e suite (testuser@domain.org / testpassword123).
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
