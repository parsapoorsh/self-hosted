#!/usr/bin/env bash
# Idempotent Keycloak setup after entrypoint has a working kcadm session:
# permanent master admin, app realm, OIDC clients, shared admin user.
set -euo pipefail

KCADM=/opt/keycloak/bin/kcadm.sh
SERVER="${KEYCLOAK_SERVER:-http://127.0.0.1:8080}"
REALM="${KEYCLOAK_REALM:-home}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD required}"
# Keycloak 26 first-boot temp user (compose sets KC_BOOTSTRAP_ADMIN_*).
BOOTSTRAP_USER="${KC_BOOTSTRAP_ADMIN_USERNAME:-bootstrap-admin}"
SCHEME="${APP_SCHEME:-http}"
DOMAIN="${DOMAIN:-example.com}"
AUTH_ORIGIN="${SCHEME}://auth.${DOMAIN}"

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
  printf '%s\n' "${f}"
}

log() {
  echo "keycloak-bootstrap: $*" >&2
}

kcadm_login() {
  ${KCADM} config credentials \
    --server "${SERVER}" \
    --realm master \
    --user "$1" \
    --password "$2" \
    >/dev/null
}

# username= is prefix search unless exact=true ("admin" matches "bootstrap-admin").
user_id() {
  local realm="$1"
  local username="$2"
  local id uname
  while IFS=',' read -r id uname; do
    id="${id//$'\r'/}"
    uname="${uname//$'\r'/}"
    [[ -z "${id}" || "${id}" == "id" ]] && continue
    if [[ "${uname}" == "${username}" ]]; then
      printf '%s' "${id}"
      return 0
    fi
  done < <(
    ${KCADM} get users -r "${realm}" \
      -q "username=${username}" \
      -q exact=true \
      --fields id,username \
      --format csv \
      --noquotes \
      2>/dev/null || true
  )
}

user_is_temporary() {
  local username="$1"
  local json
  [[ -z "$(user_id master "${username}")" ]] && return 1
  json="$(
    ${KCADM} get users -r master \
      -q "username=${username}" \
      -q exact=true \
      -q briefRepresentation=false \
      2>/dev/null || true
  )"
  printf '%s' "${json}" | grep -q 'is_temporary_admin'
}

delete_user() {
  local realm="$1"
  local username="$2"
  local id
  id="$(user_id "${realm}" "${username}")"
  [[ -z "${id}" ]] && return 0
  log "deleting ${realm} user '${username}'"
  ${KCADM} delete "users/${id}" -r "${realm}" >/dev/null || true
}

ensure_master_admin_user() {
  local username="$1"
  local password="$2"
  local id
  id="$(user_id master "${username}")"
  if [[ -z "${id}" ]]; then
    log "creating permanent master admin '${username}'"
    ${KCADM} create users -r master \
      -s "username=${username}" \
      -s enabled=true \
      -s emailVerified=true
    id="$(user_id master "${username}")"
  else
    log "updating permanent master admin '${username}'"
    ${KCADM} update "users/${id}" -r master \
      -s enabled=true \
      -s emailVerified=true \
      >/dev/null
  fi
  [[ -n "${id}" ]] || {
    log "failed to resolve master admin '${username}'" >&2
    return 1
  }
  ${KCADM} set-password -r master --userid "${id}" --new-password "${password}" >/dev/null
  ${KCADM} add-roles -r master --uid "${id}" --rolename admin >/dev/null
}

# Turn Keycloak 26 temp bootstrap admin into permanent KEYCLOAK_ADMIN.
ensure_master_admin() {
  local bridge="${BOOTSTRAP_USER}-bridge"

  if user_is_temporary "${ADMIN_USER}"; then
    # Rare: temp user already named like KEYCLOAK_ADMIN.
    ensure_master_admin_user "${bridge}" "${ADMIN_PASS}"
    kcadm_login "${bridge}" "${ADMIN_PASS}"
    delete_user master "${ADMIN_USER}"
    ensure_master_admin_user "${ADMIN_USER}" "${ADMIN_PASS}"
    kcadm_login "${ADMIN_USER}" "${ADMIN_PASS}"
    delete_user master "${bridge}"
  else
    ensure_master_admin_user "${ADMIN_USER}" "${ADMIN_PASS}"
    kcadm_login "${ADMIN_USER}" "${ADMIN_PASS}"
  fi

  if [[ "${BOOTSTRAP_USER}" != "${ADMIN_USER}" ]]; then
    delete_user master "${BOOTSTRAP_USER}"
  fi
  delete_user master "${bridge}"
}

