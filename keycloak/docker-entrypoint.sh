#!/usr/bin/env bash
# Start Keycloak, then (re)apply realm/client/SSO user in the background.
set -euo pipefail

BOOTSTRAP=/init/bootstrap-realm.sh
SERVER=http://127.0.0.1:8080
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD required}"
# Temporary first-boot user (Keycloak 26+); permanent admin is KEYCLOAK_ADMIN.
BOOTSTRAP_USER="${KC_BOOTSTRAP_ADMIN_USERNAME:-bootstrap-admin}"
BOOTSTRAP_PASS="${KC_BOOTSTRAP_ADMIN_PASSWORD:-${ADMIN_PASS}}"

kcadm_login() {
  local user="$1"
  local pass="$2"
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server "${SERVER}" \
    --realm master \
    --user "${user}" \
    --password "${pass}" \
    >/dev/null 2>&1
}

# Run bootstrap once Keycloak accepts admin API (same process tree).
(
  echo "keycloak: bootstrap waiting for admin API" >&2
  for i in $(seq 1 90); do
    if kcadm_login "${ADMIN_USER}" "${ADMIN_PASS}"; then
      echo "keycloak: bootstrap authenticated as ${ADMIN_USER} (try ${i})" >&2
      export KEYCLOAK_SERVER="${SERVER}"
      exec /bin/bash "${BOOTSTRAP}"
    fi
    if [[ "${BOOTSTRAP_USER}" != "${ADMIN_USER}" ]] \
      && kcadm_login "${BOOTSTRAP_USER}" "${BOOTSTRAP_PASS}"
    then
      echo "keycloak: bootstrap authenticated as ${BOOTSTRAP_USER} (try ${i})" >&2
      export KEYCLOAK_SERVER="${SERVER}"
      exec /bin/bash "${BOOTSTRAP}"
    fi
    sleep 2
  done
  echo "keycloak: bootstrap gave up waiting for admin API" >&2
  exit 1
) &

exec /opt/keycloak/bin/kc.sh start
