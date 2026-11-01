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

ensure_user() {
  local username="$1"
  local password="$2"
  local email="$3"
  local first="$4"
  local last="$5"
  local user_id

  user_id="$(
    ${KCADM} get users -r "${REALM}" -q "username=${username}" --fields id --format csv --noquotes 2>/dev/null \
      | head -n1 | tr -d '\r'
  )"

  if [[ -n "${user_id}" && "${user_id}" != "id" ]]; then
    echo "keycloak-bootstrap: user '${username}' exists"
    ${KCADM} update "users/${user_id}" -r "${REALM}" \
      -s enabled=true \
      -s "email=${email}" \
      -s emailVerified=true \
      -s "firstName=${first}" \
      -s "lastName=${last}" >/dev/null
  else
    echo "keycloak-bootstrap: creating user '${username}'"
    ${KCADM} create users -r "${REALM}" \
      -s "username=${username}" \
      -s enabled=true \
      -s "email=${email}" \
      -s emailVerified=true \
      -s "firstName=${first}" \
      -s "lastName=${last}"
    user_id="$(
      ${KCADM} get users -r "${REALM}" -q "username=${username}" --fields id --format csv --noquotes \
        | head -n1 | tr -d '\r'
    )"
  fi

  ${KCADM} set-password -r "${REALM}" --userid "${user_id}" --new-password "${password}" >/dev/null
}

# Default SSO account (Nextcloud "Login with Keycloak").
ensure_user "${SSO_USER}" "${SSO_PASS}" "${SSO_EMAIL}" "SSO" "User"

# Same admin as master realm, also in the app realm so OIDC login accepts it.
if [[ -n "${ADMIN_USER}" && -n "${ADMIN_PASS}" ]]; then
  ensure_user \
    "${ADMIN_USER}" \
    "${ADMIN_PASS}" \
    "${ADMIN_USER}@${DOMAIN}" \
    "Admin" \
    "User"
fi

echo "keycloak-bootstrap: done (realm=${REALM} client=${CLIENT_ID} sso_user=${SSO_USER} idp=${AUTH_ORIGIN})"
