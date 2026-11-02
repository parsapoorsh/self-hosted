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

echo "smoke: waiting for healthy keycloak + nexus..."
for i in $(seq 1 90); do
  kc="$("${COMPOSE[@]}" ps keycloak --format '{{.Status}}' 2>/dev/null | tail -1 || true)"
  nx="$("${COMPOSE[@]}" ps nexus --format '{{.Status}}' 2>/dev/null | tail -1 || true)"
  if [[ "${kc}" == *healthy* && "${nx}" == *healthy* ]]; then
    break
  fi
  sleep 5
done

# Wait until bootstraps have applied (API truths beat log lines).
echo "smoke: waiting for keycloak realm + nexus catalog..."
for i in $(seq 1 90); do
  ready=1
  KC_IP="$(container_ip keycloak || true)"
  NX_IP="$(container_ip nexus || true)"
  if [[ -z "${KC_IP}" || -z "${NX_IP}" ]]; then
    ready=0
  else
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
      "http://${KC_IP}:8080/realms/home/.well-known/openid-configuration" 2>/dev/null || echo 000)"
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

KC_IP="$(container_ip keycloak || true)"
if [[ -n "${KC_IP}" ]]; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    "http://${KC_IP}:8080/realms/home/.well-known/openid-configuration" || echo 000)"
  if [[ "${code}" == "200" ]]; then
    ok "keycloak realm home discovery"
  else
    bad "keycloak realm home discovery HTTP ${code}"
  fi
else
  bad "keycloak container IP"
fi

NX_IP="$(container_ip nexus || true)"
if [[ -n "${NX_IP}" ]]; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Accept: application/json" \
    "http://${NX_IP}:8081/service/rest/v1/security/users" || echo 000)"
  if [[ "${code}" == "200" ]]; then
    ok "nexus admin auth"
  else
    bad "nexus admin auth HTTP ${code}"
  fi

  eula="$(curl -sS --max-time 10 -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "http://${NX_IP}:8081/service/rest/v1/system/eula" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("accepted"))' 2>/dev/null || echo conf)"
  if [[ "${eula}" == "True" || "${eula}" == "true" ]]; then
    ok "nexus EULA accepted"
  else
    bad "nexus EULA accepted=${eula}"
  fi

  anon="$(curl -sS --max-time 10 -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "http://${NX_IP}:8081/service/rest/v1/security/anonymous" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("enabled"))' 2>/dev/null || echo conf)"
  if [[ "${anon}" == "True" || "${anon}" == "true" ]]; then
    ok "nexus anonymous enabled"
  else
    bad "nexus anonymous enabled=${anon}"
  fi

  repos="$(curl -sS --max-time 15 -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "http://${NX_IP}:8081/service/rest/v1/repositories" \
    | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
  if [[ "${repos}" -ge 10 ]]; then
    ok "nexus repos count=${repos}"
  else
    bad "nexus repos count=${repos} (expected >= 10 from catalog)"
  fi

  rut="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "X-Remote-User: ${ADMIN_USER}" \
    "http://${NX_IP}:8081/service/rest/v1/security/users" || echo 000)"
  if [[ "${rut}" == "200" ]]; then
    ok "nexus rut auth"
  else
    bad "nexus rut auth HTTP ${rut}"
  fi
else
  bad "nexus container IP"
fi

code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Host: auth.localhost" \
  "https://127.0.0.1/realms/home/.well-known/openid-configuration" || echo 000)"
if [[ "${code}" == "200" ]]; then
  ok "edge auth.localhost discovery"
else
  bad "edge auth.localhost discovery HTTP ${code}"
fi

loc="$(curl -sk -o /dev/null -w '%{redirect_url}' --max-time 10 \
  -H "Host: nexus.localhost" "https://127.0.0.1/" || true)"
if [[ "${loc}" == *"/oauth2/start"* ]]; then
  ok "edge nexus.localhost -> oauth2 start"
else
  bad "edge nexus.localhost redirect='${loc}'"
fi

loc="$(curl -sk -o /dev/null -w '%{redirect_url}' --max-time 10 \
  -H "Host: nexus.localhost" \
  "https://127.0.0.1/oauth2/start?rd=https://nexus.localhost/" || true)"
if [[ "${loc}" == *"auth.localhost/realms/home"* ]]; then
  ok "edge nexus oauth -> keycloak"
  pathq="${loc#https://auth.localhost}"
  code="$(curl -sk -o /tmp/smoke-kc.html -w '%{http_code}' --max-time 10 \
    -H "Host: auth.localhost" "https://127.0.0.1${pathq}" || echo 000)"
  if [[ "${code}" == "200" ]] && grep -q 'Sign in' /tmp/smoke-kc.html 2>/dev/null; then
    ok "keycloak login page"
  else
    bad "keycloak login page HTTP ${code}"
  fi
else
  bad "edge nexus oauth redirect='${loc}'"
fi

loc="$(curl -sk -o /dev/null -w '%{redirect_url}' --max-time 10 \
  -H "Host: cloud.localhost" "https://127.0.0.1/" || true)"
if [[ "${loc}" == *"cloud.${DOMAIN}"* ]]; then
  bad "cloud.localhost redirects to ${loc} (overwritehost still set?)"
else
  ok "cloud.localhost stays local (redir=${loc:-none})"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "smoke: FAILED — fix issues above before using the stack" >&2
  exit 1
fi
echo "smoke: all checks passed"
