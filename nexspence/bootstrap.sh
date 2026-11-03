#!/bin/bash
# Idempotent Nexspence every-start setup:
#   wait for API, enable anonymous pulls, apply catalog blob stores + repos.
set -euo pipefail

NEXSPENCE_URL="${NEXSPENCE_URL:-http://127.0.0.1:8081}"
ADMIN_USER="${NEXSPENCE_ADMIN_USER:-admin}"
ADMIN_PASS="${NEXSPENCE_ADMIN_PASSWORD:?NEXSPENCE_ADMIN_PASSWORD required}"
CATALOG="${NEXSPENCE_CATALOG:-/init/catalog.json}"
ENSURE_REPOS="${NEXSPENCE_ENSURE_REPOS:-/init/ensure_repos.py}"

CURL_OUT="$(mktemp)"
trap 'rm -f "${CURL_OUT}"' EXIT

log() {
  echo "nexspence-bootstrap: $*" >&2
}

curl_auth() {
  local user="$1"
  local pass="$2"
  shift 2
  local attempt code
  for attempt in $(seq 1 20); do
    code="$(
      curl -sS -o "${CURL_OUT}" -w "%{http_code}" \
        --connect-timeout 5 \
        --max-time 120 \
        -u "${user}:${pass}" \
        "$@" || true
    )"
    case "${code}" in
      200|201|204)
        cat "${CURL_OUT}"
        return 0
        ;;
      429)
        log "HTTP 429 (try ${attempt}/20); sleeping"
        sleep 3
        ;;
      *)
        log "HTTP ${code} for ${*: -1}"
        if [[ -s "${CURL_OUT}" ]]; then
          head -c 500 "${CURL_OUT}" >&2 || true
          echo >&2
        fi
        return 1
        ;;
    esac
  done
  log "gave up after rate limits on ${*: -1}"
  return 1
}

auth_ok() {
  curl -sS -f -o /dev/null \
    --connect-timeout 5 --max-time 15 \
    -u "$1:$2" \
    -H "Accept: application/json" \
    "${NEXSPENCE_URL}/service/rest/v1/security/users" 2>/dev/null
}

wait_api() {
  local i code
  log "waiting for ${NEXSPENCE_URL}"
  for i in $(seq 1 90); do
    code="$(
      curl -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 3 --max-time 10 \
        "${NEXSPENCE_URL}/api/v1/auth/config" 2>/dev/null || echo 000
    )"
    if [[ "${code}" == "200" ]]; then
      log "api up (try ${i})"
      return 0
    fi
    sleep 2
  done
  log "gave up waiting for nexspence"
  return 1
}

ensure_catalog() {
  local pass="$1"
  [[ -f "${CATALOG}" ]] || {
    log "catalog missing: ${CATALOG}"
    return 1
  }
  [[ -f "${ENSURE_REPOS}" ]] || {
    log "ensure_repos missing: ${ENSURE_REPOS}"
    return 1
  }
  log "applying catalog ${CATALOG}"
  NEXSPENCE_URL="${NEXSPENCE_URL}" \
    NEXSPENCE_ADMIN_USER="${ADMIN_USER}" \
    NEXSPENCE_ADMIN_PASSWORD="${pass}" \
    NEXSPENCE_CATALOG="${CATALOG}" \
    python3 "${ENSURE_REPOS}"
}

configure() {
  set -euo pipefail
  wait_api
  if ! auth_ok "${ADMIN_USER}" "${ADMIN_PASS}"; then
    log "admin auth failed for ${ADMIN_USER}"
    return 1
  fi
  # Anonymous pulls are per-repository (allow_anonymous) via ensure_repos.
  ensure_catalog "${ADMIN_PASS}"
  log "done (admin=${ADMIN_USER})"
}

configure
