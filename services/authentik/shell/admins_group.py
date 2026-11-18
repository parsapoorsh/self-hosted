# Runs inside the authentik container via `ak shell -c`.
# Env: ADMIN_USER.
import os
from authentik.core.models import User, Group
from authentik.providers.oauth2.models import OAuth2Provider, ScopeMapping

g, _ = Group.objects.get_or_create(name="admins")
u = User.objects.filter(username=os.environ["ADMIN_USER"]).first()
if u is not None:
    g.users.add(u)

gm, _ = ScopeMapping.objects.get_or_create(
    managed="self-hosted/scope-groups",
    defaults={
        "name": "self-hosted groups",
        "scope_name": "groups",
        "description": "Group names for Nexspence admin mapping",
        "expression": "return [group.name for group in request.user.ak_groups.all()]",
    },
)
for p in OAuth2Provider.objects.all():
    p.property_mappings.add(gm)
print("admins group ready")
