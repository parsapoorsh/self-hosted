#!/usr/bin/env bash
# Ensure shared admin user exists in Authentik (matches ADMIN_USERNAME).
# Uses `ak shell` inside the server container (no API token required).
# The Django snippets live in services/authentik/shell/*.py and are read here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

# Never read the terminal: under `timeout` a tty read stops the process group
# with SIGTTIN when this script runs from an interactive compose.sh session.
exec </dev/null

# shellcheck disable=SC1091
set -a
source "${ROOT}/.env"
source "${ROOT}/.env.secrets"
set +a

ADMIN_USER="${ADMIN_USERNAME:-admin}"
ADMIN_PASS="${ADMIN_PASSWORD:?}"
ADMIN_EMAIL="${AUTH_ADMIN_EMAIL:-${ADMIN_USER}@${DOMAIN:-example.com}}"
DOMAIN="${DOMAIN:-example.com}"
HTTPS_PORT="${HTTPS_PORT:-443}"
HTTPS_PORT_SUFFIX="${HTTPS_PORT_SUFFIX:-}"
if [[ -z "${HTTPS_PORT_SUFFIX}" && "${HTTPS_PORT}" != "443" ]]; then
  HTTPS_PORT_SUFFIX=":${HTTPS_PORT}"
fi
# Public portal URL (tenant base_url). Required in Authentik 2026.x.
AUTH_BASE_URL="https://auth.${DOMAIN}${HTTPS_PORT_SUFFIX}"
AUTH_HOST="auth.${DOMAIN}${HTTPS_PORT_SUFFIX}"
COMPOSE=(docker compose --env-file .env --env-file .env.secrets)
PY_DIR="${ROOT}/services/authentik/shell"

# Fail before touching the stack when a snippet is missing, rather than
# running an empty `ak shell -c ""`.
SNIPPETS=(
  upsert_admin.py
  brand_ready.py
  tenant_brand.py
  oidc_ready.py
  oauth2_providers.py
  admins_group.py
  enrollment.py
)
for snippet in "${SNIPPETS[@]}"; do
  if [[ ! -r "${PY_DIR}/${snippet}" ]]; then
    echo "authentik-bootstrap: missing ${PY_DIR}/${snippet}" >&2
    exit 1
  fi
done

# Probe the Django app (DB + migrations + config), not just the health string:
# on a cold volume the HTTP health check can pass briefly before `ak` works.
echo "authentik-bootstrap: waiting for authentik..."
ready=0
for i in $(seq 1 150); do
  if timeout 20 "${COMPOSE[@]}" exec -T authentik \
    ak shell -c '1' </dev/null >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [[ "${ready}" -ne 1 ]]; then
  echo "authentik-bootstrap: authentik did not become ready" >&2
  exit 1
fi

echo "authentik-bootstrap: upsert user ${ADMIN_USER}"
"${COMPOSE[@]}" exec -T \
  -e ADMIN_USER="${ADMIN_USER}" \
  -e ADMIN_PASS="${ADMIN_PASS}" \
  -e ADMIN_EMAIL="${ADMIN_EMAIL}" \
  authentik ak shell -c "$(cat "${PY_DIR}/upsert_admin.py")"

# Tenant base_url + brand domain (fixes "base URL has not been configured").
# The default brand is created by an Authentik blueprint; on a cold volume it
# can land after the health check, so wait for it before patching.
echo "authentik-bootstrap: waiting for default brand..."
for i in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T authentik \
    ak shell -c "$(cat "${PY_DIR}/brand_ready.py")" >/dev/null 2>&1; then
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "authentik-bootstrap: WARN default brand not found" >&2
  fi
  sleep 2
done

echo "authentik-bootstrap: base_url=${AUTH_BASE_URL}"
"${COMPOSE[@]}" exec -T \
  -e AUTH_BASE_URL="${AUTH_BASE_URL}" \
  -e AUTH_HOST="${AUTH_HOST}" \
  authentik ak shell -c "$(cat "${PY_DIR}/tenant_brand.py")"

# Wait for custom blueprints (OIDC apps) to apply.
echo "authentik-bootstrap: waiting for OIDC blueprints..."
for i in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T authentik \
    ak shell -c "$(cat "${PY_DIR}/oidc_ready.py")" 2>/dev/null \
    | tail -1 | grep -q '^ok$'; then
    echo "authentik-bootstrap: OIDC apps present"
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "authentik-bootstrap: WARN OIDC apps not ready yet (worker blueprints still applying)" >&2
  fi
  sleep 3
done

# Ensure RS256 signing keys (Nextcloud/Nexspence reject HS256) + GitLab username claim.
echo "authentik-bootstrap: ensuring RS256 signing keys + grant types"
"${COMPOSE[@]}" exec -T \
  -e NC_SECRET="${OIDC_CLIENT_SECRET}" \
  -e MIRROR_SECRET="${MIRROR_OIDC_CLIENT_SECRET}" \
  -e MM_SECRET="${MATTERMOST_OIDC_CLIENT_SECRET}" \
  authentik ak shell -c "$(cat "${PY_DIR}/oauth2_providers.py")"

# Nexspence maps Authentik group "admins" -> nx-admin. Ensure it exists.
echo "authentik-bootstrap: ensuring admins group"
"${COMPOSE[@]}" exec -T \
  -e ADMIN_USER="${ADMIN_USER}" \
  authentik ak shell -c "$(cat "${PY_DIR}/admins_group.py")"

# Open self-registration (username + password + name) + Sign up on login.
echo "authentik-bootstrap: ensuring enrollment (self-signup)"
"${COMPOSE[@]}" exec -T authentik ak shell -c "$(cat "${PY_DIR}/enrollment.py")"

echo "authentik-bootstrap: done"
