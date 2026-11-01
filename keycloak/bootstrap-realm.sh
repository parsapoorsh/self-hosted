#!/usr/bin/env bash
# Idempotent Keycloak realm + Nextcloud OIDC client + SSO user.
set -euo pipefail

KCADM=/opt/keycloak/bin/kcadm.sh
SERVER="${KEYCLOAK_SERVER:-http://127.0.0.1:8080}"
REALM="${KEYCLOAK_REALM:-home}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD required}"
CLIENT_ID="${OIDC_CLIENT_ID:-nextcloud}"
CLIENT_SECRET="${OIDC_CLIENT_SECRET:?OIDC_CLIENT_SECRET required}"
SCHEME="${APP_SCHEME:-http}"
DOMAIN="${DOMAIN:-example.com}"
CLOUD_ORIGIN="${SCHEME}://cloud.${DOMAIN}"
AUTH_ORIGIN="${SCHEME}://auth.${DOMAIN}"
# Nextcloud sometimes emits https:// even on local http; allow both schemes.
CLOUD_HTTP="http://cloud.${DOMAIN}"
CLOUD_HTTPS="https://cloud.${DOMAIN}"
SSO_USER="${SSO_USERNAME:-user}"
SSO_PASS="${SSO_PASSWORD:?SSO_PASSWORD required}"
SSO_EMAIL="${SSO_EMAIL:-user@localhost}"

${KCADM} config credentials \
  --server "${SERVER}" \
  --realm master \
  --user "${ADMIN_USER}" \
  --password "${ADMIN_PASS}" \
  >/dev/null

if ${KCADM} get "realms/${REALM}" >/dev/null 2>&1; then
  echo "keycloak-bootstrap: realm '${REALM}' exists"
else
  echo "keycloak-bootstrap: creating realm '${REALM}'"
  ${KCADM} create realms \
    -s "realm=${REALM}" \
    -s enabled=true \
    -s registrationAllowed=false \
    -s resetPasswordAllowed=true \
    -s editUsernameAllowed=false \
    -s "sslRequired=none"
fi

${KCADM} update "realms/${REALM}" -s "sslRequired=none" >/dev/null

CLIENT_UUID="$(
  ${KCADM} get clients -r "${REALM}" -q "clientId=${CLIENT_ID}" --fields id --format csv --noquotes 2>/dev/null \
    | head -n1 | tr -d '\r'
)"

# kcadm -s drops multi-value JSON arrays; write a client body file instead.
CLIENT_JSON="$(mktemp)"
trap 'rm -f "${CLIENT_JSON}"' EXIT
cat >"${CLIENT_JSON}" <<EOF
{
  "clientId": "${CLIENT_ID}",
  "enabled": true,
  "publicClient": false,
  "secret": "${CLIENT_SECRET}",
  "clientAuthenticatorType": "client-secret",
  "protocol": "openid-connect",
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": true,
  "serviceAccountsEnabled": false,
  "fullScopeAllowed": true,
  "redirectUris": [
    "${CLOUD_HTTP}/apps/user_oidc/code",
    "${CLOUD_HTTP}/index.php/apps/user_oidc/code",
    "${CLOUD_HTTPS}/apps/user_oidc/code",
    "${CLOUD_HTTPS}/index.php/apps/user_oidc/code"
  ],
  "webOrigins": [
    "${CLOUD_HTTP}",
    "${CLOUD_HTTPS}"
  ]
}
EOF

if [[ -n "${CLIENT_UUID}" && "${CLIENT_UUID}" != "id" ]]; then
  echo "keycloak-bootstrap: updating client '${CLIENT_ID}'"
  ${KCADM} update "clients/${CLIENT_UUID}" -r "${REALM}" -f "${CLIENT_JSON}"
else
  echo "keycloak-bootstrap: creating client '${CLIENT_ID}'"
  ${KCADM} create clients -r "${REALM}" -f "${CLIENT_JSON}"
fi

USER_ID="$(
  ${KCADM} get users -r "${REALM}" -q "username=${SSO_USER}" --fields id --format csv --noquotes 2>/dev/null \
    | head -n1 | tr -d '\r'
)"

if [[ -n "${USER_ID}" && "${USER_ID}" != "id" ]]; then
  echo "keycloak-bootstrap: user '${SSO_USER}' exists"
  ${KCADM} update "users/${USER_ID}" -r "${REALM}" \
    -s enabled=true \
    -s "email=${SSO_EMAIL}" \
    -s emailVerified=true \
    -s "firstName=SSO" \
    -s "lastName=User" >/dev/null
else
  echo "keycloak-bootstrap: creating user '${SSO_USER}'"
  ${KCADM} create users -r "${REALM}" \
    -s "username=${SSO_USER}" \
    -s enabled=true \
    -s "email=${SSO_EMAIL}" \
    -s emailVerified=true \
    -s "firstName=SSO" \
    -s "lastName=User"
  USER_ID="$(
    ${KCADM} get users -r "${REALM}" -q "username=${SSO_USER}" --fields id --format csv --noquotes \
      | head -n1 | tr -d '\r'
  )"
fi

${KCADM} set-password -r "${REALM}" --userid "${USER_ID}" --new-password "${SSO_PASS}" >/dev/null
echo "keycloak-bootstrap: done (realm=${REALM} client=${CLIENT_ID} sso_user=${SSO_USER} idp=${AUTH_ORIGIN})"
