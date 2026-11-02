#!/usr/bin/env bash
# Idempotent Keycloak realm + OIDC clients + admin user (home realm).
set -euo pipefail

KCADM=/opt/keycloak/bin/kcadm.sh
SERVER="${KEYCLOAK_SERVER:-http://127.0.0.1:8080}"
REALM="${KEYCLOAK_REALM:-home}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD required}"
SCHEME="${APP_SCHEME:-http}"
DOMAIN="${DOMAIN:-example.com}"
AUTH_ORIGIN="${SCHEME}://auth.${DOMAIN}"

# Nextcloud sometimes emits https:// even on local http; allow both schemes.
CLOUD_HTTP="http://cloud.${DOMAIN}"
CLOUD_HTTPS="https://cloud.${DOMAIN}"
NEXUS_HTTP="http://nexus.${DOMAIN}"
NEXUS_HTTPS="https://nexus.${DOMAIN}"

CLIENT_ID="${OIDC_CLIENT_ID:-nextcloud}"
CLIENT_SECRET="${OIDC_CLIENT_SECRET:?OIDC_CLIENT_SECRET required}"
NEXUS_CLIENT_ID="${NEXUS_OIDC_CLIENT_ID:-nexus}"
NEXUS_CLIENT_SECRET="${NEXUS_OIDC_CLIENT_SECRET:?NEXUS_OIDC_CLIENT_SECRET required}"

TMP_FILES=()
cleanup() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    rm -f "${f}"
  done
}
trap cleanup EXIT

mktemp_tracked() {
  local f
  f="$(mktemp)"
  TMP_FILES+=("${f}")
  echo "${f}"
}

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

# Ensure a confidential OIDC client. kcadm -s drops multi-value arrays; use -f.
ensure_oidc_client() {
  local client_id="$1"
  local client_secret="$2"
  local root_http="$3"
  local root_https="$4"
  # Extra redirect paths (space-separated), relative to each origin root.
  # Example: "/oauth2/callback" for oauth2-proxy.
  local extra_paths="${5:-}"
  local client_uuid client_json attr_json path redirects origins post_logout
  local -a redirect_list origin_list post_list

  redirect_list=()
  origin_list=("${root_http}" "${root_https}")
  post_list=()

  for root in "${root_http}" "${root_https}"; do
    redirect_list+=("${root}" "${root}/" "${root}/*")
    post_list+=("${root}" "${root}/" "${root}/*")
    for path in ${extra_paths}; do
      redirect_list+=("${root}${path}")
      post_list+=("${root}${path}")
    done
  done

  client_json="$(mktemp_tracked)"
  {
    printf '{\n'
    printf '  "clientId": "%s",\n' "${client_id}"
    printf '  "enabled": true,\n'
    printf '  "publicClient": false,\n'
    printf '  "secret": "%s",\n' "${client_secret}"
    printf '  "clientAuthenticatorType": "client-secret",\n'
    printf '  "protocol": "openid-connect",\n'
    printf '  "standardFlowEnabled": true,\n'
    printf '  "directAccessGrantsEnabled": true,\n'
    printf '  "serviceAccountsEnabled": false,\n'
    printf '  "fullScopeAllowed": true,\n'
    printf '  "rootUrl": "%s",\n' "${root_http}"
    printf '  "baseUrl": "/",\n'
    printf '  "redirectUris": [\n'
    local i n
    n="${#redirect_list[@]}"
    for ((i = 0; i < n; i++)); do
      if ((i + 1 < n)); then
        printf '    "%s",\n' "${redirect_list[$i]}"
      else
        printf '    "%s"\n' "${redirect_list[$i]}"
      fi
    done
    printf '  ],\n'
    printf '  "webOrigins": [\n'
    n="${#origin_list[@]}"
    for ((i = 0; i < n; i++)); do
      if ((i + 1 < n)); then
        printf '    "%s",\n' "${origin_list[$i]}"
      else
        printf '    "%s"\n' "${origin_list[$i]}"
      fi
    done
    printf '  ]\n'
    printf '}\n'
  } >"${client_json}"

  client_uuid="$(
    ${KCADM} get clients -r "${REALM}" -q "clientId=${client_id}" --fields id --format csv --noquotes 2>/dev/null \
      | head -n1 | tr -d '\r'
  )"

  if [[ -n "${client_uuid}" && "${client_uuid}" != "id" ]]; then
    echo "keycloak-bootstrap: updating client '${client_id}'"
    ${KCADM} update "clients/${client_uuid}" -r "${REALM}" -f "${client_json}"
  else
    echo "keycloak-bootstrap: creating client '${client_id}'"
    ${KCADM} create clients -r "${REALM}" -f "${client_json}"
  fi

  # kcadm -f sometimes drops attributes; set post-logout URIs explicitly.
  client_uuid="$(
    ${KCADM} get clients -r "${REALM}" -q "clientId=${client_id}" --fields id --format csv --noquotes 2>/dev/null \
      | head -n1 | tr -d '\r'
  )"
  post_logout="$(IFS='##'; echo "${post_list[*]}")"
  attr_json="$(mktemp_tracked)"
  cat >"${attr_json}" <<EOF
{
  "attributes": {
    "post.logout.redirect.uris": "${post_logout}",
    "backchannel.logout.session.required": "true"
  }
}
EOF
  ${KCADM} update "clients/${client_uuid}" -r "${REALM}" -f "${attr_json}" >/dev/null
}

ensure_oidc_client \
  "${CLIENT_ID}" \
  "${CLIENT_SECRET}" \
  "${CLOUD_HTTP}" \
  "${CLOUD_HTTPS}" \
  ""

ensure_oidc_client \
  "${NEXUS_CLIENT_ID}" \
  "${NEXUS_CLIENT_SECRET}" \
  "${NEXUS_HTTP}" \
  "${NEXUS_HTTPS}" \
  "/oauth2/callback"

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

# Same admin as master realm, in the app realm for OIDC login (Nextcloud + Nexus).
ensure_user \
  "${ADMIN_USER}" \
  "${ADMIN_PASS}" \
  "${ADMIN_USER}@${DOMAIN}" \
  "Admin" \
  "User"

# Drop legacy default SSO account if it still exists from earlier boots.
LEGACY_SSO_ID="$(
  ${KCADM} get users -r "${REALM}" -q "username=user" --fields id --format csv --noquotes 2>/dev/null \
    | head -n1 | tr -d '\r'
)"
if [[ -n "${LEGACY_SSO_ID}" && "${LEGACY_SSO_ID}" != "id" ]]; then
  echo "keycloak-bootstrap: removing legacy SSO user 'user'"
  ${KCADM} delete "users/${LEGACY_SSO_ID}" -r "${REALM}" >/dev/null || true
fi

echo "keycloak-bootstrap: done (realm=${REALM} clients=${CLIENT_ID},${NEXUS_CLIENT_ID} admin=${ADMIN_USER} idp=${AUTH_ORIGIN})"
