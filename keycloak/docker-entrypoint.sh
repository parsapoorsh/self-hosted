#!/usr/bin/env bash
# Start Keycloak, then (re)apply realm/client/SSO user in the background.
set -euo pipefail

BOOTSTRAP=/init/bootstrap-realm.sh

# Run bootstrap once Keycloak accepts admin API (same process tree).
(
  echo "keycloak: bootstrap waiting for admin API"
  for i in $(seq 1 90); do
    if /opt/keycloak/bin/kcadm.sh config credentials \
      --server http://127.0.0.1:8080 \
      --realm master \
      --user "${KEYCLOAK_ADMIN:-admin}" \
      --password "${KEYCLOAK_ADMIN_PASSWORD}" \
      >/dev/null 2>&1
    then
      echo "keycloak: bootstrap authenticated (try ${i})"
      # Prefer in-container URL for kcadm; browser hostname stays KC_HOSTNAME.
      export KEYCLOAK_SERVER=http://127.0.0.1:8080
      exec /bin/bash "${BOOTSTRAP}"
    fi
    sleep 2
  done
  echo "keycloak: bootstrap gave up waiting for admin API" >&2
  exit 1
) &

exec /opt/keycloak/bin/kc.sh start
