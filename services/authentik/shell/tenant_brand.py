# Runs inside the authentik container via `ak shell -c`.
# Env: AUTH_BASE_URL, AUTH_HOST.
import os
from authentik.tenants.models import Tenant
from authentik.brands.models import Brand
from authentik.core.apps import Setup

base = os.environ["AUTH_BASE_URL"]
host = os.environ["AUTH_HOST"]

t = Tenant.objects.get(schema_name="public")
t.base_url = base
t.save()
# setup=True means first-run wizard is finished (False redirects to /setup).
Setup.set(True, tenant=t)

# Default brand matches public Host (with non-default port when set).
b = Brand.objects.get(default=True)
b.domain = host
b.save()

# Local TLS brand for auth.localhost (and :port).
local_host = "auth.localhost"
if ":" in host:
    local_host = "auth.localhost:" + host.split(":", 1)[1]
lb, created = Brand.objects.get_or_create(
    domain=local_host,
    defaults={
        "default": False,
        "branding_title": b.branding_title,
        "flow_authentication": b.flow_authentication,
        "flow_invalidation": b.flow_invalidation,
        "flow_user_settings": b.flow_user_settings,
    },
)
if not created:
    lb.flow_authentication = b.flow_authentication
    lb.flow_invalidation = b.flow_invalidation
    lb.flow_user_settings = b.flow_user_settings
    lb.save()
print(f"base_url={t.base_url} setup={Setup.get(tenant=t)} brand={b.domain} local={lb.domain}")
