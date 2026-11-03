#!/usr/bin/env bash
# Ensure shared admin user exists in Authentik (matches KEYCLOAK_ADMIN).
# Uses `ak shell` inside the server container (no API token required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
set -a
source "${ROOT}/.env"
source "${ROOT}/.env.secrets"
set +a

ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:?}"
ADMIN_EMAIL="${AUTH_ADMIN_EMAIL:-${ADMIN_USER}@${DOMAIN:-example.com}}"
DOMAIN="${DOMAIN:-example.com}"
HTTPS_PORT="${HTTPS_PORT:-443}"
HTTPS_PORT_SUFFIX="${HTTPS_PORT_SUFFIX:-}"
if [[ -z "${HTTPS_PORT_SUFFIX}" && "${HTTPS_PORT}" != "443" ]]; then
  HTTPS_PORT_SUFFIX=":${HTTPS_PORT}"
fi
# Public portal URL (tenant base_url). Required in Authentik 2026.x.
AUTH_BASE_URL="https://auth.${DOMAIN}${HTTPS_PORT_SUFFIX}"
AUTH_HOST="auth.${DOMAIN}${HTTPS_PORT_SUFFIX}"
COMPOSE=(docker compose --env-file .env --env-file .env.secrets)

echo "authentik-bootstrap: waiting for healthy authentik..."
for i in $(seq 1 90); do
  st="$("${COMPOSE[@]}" ps authentik --format '{{.Status}}' 2>/dev/null | tail -1 || true)"
  if [[ "${st}" == *healthy* ]]; then
    break
  fi
  sleep 2
done

echo "authentik-bootstrap: upsert user ${ADMIN_USER}"
"${COMPOSE[@]}" exec -T \
  -e ADMIN_USER="${ADMIN_USER}" \
  -e ADMIN_PASS="${ADMIN_PASS}" \
  -e ADMIN_EMAIL="${ADMIN_EMAIL}" \
  authentik ak shell -c '
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
'

# Tenant base_url + brand domain (fixes "base URL has not been configured").
echo "authentik-bootstrap: base_url=${AUTH_BASE_URL}"
"${COMPOSE[@]}" exec -T \
  -e AUTH_BASE_URL="${AUTH_BASE_URL}" \
  -e AUTH_HOST="${AUTH_HOST}" \
  authentik ak shell -c '
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
'

# Wait for custom blueprints (OIDC apps) to apply.
echo "authentik-bootstrap: waiting for OIDC blueprints..."
for i in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T authentik ak shell -c '
from authentik.providers.oauth2.models import OAuth2Provider
ids = set(OAuth2Provider.objects.values_list("client_id", flat=True))
need = {"nextcloud", "mirror", "mattermost"}
print("ok" if need.issubset(ids) else f"missing={need-ids}")
' 2>/dev/null | tail -1 | grep -q '^ok$'; then
    echo "authentik-bootstrap: OIDC apps present"
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "authentik-bootstrap: WARN OIDC apps not ready yet (worker blueprints still applying)" >&2
  fi
  sleep 3
done

# Ensure RS256 signing keys (Nextcloud/Nexspence reject HS256) + GitLab username claim.
echo "authentik-bootstrap: ensuring RS256 signing keys"
"${COMPOSE[@]}" exec -T authentik ak shell -c '
from authentik.crypto.models import CertificateKeyPair
from authentik.providers.oauth2.models import OAuth2Provider, ScopeMapping

cert = CertificateKeyPair.objects.filter(name__icontains="Self-signed").first()
if cert is None:
    cert = CertificateKeyPair.objects.filter(name__icontains="JWT").first()
if cert is None:
    raise SystemExit("no signing certificate found")

