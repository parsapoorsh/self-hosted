# Runs inside the authentik container via `ak shell -c`.
# Env: ADMIN_USER, ADMIN_PASS, ADMIN_EMAIL.
import os
from authentik.core.models import User, Group

username = os.environ["ADMIN_USER"]
password = os.environ["ADMIN_PASS"]
email = os.environ["ADMIN_EMAIL"]

user, created = User.objects.get_or_create(
    username=username,
    defaults={
        "name": "Admin",
        "email": email,
        "is_active": True,
        "type": "internal",
        "path": "users",
    },
)
user.name = user.name or "Admin"
user.email = email
user.is_active = True
user.set_password(password)
user.save()

# Superuser group (Authentik Admins)
group = Group.objects.filter(name="authentik Admins").first()
if group is not None:
    group.users.add(user)

print(f"authentik-bootstrap: user={username} created={created} pk={user.pk}")
