#!/usr/bin/env bash
# Post-up checks. Exit 1 if anything critical is wrong.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

if [[ ! -f .env ]]; then
  echo "smoke: missing .env" >&2
  exit 1
fi
if [[ ! -f .env.secrets ]]; then
  ./scripts/sync-secrets.sh
fi

set -a
# shellcheck disable=SC1091
source .env
# shellcheck disable=SC1091
source .env.secrets
set +a

DOMAIN="${DOMAIN:-example.com}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:?}"
COMPOSE=(docker compose --env-file .env --env-file .env.secrets)

fail=0
ok() { echo "smoke: OK  $*"; }
bad() { echo "smoke: FAIL $*" >&2; fail=1; }

container_ip() {
  local svc="$1"
  local id
  id="$("${COMPOSE[@]}" ps -q "${svc}" 2>/dev/null | head -1)"
  [[ -n "${id}" ]] || return 1
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${id}"
}

echo "smoke: waiting for healthy authelia + nexspence..."
for i in $(seq 1 90); do
  au="$("${COMPOSE[@]}" ps authelia --format '{{.Status}}' 2>/dev/null | tail -1 || true)"
  nx="$("${COMPOSE[@]}" ps nexspence --format '{{.Status}}' 2>/dev/null | tail -1 || true)"
  if [[ "${au}" == *healthy* && "${nx}" == *healthy* ]]; then
    break
  fi
  sleep 5
done

echo "smoke: waiting for mattermost API..."
for i in $(seq 1 60); do
  MM_IP="$(container_ip mattermost || true)"
  if [[ -n "${MM_IP}" ]]; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
      "http://${MM_IP}:8065/api/v4/system/ping" 2>/dev/null || echo 000)"
    if [[ "${code}" == "200" ]]; then
      break
    fi
  fi
  sleep 5
done

# Wait until bootstraps have applied (API truths beat log lines).
echo "smoke: waiting for authelia OIDC + nexspence catalog..."
for i in $(seq 1 90); do
  ready=1
  AU_IP="$(container_ip authelia || true)"
  NX_IP="$(container_ip nexspence || true)"
  if [[ -z "${AU_IP}" || -z "${NX_IP}" ]]; then
    ready=0
  else
    # Authelia 4.39+ OIDC discovery needs X-Forwarded-Proto=https (portal is TLS-only).
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
      -H "X-Forwarded-Proto: https" \
      -H "X-Forwarded-Host: auth.localhost" \
      "http://${AU_IP}:9091/.well-known/openid-configuration" 2>/dev/null || echo 000)"
    if [[ "${code}" != "200" ]]; then
      ready=0
    fi
    repos="$(curl -sS --max-time 8 -u "${ADMIN_USER}:${ADMIN_PASS}" \
      "http://${NX_IP}:8081/service/rest/v1/repositories" 2>/dev/null \
      | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
    if ! [[ "${repos}" =~ ^[0-9]+$ ]] || (( repos < 10 )); then
      ready=0
    fi
  fi
  if [[ "${ready}" -eq 1 ]]; then
    break
  fi
  sleep 5
done

AU_IP="$(container_ip authelia || true)"
if [[ -n "${AU_IP}" ]]; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "X-Forwarded-Proto: https" \
    -H "X-Forwarded-Host: auth.localhost" \
    "http://${AU_IP}:9091/.well-known/openid-configuration" || echo 000)"
  if [[ "${code}" == "200" ]]; then
    ok "authelia OIDC discovery"
  else
    bad "authelia OIDC discovery HTTP ${code}"
  fi
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    "http://${AU_IP}:9091/api/health" || echo 000)"
  if [[ "${code}" == "200" ]]; then
    ok "authelia health"
  else
    bad "authelia health HTTP ${code}"
  fi
else
  bad "authelia container IP"
fi

NX_IP="$(container_ip nexspence || true)"
if [[ -n "${NX_IP}" ]]; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Accept: application/json" \
    "http://${NX_IP}:8081/service/rest/v1/security/users" || echo 000)"
  if [[ "${code}" == "200" ]]; then
    ok "nexspence admin auth"
  else
    bad "nexspence admin auth HTTP ${code}"
  fi

  anon="$(curl -sS --max-time 10 -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "http://${NX_IP}:8081/service/rest/v1/security/anonymous" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("enabled"))' 2>/dev/null || echo conf)"
  if [[ "${anon}" == "True" || "${anon}" == "true" ]]; then
    ok "nexspence anonymous enabled"
  else
    bad "nexspence anonymous enabled=${anon}"
  fi

  repos="$(curl -sS --max-time 15 -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "http://${NX_IP}:8081/service/rest/v1/repositories" \
    | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
  if [[ "${repos}" -ge 10 ]]; then
    ok "nexspence repos count=${repos}"
  else
    bad "nexspence repos count=${repos} (expected >= 10 from catalog)"
  fi
else
  bad "nexspence container IP"
fi

code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Host: auth.localhost" \
  "https://127.0.0.1/.well-known/openid-configuration" || echo 000)"
if [[ "${code}" == "200" ]]; then
  ok "edge auth.localhost discovery"
else
  bad "edge auth.localhost discovery HTTP ${code}"
fi

# UI is public to the edge; SSO is Nexspence native OIDC (Sign in with Authelia).
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Host: mirror.localhost" "https://127.0.0.1/" || echo 000)"
if [[ "${code}" == "200" || "${code}" == "302" || "${code}" == "301" ]]; then
  ok "edge mirror.localhost UI HTTP ${code}"
else
  bad "edge mirror.localhost UI HTTP ${code}"
fi

# Package path must not require browser SSO.
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
  -H "Host: mirror.localhost" \
  "https://127.0.0.1/service/rest/v1/status" || echo 000)"
if [[ "${code}" == "200" ]]; then
  ok "edge mirror status"
else
  bad "edge mirror status HTTP ${code}"
fi

MM_IP="$(container_ip mattermost || true)"
if [[ -n "${MM_IP}" ]]; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    "http://${MM_IP}:8065/api/v4/system/ping" || echo 000)"
  if [[ "${code}" == "200" ]]; then
    ok "mattermost ping"
  else
    bad "mattermost ping HTTP ${code}"
  fi
else
  bad "mattermost container IP"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "smoke: FAILED" >&2
  exit 1
fi
echo "smoke: all checks passed"
