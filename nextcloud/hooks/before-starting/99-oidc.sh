#!/bin/sh
# Trusted domains + user_oidc against Authelia. Idempotent.
# Nextcloud image runs hooks with /bin/sh — keep POSIX (no bash arrays).
set -eu

OCC="php /var/www/html/occ"
DOMAIN="${DOMAIN:-example.com}"
SCHEME="${APP_SCHEME:-http}"
CLIENT_ID="${OIDC_CLIENT_ID:-nextcloud}"
CLIENT_SECRET="${OIDC_CLIENT_SECRET:-}"
PROVIDER_ID="${OIDC_PROVIDER_ID:-Authelia}"

if [ -z "${CLIENT_SECRET}" ]; then
  echo "oidc-hook: OIDC_CLIENT_SECRET empty — skip"
  exit 0
fi

# Public discovery for browser redirects (Authelia portal is HTTPS).
# Internal wait uses service DNS.
DISCOVERY="https://auth.${DOMAIN}/.well-known/openid-configuration"
DISCOVERY_INTERNAL="http://authelia:9091/.well-known/openid-configuration"

if ! ${OCC} status 2>/dev/null | grep -q 'installed: true'; then
  echo "oidc-hook: nextcloud not installed yet — skip"
  exit 0
fi

${OCC} config:system:set allow_local_remote_servers --type=boolean --value=true >/dev/null

# Both public names. Do not force overwritehost — Host header must win so
# cloud.localhost stays on localhost (otherwise redirects to cloud.<DOMAIN>).
${OCC} config:system:set trusted_domains 0 --value="cloud.${DOMAIN}" >/dev/null
${OCC} config:system:set trusted_domains 1 --value="cloud.localhost" >/dev/null
${OCC} config:system:delete overwritehost >/dev/null 2>&1 || true
${OCC} config:system:delete overwriteprotocol >/dev/null 2>&1 || true
${OCC} config:system:set overwrite.cli.url \
  --value="${SCHEME}://cloud.${DOMAIN}" >/dev/null

if ! ${OCC} app:list --enabled 2>/dev/null | grep -q 'user_oidc'; then
  echo "oidc-hook: installing user_oidc"
  ${OCC} app:install user_oidc 2>/dev/null || true
  ${OCC} app:enable user_oidc || true
fi

echo "oidc-hook: waiting for Authelia ${DISCOVERY_INTERNAL}"
i=1
while [ "$i" -le 60 ]; do
  if php -r "exit(@file_get_contents('${DISCOVERY_INTERNAL}') === false ? 1 : 0);"; then
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "oidc-hook: Authelia discovery not reachable — skip (will retry next start)"
    exit 0
  fi
  i=$((i + 1))
  sleep 2
done

echo "oidc-hook: configuring provider '${PROVIDER_ID}'"
${OCC} user_oidc:provider "${PROVIDER_ID}" \
  --clientid="${CLIENT_ID}" \
  --clientsecret="${CLIENT_SECRET}" \
  --discoveryuri="${DISCOVERY}" \
  --scope="openid email profile" \
  --unique-uid=0 \
  --mapping-uid=preferred_username \
  --mapping-display-name=name \
  --mapping-email=email \
  >/dev/null

# Drop legacy Keycloak provider name if present (migration).
if [ "${PROVIDER_ID}" != "Keycloak" ]; then
  ${OCC} user_oidc:provider:delete Keycloak 2>/dev/null || true
fi

${OCC} config:app:set user_oidc allow_multiple_user_backends --value=1 >/dev/null
# user_oidc blocks OIDC on plain HTTP unless this is set (local APP_SCHEME=http).
if [ "${SCHEME}" = "http" ]; then
  ${OCC} config:app:set user_oidc allow_insecure_http --value=1 --type=boolean >/dev/null
else
  ${OCC} config:app:delete user_oidc allow_insecure_http >/dev/null 2>&1 || true
fi
echo "oidc-hook: provider ready (trusted=cloud.${DOMAIN},cloud.localhost)"
