#!/usr/bin/env bash
# Runs inside the nextcloud container on every start (official image hook).
# Configures user_oidc against Keycloak. Idempotent.
set -euo pipefail

OCC=(php /var/www/html/occ)
SCHEME="${APP_SCHEME:-http}"
DOMAIN="${DOMAIN:-example.com}"
REALM="${KEYCLOAK_REALM:-home}"
CLIENT_ID="${OIDC_CLIENT_ID:-nextcloud}"
CLIENT_SECRET="${OIDC_CLIENT_SECRET:-}"
PROVIDER_ID="${OIDC_PROVIDER_ID:-Keycloak}"

if [[ -z "${CLIENT_SECRET}" ]]; then
  echo "oidc-hook: OIDC_CLIENT_SECRET empty — skip"
  exit 0
fi

# Internal discovery (service name). Public auth.<DOMAIN> is for browsers only;
# *.localhost resolves to loopback inside containers and breaks OIDC.
DISCOVERY_INTERNAL="http://keycloak:8080/realms/${REALM}/.well-known/openid-configuration"
# Provider still stores this URL; Keycloak KC_HOSTNAME keeps browser endpoints public.
DISCOVERY="${DISCOVERY_INTERNAL}"

if ! "${OCC[@]}" status 2>/dev/null | grep -q 'installed: true'; then
  echo "oidc-hook: nextcloud not installed yet — skip"
  exit 0
fi

"${OCC[@]}" config:system:set allow_local_remote_servers --type=boolean --value=true >/dev/null
"${OCC[@]}" config:system:set trusted_domains 0 --value="cloud.${DOMAIN}" >/dev/null
"${OCC[@]}" config:system:set overwritehost --value="cloud.${DOMAIN}" >/dev/null
"${OCC[@]}" config:system:set overwrite.cli.url --value="${SCHEME}://cloud.${DOMAIN}" >/dev/null
# Pin public URL scheme so OIDC redirect_uri matches Keycloak (and APP_SCHEME).
"${OCC[@]}" config:system:set overwriteprotocol --value="${SCHEME}" >/dev/null

if ! "${OCC[@]}" app:list --enabled 2>/dev/null | grep -q 'user_oidc'; then
  echo "oidc-hook: installing user_oidc"
  "${OCC[@]}" app:install user_oidc 2>/dev/null || true
  "${OCC[@]}" app:enable user_oidc || true
fi

echo "oidc-hook: waiting for Keycloak ${DISCOVERY_INTERNAL}"
for i in $(seq 1 60); do
  if php -r "exit(@file_get_contents('${DISCOVERY_INTERNAL}') === false ? 1 : 0);"; then
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "oidc-hook: Keycloak discovery not reachable — skip (will retry next start)"
    exit 0
  fi
  sleep 2
done

# If discovery still advertises auth.<DOMAIN> token URLs, force IPv4-friendly
# access by also trusting the internal issuer host via overwrite is N/A;
# KC_HOSTNAME_BACKCHANNEL_DYNAMIC lets Keycloak accept internal backchannel.
echo "oidc-hook: configuring provider '${PROVIDER_ID}'"
"${OCC[@]}" user_oidc:provider "${PROVIDER_ID}" \
  --clientid="${CLIENT_ID}" \
  --clientsecret="${CLIENT_SECRET}" \
  --discoveryuri="${DISCOVERY}" \
  --scope="openid email profile" \
  --unique-uid=0 \
  --mapping-uid=preferred_username \
  --mapping-display-name=name \
  --mapping-email=email \
  >/dev/null

"${OCC[@]}" config:app:set user_oidc allow_multiple_user_backends --value=1 >/dev/null
# user_oidc blocks OIDC on plain HTTP unless this is set (local APP_SCHEME=http).
if [[ "${SCHEME}" == "http" ]]; then
  "${OCC[@]}" config:app:set user_oidc allow_insecure_http --value=1 --type=boolean >/dev/null
else
  "${OCC[@]}" config:app:delete user_oidc allow_insecure_http >/dev/null 2>&1 || true
fi
echo "oidc-hook: provider ready"
