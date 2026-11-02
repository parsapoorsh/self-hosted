#!/usr/bin/env bash
# Idempotent Nexus first-boot / every-start setup:
#   admin password, CE EULA, anonymous access, Rut Auth (Keycloak SSO),
#   drop sample repos, apply catalog blob stores + repos.
set -euo pipefail

NEXUS_URL="${NEXUS_URL:-http://127.0.0.1:8081}"
ADMIN_USER="${NEXUS_ADMIN_USER:-admin}"
ADMIN_PASS="${NEXUS_ADMIN_PASSWORD:?NEXUS_ADMIN_PASSWORD required}"
DATA_DIR="${NEXUS_DATA_DIR:-/nexus-data}"
HEADER_NAME="${NEXUS_RUT_HEADER:-X-Remote-User}"
SCRIPT_NAME="self-hosted-rutauth"
CATALOG="${NEXUS_CATALOG:-/init/catalog.json}"
ENSURE_REPOS="${NEXUS_ENSURE_REPOS:-/init/ensure_repos.py}"

DEFAULT_REPOS="maven-central maven-public maven-releases maven-snapshots nuget-group nuget-hosted nuget.org-proxy"

CURL_OUT="$(mktemp)"
trap 'rm -f "${CURL_OUT}"' EXIT

log() {
  # stderr stays line-buffered under Docker; stdout from background jobs can stall.
  echo "nexus-bootstrap: $*" >&2
}

# HTTP call with basic auth; retries Nexus early-boot 429s.
# Prints body on 2xx. Args after user/pass are curl args (URL last).
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
    "${NEXUS_URL}/service/rest/v1/security/users" 2>/dev/null
}

wait_nexus() {
  local i
  log "waiting for ${NEXUS_URL}"
  for i in $(seq 1 90); do
    if curl -sS -f -o /dev/null \
      --connect-timeout 3 --max-time 10 \
      "${NEXUS_URL}/service/rest/v1/status" 2>/dev/null
    then
      log "status up (try ${i})"
      if curl -sS -f -o /dev/null \
        --connect-timeout 3 --max-time 10 \
        "${NEXUS_URL}/service/rest/v1/status/writable" 2>/dev/null
      then
        log "writable"
      else
        log "writable not ready yet (continuing)"
      fi
      return 0
    fi
    sleep 5
  done
  log "gave up waiting for nexus"
  return 1
}

resolve_admin_pass() {
  local generated=""

  if auth_ok "${ADMIN_USER}" "${ADMIN_PASS}"; then
    printf '%s' "${ADMIN_PASS}"
    return 0
  fi

  if [[ -f "${DATA_DIR}/admin.password" ]]; then
    generated="$(tr -d '[:space:]' <"${DATA_DIR}/admin.password")"
  fi

  if [[ -n "${generated}" ]] && auth_ok "${ADMIN_USER}" "${generated}"; then
    log "setting admin password from generated file"
    curl_auth "${ADMIN_USER}" "${generated}" \
      -X PUT \
      -H "Content-Type: text/plain" \
      --data-binary "${ADMIN_PASS}" \
      "${NEXUS_URL}/service/rest/v1/security/users/${ADMIN_USER}/change-password" \
      >/dev/null
    auth_ok "${ADMIN_USER}" "${ADMIN_PASS}" || {
      log "password change did not stick"
      return 1
    }
    printf '%s' "${ADMIN_PASS}"
    return 0
  fi

  log "no working admin credentials yet"
  return 1
}

# Community Edition blocks many APIs until EULA is accepted.
accept_eula() {
  local pass="$1"
  local body accepted

  body="$(
    curl_auth "${ADMIN_USER}" "${pass}" \
      -H "Accept: application/json" \
      "${NEXUS_URL}/service/rest/v1/system/eula"
  )" || return 1

  accepted="$(
    printf '%s' "${body}" | python3 -c \
      'import json,sys; print(json.load(sys.stdin).get("accepted", False))' \
      2>/dev/null || echo false
  )"
  if [[ "${accepted}" == "True" || "${accepted}" == "true" ]]; then
    log "EULA already accepted"
    return 0
  fi

  log "accepting Community EULA"
  body="$(
    printf '%s' "${body}" | python3 -c \
      'import json,sys; d=json.load(sys.stdin); d["accepted"]=True; print(json.dumps(d))'
  )"
  curl_auth "${ADMIN_USER}" "${pass}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "${body}" \
    "${NEXUS_URL}/service/rest/v1/system/eula" \
    >/dev/null
  log "EULA accepted"
}

enable_anonymous() {
  local pass="$1"
  local body

  body="$(
    curl_auth "${ADMIN_USER}" "${pass}" \
      -H "Accept: application/json" \
      "${NEXUS_URL}/service/rest/v1/security/anonymous"
  )" || return 1

  body="$(
    printf '%s' "${body}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["enabled"] = True
