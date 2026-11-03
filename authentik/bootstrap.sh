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

echo "authentik-bootstrap: done"
