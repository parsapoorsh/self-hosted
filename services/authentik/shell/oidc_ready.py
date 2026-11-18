# Runs inside the authentik container via `ak shell -c`.
# Prints `ok` once the OIDC blueprints (apps + email scope) are applied.
from authentik.providers.oauth2.models import OAuth2Provider, ScopeMapping

ids = set(OAuth2Provider.objects.values_list("client_id", flat=True))
need = {"nextcloud", "mirror", "mattermost"}
has_email = ScopeMapping.objects.filter(managed="self-hosted/scope-email-fallback").exists()
print("ok" if need.issubset(ids) and has_email else f"missing={need-ids}")