app_origins() {
  local sub="$1"
  local origins=()
  origins+=("http://${sub}.${DOMAIN}" "https://${sub}.${DOMAIN}")
  if [[ "${DOMAIN}" != "localhost" ]]; then
    origins+=("http://${sub}.localhost" "https://${sub}.localhost")
  fi
  printf '%s' "${origins[*]}"
}

ensure_realm() {
  if ${KCADM} get "realms/${REALM}" >/dev/null 2>&1; then
    log "realm '${REALM}' exists"
  else
    log "creating realm '${REALM}'"
    ${KCADM} create realms \
      -s "realm=${REALM}" \
      -s enabled=true \
      -s registrationAllowed=false \
      -s resetPasswordAllowed=true \
      -s editUsernameAllowed=false \
      -s "sslRequired=none"
  fi
  ${KCADM} update "realms/${REALM}" -s "sslRequired=none" >/dev/null
}

# origins: space-separated roots; extra_paths: relative paths per root.
ensure_oidc_client() {
  local client_id="$1"
  local client_secret="$2"
  local origins="$3"
  local extra_paths="${4:-}"
  local client_uuid client_json attr_json path post_logout root first_root
  local -a redirect_list origin_list post_list
  local i n

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
    ${KCADM} get clients -r "${REALM}" -q "clientId=${client_id}" \
      --fields id --format csv --noquotes 2>/dev/null \
      | head -n1 | tr -d '\r'
  )"
  if [[ -n "${client_uuid}" && "${client_uuid}" != "id" ]]; then
    log "updating client '${client_id}'"
    ${KCADM} update "clients/${client_uuid}" -r "${REALM}" -f "${client_json}"
  else
    log "creating client '${client_id}'"
    ${KCADM} create clients -r "${REALM}" -f "${client_json}"
  fi

  client_uuid="$(
    ${KCADM} get clients -r "${REALM}" -q "clientId=${client_id}" \
      --fields id --format csv --noquotes 2>/dev/null \
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

ensure_realm_user() {
  local username="$1"
  local password="$2"
  local email="$3"
  local first="$4"
  local last="$5"
  local id

  id="$(user_id "${REALM}" "${username}")"
  if [[ -n "${id}" ]]; then
    log "user '${username}' exists in ${REALM}"
    ${KCADM} update "users/${id}" -r "${REALM}" \
      -s enabled=true \
      -s "email=${email}" \
      -s emailVerified=true \
      -s "firstName=${first}" \
      -s "lastName=${last}" \
      >/dev/null
  else
    log "creating user '${username}' in ${REALM}"
    ${KCADM} create users -r "${REALM}" \
      -s "username=${username}" \
      -s enabled=true \
      -s "email=${email}" \
      -s emailVerified=true \
      -s "firstName=${first}" \
      -s "lastName=${last}"
    id="$(user_id "${REALM}" "${username}")"
  fi
  [[ -n "${id}" ]] || {
    log "failed to resolve user '${username}'" >&2
    return 1
  }
  ${KCADM} set-password -r "${REALM}" --userid "${id}" --new-password "${password}" >/dev/null
}

# --- main ---
ensure_master_admin
ensure_realm
ensure_oidc_client \
  "${CLIENT_ID}" \
  "${CLIENT_SECRET}" \
  "$(app_origins cloud)" \
  ""
ensure_oidc_client \
  "${NEXUS_CLIENT_ID}" \
  "${NEXUS_CLIENT_SECRET}" \
  "$(app_origins nexus)" \
  "/oauth2/callback"
ensure_realm_user \
  "${ADMIN_USER}" \
  "${ADMIN_PASS}" \
  "${ADMIN_USER}@${DOMAIN}" \
  "Admin" \
  "User"
delete_user "${REALM}" user

log "done (realm=${REALM} clients=${CLIENT_ID},${NEXUS_CLIENT_ID} admin=${ADMIN_USER} idp=${AUTH_ORIGIN})"
