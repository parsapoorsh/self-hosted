#!/usr/bin/env bash
# docker compose wrapper: refresh derived secrets, then run compose with both env files.
# After `up -d`, wait for bootstraps and run smoke-check.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

./scripts/sync-secrets.sh

# Alpine repo signing key (PEM). Create once on the host for Nexspence alpine proxies.
ensure_alpine_signing_key() {
  local key="${ROOT}/cert/alpine.key"
  if [[ -f "${key}" ]]; then
    return 0
  fi
  mkdir -p "${ROOT}/cert"
  echo "compose: creating ${key}"
  openssl genrsa 2048 2>/dev/null \
    | openssl pkcs8 -topk8 -nocrypt -out "${key}"
  # Nexspence container runs as uid 1000; bootstrap must read this key.
  chmod 644 "${key}"
}
# Existing keys may still be 0600 from older compose runs.
if [[ -f "${ROOT}/cert/alpine.key" ]]; then
  chmod 644 "${ROOT}/cert/alpine.key" || true
fi
ensure_alpine_signing_key

# Primary domain TLS material (nginx fails hard without it).
require_domain_cert() {
  local domain="${DOMAIN:-}"
  if [[ -z "${domain}" && -f .env ]]; then
    # shellcheck disable=SC1091
    domain="$(set -a; source .env; set +a; printf '%s' "${DOMAIN:-}")"
  fi
  domain="${domain:-example.com}"
  local dir="${ROOT}/cert/${domain}"
  if [[ -f "${dir}/fullchain.pem" && -f "${dir}/privkey.pem" ]]; then
    return 0
  fi
  echo "compose: missing cert/${domain}/{fullchain,privkey}.pem" >&2
  echo "compose: run ./scripts/self-signed.sh  (or place real LE certs there)" >&2
  exit 1
}

# Landing pages (nginx serves static/ for apex / www). Gitignored — build if missing.
ensure_static() {
  if [[ -f "${ROOT}/static/index.html" ]]; then
    return 0
  fi
  echo "compose: static/ missing or incomplete (need static/index.html)"
  if [[ ! -x "${ROOT}/scripts/build-static.sh" ]]; then
    echo "compose: scripts/build-static.sh not executable" >&2
    exit 1
  fi
  echo "compose: running ./scripts/build-static.sh ..."
  "${ROOT}/scripts/build-static.sh"
  if [[ ! -f "${ROOT}/static/index.html" ]]; then
    echo "compose: static/index.html still missing after build-static" >&2
    exit 1
  fi
}

COMPOSE=(docker compose --env-file .env --env-file .env.secrets)

cmd=""
detach=0
for arg in "$@"; do
  case "${arg}" in
    -d|--detach) detach=1 ;;
    -*)
      ;;
    *)
      if [[ -z "${cmd}" ]]; then
        cmd="${arg}"
      fi
      ;;
  esac
done

# Fail before docker starts so nginx does not crash-loop on missing DOMAIN cert
# or an empty landing site.
case "${cmd}" in
  up|start|restart)
    require_domain_cert
    ensure_static
    ;;
esac

# App DBs are created by postgres/init only on a fresh volume. For an existing
# postgres_data volume, create new app roles before services that need them start.
ensure_app_dbs() {
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  # shellcheck disable=SC1091
  source "${ROOT}/.env.secrets"
  set +a

  echo "compose: waiting for postgres..."
  local i
  for i in $(seq 1 60); do
    if "${COMPOSE[@]}" exec -T postgres pg_isready -U postgres -d postgres >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  if ! "${COMPOSE[@]}" exec -T postgres pg_isready -U postgres -d postgres >/dev/null 2>&1; then
    echo "compose: postgres not ready — skip app DB ensure" >&2
    return 1
  fi

  if [[ -n "${AUTH_DB_PASSWORD:-}" ]]; then
    ./scripts/pg-app-db.sh authelia authelia "${AUTH_DB_PASSWORD}"
  fi
  if [[ -n "${MATTERMOST_DB_PASSWORD:-}" ]]; then
    ./scripts/pg-app-db.sh mattermost mattermost "${MATTERMOST_DB_PASSWORD}"
  fi
  if [[ -n "${NEXSPENCE_DB_PASSWORD:-}" ]]; then
    ./scripts/pg-app-db.sh nexspence nexspence "${NEXSPENCE_DB_PASSWORD}"
  fi
}

status=0
if [[ "${cmd}" == "up" && "${detach}" -eq 1 ]]; then
  # Bring postgres up first so Authelia/Mattermost DB roles exist before they start.
  "${COMPOSE[@]}" up -d postgres
  status=$?
  if [[ "${status}" -eq 0 ]]; then
    ensure_app_dbs || status=$?
  fi
  if [[ "${status}" -eq 0 ]]; then
    "${COMPOSE[@]}" "$@"
    status=$?
  fi
  if [[ "${status}" -eq 0 ]]; then
    echo "compose: running smoke-check (bootstraps can take a few minutes)..."
    ./scripts/smoke-check.sh || status=$?
  fi
else
  "${COMPOSE[@]}" "$@"
  status=$?
fi

exit "${status}"
