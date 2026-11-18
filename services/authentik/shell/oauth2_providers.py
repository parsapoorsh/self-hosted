# Runs inside the authentik container via `ak shell -c`.
# Env: NC_SECRET, MIRROR_SECRET, MM_SECRET.
import os
from authentik.crypto.models import CertificateKeyPair
from authentik.providers.oauth2.models import OAuth2Provider, ScopeMapping, GrantTypes

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
    "goauthentik.io/providers/oauth2/scope-profile",
]))
# Enrollment has no email prompt; this mapping falls back to username@domain.
em = ScopeMapping.objects.filter(managed="self-hosted/scope-email-fallback").first()
if em is None:
    raise SystemExit("missing self-hosted/scope-email-fallback scope mapping")
# 2026.x stores grant_types=[]; empty list rejects authorization_code as malformed.
grants = [GrantTypes.AUTHORIZATION_CODE, GrantTypes.REFRESH_TOKEN]
secrets = {
    "nextcloud": os.environ.get("NC_SECRET") or "",
    "mirror": os.environ.get("MIRROR_SECRET") or "",
    "mattermost": os.environ.get("MM_SECRET") or "",
}
for p in OAuth2Provider.objects.all():
    p.signing_key = cert
    p.include_claims_in_id_token = True
    p.grant_types = grants
    if secrets.get(p.client_id):
        p.client_secret = secrets[p.client_id]
    p.save()
    p.property_mappings.set(std + [sm, em])
print("signing_key=%s providers=%s grants=authorization_code+refresh_token" % (
    cert.name, OAuth2Provider.objects.count(),
))