d["userId"] = d.get("userId") or "anonymous"
d["realmName"] = d.get("realmName") or "NexusAuthorizingRealm"
print(json.dumps(d))
'
  )"
  curl_auth "${ADMIN_USER}" "${pass}" \
    -X PUT \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "${body}" \
    "${NEXUS_URL}/service/rest/v1/security/anonymous" \
    >/dev/null
  log "anonymous access enabled"
}

json_script_body() {
  local name="$1"
  local content="$2"
  SCRIPT_NAME="${name}" GROOVY="${content}" python3 - <<'PY'
import json, os
print(json.dumps({
    "name": os.environ["SCRIPT_NAME"],
    "type": "groovy",
    "content": os.environ["GROOVY"],
}))
PY
}

ensure_rut_capability() {
  local pass="$1"
  local groovy body result

  groovy="$(cat <<EOF
import org.sonatype.nexus.capability.CapabilityRegistry
import org.sonatype.nexus.capability.CapabilityType

def registry = container.lookup(CapabilityRegistry.class.name)
def type = CapabilityType.capabilityType("rutauth")
def props = ["httpHeader": "${HEADER_NAME}"] as Map<String, String>
def existing = registry.all.find { it.context().type() == type }
if (existing) {
  registry.update(existing.context().id(), true, "Keycloak SSO via reverse proxy", props)
  return "updated:" + existing.context().id()
}
def ref = registry.add(type, true, "Keycloak SSO via reverse proxy", props)
return "created:" + ref.context().id()
EOF
)"

  body="$(json_script_body "${SCRIPT_NAME}" "${groovy}")"

  curl -sS -o /dev/null -w "" \
    -u "${ADMIN_USER}:${pass}" \
    -X DELETE \
    "${NEXUS_URL}/service/rest/v1/script/${SCRIPT_NAME}" 2>/dev/null || true

  log "installing rutauth groovy script"
  curl_auth "${ADMIN_USER}" "${pass}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "${body}" \
    "${NEXUS_URL}/service/rest/v1/script" \
    >/dev/null

  result="$(
    curl_auth "${ADMIN_USER}" "${pass}" \
      -X POST \
      -H "Content-Type: text/plain" \
      -H "Accept: application/json" \
      "${NEXUS_URL}/service/rest/v1/script/${SCRIPT_NAME}/run"
  )"
  log "rutauth: $(printf '%s' "${result}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("result", d))')"

  curl -sS -o /dev/null -w "" \
    -u "${ADMIN_USER}:${pass}" \
    -X DELETE \
    "${NEXUS_URL}/service/rest/v1/script/${SCRIPT_NAME}" 2>/dev/null || true
}

ensure_realms() {
  local pass="$1"
  log "setting active realms (rut + local)"
  curl_auth "${ADMIN_USER}" "${pass}" \
    -X PUT \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d '["rutauth-realm","NexusAuthenticatingRealm"]' \
    "${NEXUS_URL}/service/rest/v1/security/realms/active" \
    >/dev/null
}

delete_default_repos() {
  local pass="$1"
  local repo code attempt
  for repo in ${DEFAULT_REPOS}; do
    for attempt in $(seq 1 12); do
      code="$(
        curl -sS -o /dev/null -w "%{http_code}" \
          --connect-timeout 5 --max-time 30 \
          -u "${ADMIN_USER}:${pass}" \
          -X DELETE \
          "${NEXUS_URL}/service/rest/v1/repositories/${repo}" || true
      )"
      case "${code}" in
        204) log "deleted default repo ${repo}"; break ;;
        404) break ;;
        429) log "delete ${repo}: 429 (try ${attempt}/12)"; sleep 3 ;;
        *) log "delete ${repo}: HTTP ${code}"; break ;;
      esac
    done
  done
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
  NEXUS_URL="${NEXUS_URL}" \
    NEXUS_ADMIN_USER="${ADMIN_USER}" \
    NEXUS_ADMIN_PASSWORD="${pass}" \
    NEXUS_CATALOG="${CATALOG}" \
    python3 "${ENSURE_REPOS}"
}

verify_rut() {
  local code
  code="$(
    curl -sS -o /dev/null -w "%{http_code}" \
      --connect-timeout 5 --max-time 15 \
      -H "${HEADER_NAME}: ${ADMIN_USER}" \
      "${NEXUS_URL}/service/rest/v1/security/users" || true
  )"
  if [[ "${code}" != "200" ]]; then
    log "rut check failed HTTP ${code}"
    return 1
  fi
  log "rut ok (${HEADER_NAME}=${ADMIN_USER})"
}

configure() {
  set -euo pipefail
  local pass
  wait_nexus
  pass="$(resolve_admin_pass)"
  accept_eula "${pass}"
  enable_anonymous "${pass}"
  ensure_rut_capability "${pass}"
  ensure_realms "${pass}"
  delete_default_repos "${pass}"
  ensure_catalog "${pass}"
  verify_rut
  log "done (admin=${ADMIN_USER} rut=${HEADER_NAME})"
}

while true; do
  set +e
  configure
  status=$?
  set -e
  if [[ "${status}" -eq 0 ]]; then
    exit 0
  fi
  log "configure failed (exit ${status}); retry in 20s"
  sleep 20
done
