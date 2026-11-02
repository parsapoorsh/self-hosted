#!/usr/bin/env bash
# Idempotent Keycloak realm + OIDC clients + admin user (home realm).
# Entrypoint already authenticated kcadm (permanent admin or bootstrap temp).
set -euo pipefail

KCADM=/opt/keycloak/bin/kcadm.sh
SERVER="${KEYCLOAK_SERVER:-http://127.0.0.1:8080}"
REALM="${KEYCLOAK_REALM:-home}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD required}"
# Keycloak 26+ first-boot temp admin (compose sets KC_BOOTSTRAP_ADMIN_*).
BOOTSTRAP_USER="${KC_BOOTSTRAP_ADMIN_USERNAME:-bootstrap-admin}"
SCHEME="${APP_SCHEME:-http}"
DOMAIN="${DOMAIN:-example.com}"
AUTH_ORIGIN="${SCHEME}://auth.${DOMAIN}"

# App origins: primary DOMAIN plus localhost aliases (same stack, local browser).
# Nextcloud sometimes emits https:// even on local http; allow both schemes.
app_origins() {
  # $1 = subdomain label (cloud, nexus, ...)
  local sub="$1"
  local origins=()
  origins+=("http://${sub}.${DOMAIN}" "https://${sub}.${DOMAIN}")
  if [[ "${DOMAIN}" != "localhost" ]]; then
    origins+=("http://${sub}.localhost" "https://${sub}.localhost")
  fi
  printf '%s' "${origins[*]}"
}

CLOUD_ORIGINS="$(app_origins cloud)"
NEXUS_ORIGINS="$(app_origins nexus)"

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

kcadm_login() {
  local user="$1"
  local pass="$2"
  ${KCADM} config credentials \
    --server "${SERVER}" \
    --realm master \
    --user "${user}" \
    --password "${pass}" \
    >/dev/null
}

master_user_id() {
  local username="$1"
  local id
  id="$(
    ${KCADM} get users -r master -q "username=${username}" \
      --fields id --format csv --noquotes 2>/dev/null \
      | head -n1 | tr -d '\r'
  )"
  if [[ -n "${id}" && "${id}" != "id" ]]; then
    printf '%s' "${id}"
  fi
}

master_user_is_temporary() {
  local username="$1"
  local json
  json="$(
    ${KCADM} get users -r master \
      -q "username=${username}" \
      -q briefRepresentation=false 2>/dev/null || true
  )"
  printf '%s' "${json}" | grep -q 'is_temporary_admin'
}

delete_master_user() {
  local username="$1"
  local id
  id="$(master_user_id "${username}")"
  if [[ -n "${id}" ]]; then
    echo "keycloak-bootstrap: deleting master user '${username}'"
    ${KCADM} delete "users/${id}" -r master >/dev/null || true
  fi
}

create_master_admin() {
  local username="$1"
  local password="$2"
  local user_id
  user_id="$(master_user_id "${username}")"
  if [[ -z "${user_id}" ]]; then
    echo "keycloak-bootstrap: creating permanent master admin '${username}'"
    ${KCADM} create users -r master \
      -s "username=${username}" \
      -s enabled=true \
      -s emailVerified=true
    user_id="$(master_user_id "${username}")"
  else
    echo "keycloak-bootstrap: updating permanent master admin '${username}'"
    ${KCADM} update "users/${user_id}" -r master \
      -s enabled=true \
      -s emailVerified=true >/dev/null
  fi
  ${KCADM} set-password -r master --userid "${user_id}" --new-password "${password}" >/dev/null
  ${KCADM} add-roles -r master --uid "${user_id}" --rolename admin >/dev/null
}

# Replace Keycloak 26 temporary bootstrap admin with a permanent KEYCLOAK_ADMIN.
ensure_master_admin() {
  local promote="${BOOTSTRAP_USER}-promote"
  local existing

  existing="$(master_user_id "${ADMIN_USER}")"
  if [[ -n "${existing}" ]] && ! master_user_is_temporary "${ADMIN_USER}"; then
    create_master_admin "${ADMIN_USER}" "${ADMIN_PASS}"
    kcadm_login "${ADMIN_USER}" "${ADMIN_PASS}"
    if [[ "${BOOTSTRAP_USER}" != "${ADMIN_USER}" ]]; then
      delete_master_user "${BOOTSTRAP_USER}"
    fi
    delete_master_user "${promote}"
    return 0
  fi

  if [[ -n "${existing}" ]] && master_user_is_temporary "${ADMIN_USER}"; then
    # Same username as temp admin: promote via a short-lived intermediate.
    create_master_admin "${promote}" "${ADMIN_PASS}"
    kcadm_login "${promote}" "${ADMIN_PASS}"
    delete_master_user "${ADMIN_USER}"
    create_master_admin "${ADMIN_USER}" "${ADMIN_PASS}"
    kcadm_login "${ADMIN_USER}" "${ADMIN_PASS}"
    delete_master_user "${promote}"
    if [[ "${BOOTSTRAP_USER}" != "${ADMIN_USER}" ]]; then
      delete_master_user "${BOOTSTRAP_USER}"
    fi
    return 0
  fi

  # Fresh install: temp user is BOOTSTRAP_USER, permanent is ADMIN_USER.
  create_master_admin "${ADMIN_USER}" "${ADMIN_PASS}"
  kcadm_login "${ADMIN_USER}" "${ADMIN_PASS}"
  if [[ "${BOOTSTRAP_USER}" != "${ADMIN_USER}" ]]; then
    delete_master_user "${BOOTSTRAP_USER}"
  fi
  delete_master_user "${promote}"
}

ensure_master_admin

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
# origins: space-separated roots (http://host and https://host, DOMAIN + localhost).
ensure_oidc_client() {
  local client_id="$1"
  local client_secret="$2"
  local origins="$3"
  # Extra redirect paths (space-separated), relative to each origin root.
  # Example: "/oauth2/callback" for oauth2-proxy.
  local extra_paths="${4:-}"
  local client_uuid client_json attr_json path post_logout root first_root
  local -a redirect_list origin_list post_list

  redirect_list=()
  origin_list=()
  post_list=()
  first_root=""

  for root in ${origins}; do
    [[ -z "${first_root}" ]] && first_root="${root}"
    origin_list+=("${root}")
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
    printf '  "rootUrl": "%s",\n' "${first_root}"
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
  "${CLOUD_ORIGINS}" \
  ""

ensure_oidc_client \
  "${NEXUS_CLIENT_ID}" \
  "${NEXUS_CLIENT_SECRET}" \
  "${NEXUS_ORIGINS}" \
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