sm, _ = ScopeMapping.objects.get_or_create(
    managed="goauthentik.io/providers/oauth2/scope-username-gitlab",
    defaults={
        "name": "Authentik self-hosted GitLab username",
        "scope_name": "profile",
        "description": "Expose username for Mattermost GitLab OIDC",
        "expression": "return {\"username\": request.user.username, \"preferred_username\": request.user.username}",
    },
)
std = list(ScopeMapping.objects.filter(managed__in=[
    "goauthentik.io/providers/oauth2/scope-openid",
    "goauthentik.io/providers/oauth2/scope-email",
    "goauthentik.io/providers/oauth2/scope-profile",
]))
for p in OAuth2Provider.objects.all():
    p.signing_key = cert
    p.include_claims_in_id_token = True
    p.save()
    p.property_mappings.set(std + [sm])
print("signing_key=%s providers=%s" % (cert.name, OAuth2Provider.objects.count()))
'

# Nexspence maps Authentik group "admins" -> nx-admin. Ensure it exists.
echo "authentik-bootstrap: ensuring admins group"
"${COMPOSE[@]}" exec -T \
  -e ADMIN_USER="${ADMIN_USER}" \
  authentik ak shell -c '
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
'

# Open self-registration (username + password + name + email) + Sign up on login.
echo "authentik-bootstrap: ensuring enrollment (self-signup)"
"${COMPOSE[@]}" exec -T authentik ak shell -c '
from authentik.flows.models import (
    Flow,
    FlowDesignation,
    FlowAuthenticationRequirement,
    FlowStageBinding,
)
from authentik.stages.prompt.models import Prompt, PromptStage, FieldTypes
from authentik.stages.user_write.models import UserWriteStage, UserCreationMode
from authentik.stages.user_login.models import UserLoginStage
from authentik.stages.identification.models import IdentificationStage

def ensure_prompt(name, key, label, ftype, order=0):
    p, _ = Prompt.objects.update_or_create(
        name=name,
        defaults={
            "field_key": key,
            "label": label,
            "type": ftype,
            "required": True,
            "placeholder": label,
            "placeholder_expression": False,
            "order": order,
        },
    )
    return p

p_user = ensure_prompt(
    "self-hosted-enrollment-field-username", "username", "Username", FieldTypes.USERNAME, 0
)
p_pass = ensure_prompt(
    "self-hosted-enrollment-field-password", "password", "Password", FieldTypes.PASSWORD, 0
)
p_pass2 = ensure_prompt(
    "self-hosted-enrollment-field-password-repeat",
    "password_repeat",
    "Password (repeat)",
    FieldTypes.PASSWORD,
    1,
)
p_name = ensure_prompt(
    "self-hosted-enrollment-field-name", "name", "Name", FieldTypes.TEXT, 0
)
p_email = ensure_prompt(
    "self-hosted-enrollment-field-email", "email", "Email", FieldTypes.EMAIL, 1
)

ps1, _ = PromptStage.objects.update_or_create(name="self-hosted-enrollment-prompt-first")
ps1.fields.set([p_user, p_pass, p_pass2])
ps2, _ = PromptStage.objects.update_or_create(name="self-hosted-enrollment-prompt-second")
ps2.fields.set([p_name, p_email])

uw, _ = UserWriteStage.objects.update_or_create(
    name="self-hosted-enrollment-user-write",
    defaults={"user_creation_mode": UserCreationMode.ALWAYS_CREATE},
)
ul, _ = UserLoginStage.objects.update_or_create(name="self-hosted-enrollment-user-login")

flow, _ = Flow.objects.update_or_create(
    slug="default-enrollment-flow",
    defaults={
        "name": "Self-hosted enrollment",
        "title": "Create an account",
        "designation": FlowDesignation.ENROLLMENT,
        "authentication": FlowAuthenticationRequirement.REQUIRE_UNAUTHENTICATED,
    },
)
FlowStageBinding.objects.filter(target=flow).delete()
for order, stage in ((10, ps1), (11, ps2), (20, uw), (100, ul)):
    FlowStageBinding.objects.create(target=flow, stage=stage, order=order)

ident = IdentificationStage.objects.get(name="default-authentication-identification")
ident.user_fields = ["username", "email"]
ident.enrollment_flow = flow
ident.save()
print("signup ready: /if/flow/default-enrollment-flow/")
'

echo "authentik-bootstrap: done"
