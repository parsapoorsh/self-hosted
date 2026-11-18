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

# Landing pages (nginx serves static/ for apex / www). Gitignored - build if missing.
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

# Mattermost Calls ICE host: address clients dial for UDP/TCP media (CALLS_PORT).
# chat.$DOMAIN often resolves to 127.0.0.1 in local DNS; that makes the plugin
# bind loopback inside Docker and media fails (sendto: invalid argument).
# Prefer an explicit CALLS_ICE_HOST_OVERRIDE; else the host's primary IPv4.
ensure_calls_ice_host() {
  # shellcheck disable=SC1091
  set -a
  source "${ROOT}/.env"
  set +a

  if [[ -n "${CALLS_ICE_HOST_OVERRIDE:-}" ]]; then
    export CALLS_ICE_HOST_OVERRIDE
    return 0
  fi

  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
  if [[ -z "${ip}" || "${ip}" == 127.* ]]; then
    echo "compose: could not detect host IPv4 for Mattermost Calls ICE" >&2
    echo "compose: set CALLS_ICE_HOST_OVERRIDE in .env (LAN or public IP)" >&2
    exit 1
  fi
  export CALLS_ICE_HOST_OVERRIDE="${ip}"
  echo "compose: CALLS_ICE_HOST_OVERRIDE=${CALLS_ICE_HOST_OVERRIDE} (host IPv4)"
}

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

# Calls ICE host is required for compose interpolation whenever mattermost is
# referenced (up, exec, config, …).
ensure_calls_ice_host

# Fail before docker starts so nginx does not crash-loop on missing DOMAIN cert
# or an empty landing site.
case "${cmd}" in
  up|start|restart)
    require_domain_cert
    ensure_static
    ;;
esac

# App DBs are created by services/postgres/init only on a fresh volume. For an existing
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
    echo "compose: postgres not ready - skip app DB ensure" >&2
    return 1
  fi

  # On a fresh volume postgres is briefly reachable while init scripts run and
  # then restarts, so a single psql attempt can fail mid-connection.
  ensure_app_db() {
    local db="$1" user="$2" pass="$3" i
    for i in $(seq 1 15); do
      if ./scripts/pg-app-db.sh "${db}" "${user}" "${pass}" >/dev/null 2>&1; then
        return 0
      fi
      sleep 2
    done
    echo "compose: could not ensure database ${db}" >&2
    return 1
  }

  local rc=0
  if [[ -n "${AUTH_DB_PASSWORD:-}" ]]; then
    ensure_app_db authentik authentik "${AUTH_DB_PASSWORD}" || rc=1
  fi
  if [[ -n "${MATTERMOST_DB_PASSWORD:-}" ]]; then
    ensure_app_db mattermost mattermost "${MATTERMOST_DB_PASSWORD}" || rc=1
  fi
  if [[ -n "${NEXSPENCE_DB_PASSWORD:-}" ]]; then
    ensure_app_db nexspence nexspence "${NEXSPENCE_DB_PASSWORD}" || rc=1
  fi
  return "${rc}"
}

# Nexspence bootstrap creates source=local admin. OIDC JIT then fails with
# "username conflict". Flip shared admin to source=oidc (external_id=username
# matches Authentik sub_mode=user_username). Password basic-auth still works.
link_nexspence_admin_oidc() {
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
  local user="${KEYCLOAK_ADMIN:-admin}"
  local email="${user}@${DOMAIN:-localhost}"
  local out
  out="$("${COMPOSE[@]}" exec -T postgres \
    psql -U nexspence -d nexspence -v ON_ERROR_STOP=1 -tAc \
    "UPDATE users
     SET source = 'oidc',
         external_id = '${user}',
         email = COALESCE(NULLIF(email, ''), '${email}'),
         updated_at = now()
     WHERE username = '${user}'
       AND source = 'local'
     RETURNING username || ':' || source;" 2>/dev/null || true)"
  out="$(echo "${out}" | tr -d '[:space:]')"
  if [[ -n "${out}" ]]; then
    echo "compose: nexspence linked ${out}"
  else
    echo "compose: nexspence admin already oidc or missing (user=${user})"
  fi
}

# Each post-start step is independent: a slow IdP start must not skip the
# Mattermost team bootstrap or the smoke-check.
post_start() {
  local post_status=0
  echo "compose: authentik bootstrap (shared admin user)..."
  ./services/authentik/bootstrap.sh || post_status=$?
  echo "compose: link nexspence admin to OIDC source..."
  link_nexspence_admin_oidc || true
  echo "compose: mattermost bootstrap (org/team defaults)..."
  ./services/mattermost/bootstrap.sh || post_status=$?
  echo "compose: running smoke-check (bootstraps can take a few minutes)..."
  ./scripts/smoke-check.sh || post_status=$?
  return "${post_status}"
}

status=0
setup_pid=""
if [[ "${cmd}" == "up" ]]; then
  # Bring postgres up first so Authentik/Mattermost DB roles exist before they start.
  "${COMPOSE[@]}" up -d postgres
  status=$?
  # Best effort: on a fresh volume services/postgres/init already creates the app DBs,
  # so a failure here must not stop the stack from starting.
  if [[ "${status}" -eq 0 ]]; then
    ensure_app_dbs || echo "compose: WARN app DB ensure failed (continuing)" >&2
  fi
  if [[ "${status}" -eq 0 ]]; then
    if [[ "${detach}" -eq 1 ]]; then
      "${COMPOSE[@]}" "$@"
      status=$?
      if [[ "${status}" -eq 0 ]]; then
        post_start || status=$?
      fi
    else
      # Foreground up owns the terminal (Ctrl+P/Q detach keys), so run the
      # post-start setup in parallel; the bootstraps wait for services.
      post_start </dev/null &
      setup_pid=$!
      "${COMPOSE[@]}" "$@"
      status=$?
      wait "${setup_pid}" || status=$?
    fi
  fi
else
  "${COMPOSE[@]}" "$@"
  status=$?
fi

exit "${status}"
