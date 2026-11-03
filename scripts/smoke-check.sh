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
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:?}"

# compose.yml requires CALLS_ICE_HOST_OVERRIDE for interpolation (same as compose.sh).
if [[ -z "${CALLS_ICE_HOST_OVERRIDE:-}" ]]; then
  CALLS_ICE_HOST_OVERRIDE="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
  export CALLS_ICE_HOST_OVERRIDE
fi
COMPOSE=(docker compose --env-file .env --env-file .env.secrets)

# Edge base (published host ports). Empty path; Host header selects the vhost.
EDGE_HTTPS="https://127.0.0.1:${HTTPS_PORT}"
EDGE_HTTP="http://127.0.0.1:${HTTP_PORT}"

# Browsers send Host with the non-default port. Empty when HTTPS_PORT is 443.
HTTPS_HOST_SUFFIX=""
if [[ "${HTTPS_PORT}" != "443" ]]; then
  HTTPS_HOST_SUFFIX=":${HTTPS_PORT}"
fi

# Authentik per-app discovery (Nextcloud issuer).
NC_DISCOVERY="/application/o/nextcloud/.well-known/openid-configuration"

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

echo "smoke: waiting for healthy authentik + nexspence..."
for i in $(seq 1 90); do
  au="$("${COMPOSE[@]}" ps authentik --format '{{.Status}}' 2>/dev/null | tail -1 || true)"
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
echo "smoke: waiting for authentik OIDC + nexspence catalog..."
for i in $(seq 1 90); do
  ready=1
  AU_IP="$(container_ip authentik || true)"
  NX_IP="$(container_ip nexspence || true)"
  if [[ -z "${AU_IP}" || -z "${NX_IP}" ]]; then
    ready=0
  else
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
      -H "X-Forwarded-Proto: https" \
      -H "X-Forwarded-Host: auth.localhost${HTTPS_HOST_SUFFIX}" \
      "http://${AU_IP}:9000${NC_DISCOVERY}" 2>/dev/null || echo 000)"
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

AU_IP="$(container_ip authentik || true)"
if [[ -n "${AU_IP}" ]]; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "X-Forwarded-Proto: https" \
    -H "X-Forwarded-Host: auth.localhost${HTTPS_HOST_SUFFIX}" \
    "http://${AU_IP}:9000${NC_DISCOVERY}" || echo 000)"
  if [[ "${code}" == "200" ]]; then
    ok "authentik Nextcloud OIDC discovery"
  else
    bad "authentik Nextcloud OIDC discovery HTTP ${code}"
  fi
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    "http://${AU_IP}:9000/-/health/ready/" || echo 000)"
  if [[ "${code}" == "200" ]]; then
    ok "authentik health"
  else
    bad "authentik health HTTP ${code}"
  fi
else
  bad "authentik container IP"
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

  # Anonymous is per-repository (allow_anonymous); no global /security/anonymous API.
  anon_repos="$(curl -sS --max-time 15 -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Accept: application/json" \
    "http://${NX_IP}:8081/service/rest/v1/repositories" \
    | python3 -c 'import sys,json; r=json.load(sys.stdin); print(sum(1 for x in r if x.get("allowAnonymous") or x.get("allow_anonymous")))' 2>/dev/null || echo 0)"
  if [[ "${anon_repos}" =~ ^[0-9]+$ ]] && (( anon_repos >= 1 )); then
    ok "nexspence repos with anonymous pull count=${anon_repos}"
  else
    bad "nexspence repos with anonymous pull count=${anon_repos}"
  fi

  repos="$(curl -sS --max-time 15 -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Accept: application/json" \
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
  -H "Host: auth.localhost${HTTPS_HOST_SUFFIX}" \
  "${EDGE_HTTPS}${NC_DISCOVERY}" || echo 000)"
if [[ "${code}" == "200" ]]; then
  ok "edge auth.localhost nextcloud discovery (:${HTTPS_PORT})"
else
  bad "edge auth.localhost nextcloud discovery HTTP ${code} (:${HTTPS_PORT})"
fi

# UI is public to the edge; SSO is Nexspence native OIDC.
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Host: mirror.localhost${HTTPS_HOST_SUFFIX}" "${EDGE_HTTPS}/" || echo 000)"
if [[ "${code}" == "200" || "${code}" == "302" || "${code}" == "301" ]]; then
  ok "edge mirror.localhost UI HTTP ${code}"
else
  bad "edge mirror.localhost UI HTTP ${code}"
fi

# Public auth config (no browser SSO). Status is auth-gated.
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
  -H "Host: mirror.localhost${HTTPS_HOST_SUFFIX}" \
  "${EDGE_HTTPS}/api/v1/auth/config" || echo 000)"
if [[ "${code}" == "200" ]]; then
  ok "edge mirror auth/config"
else
  bad "edge mirror auth/config HTTP ${code}"
fi

# HTTP -> HTTPS must be temporary (302) and keep the configured HTTPS port.
redir="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 \
  -H "Host: chat.${DOMAIN}" \
  "${EDGE_HTTP}/" || echo "000 ")"
redir_code="${redir%% *}"
redir_url="${redir#* }"
expect_loc="https://chat.${DOMAIN}${HTTPS_HOST_SUFFIX}/"
if [[ "${redir_code}" == "302" && "${redir_url}" == "${expect_loc}" ]]; then
  ok "HTTP->HTTPS chat redirect 302 -> ${expect_loc}"
else
  bad "HTTP->HTTPS chat redirect got '${redir}' want '302 ${expect_loc}'"
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

# Nextcloud is OIDC-only: /login 302s to user_oidc (then Authentik).
# Use Sec-Fetch headers so user_oidc treats this as a top-level navigation.
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
  -H "Host: cloud.localhost${HTTPS_HOST_SUFFIX}" \
  -H "Accept: text/html" \
  -H "Sec-Fetch-Mode: navigate" \
  -H "Sec-Fetch-Dest: document" \
  -H "Sec-Fetch-User: ?1" \
  -H "Sec-Fetch-Site: none" \
  "${EDGE_HTTPS}/login" || echo 000)"
loc="$(curl -sk -o /dev/null -w '%{redirect_url}' --max-time 15 \
  -H "Host: cloud.localhost${HTTPS_HOST_SUFFIX}" \
  -H "Accept: text/html" \
  -H "Sec-Fetch-Mode: navigate" \
  -H "Sec-Fetch-Dest: document" \
  -H "Sec-Fetch-User: ?1" \
  -H "Sec-Fetch-Site: none" \
  "${EDGE_HTTPS}/login" || true)"
if [[ "${code}" == "302" && "${loc}" == *"/apps/user_oidc/login/"* ]]; then
  ok "nextcloud OIDC-only /login -> ${loc}"
elif [[ "${code}" == "302" ]]; then
  ok "nextcloud /login redirect HTTP 302 -> ${loc}"
else
  bad "nextcloud /login HTTP ${code} loc=${loc} (want 302 to user_oidc)"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "smoke: FAILED" >&2
  exit 1
fi
echo "smoke: all checks passed"
