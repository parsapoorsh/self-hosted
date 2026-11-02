#!/usr/bin/env bash
# Idempotent Nexus bootstrap: admin password, Rut Auth (Keycloak via proxy),
# drop default repositories, ensure catalog blob stores + hosted/proxies/groups.
# Runs once from docker-entrypoint background job.
#
# Rut Auth capability is created via Groovy (OSS has no Capabilities REST API).
# Requires nexus.scripts.allowCreation=true (set in compose JVM opts).
set -euo pipefail

NEXUS_URL="${NEXUS_URL:-http://127.0.0.1:8081}"
ADMIN_USER="${NEXUS_ADMIN_USER:-admin}"
ADMIN_PASS="${NEXUS_ADMIN_PASSWORD:?NEXUS_ADMIN_PASSWORD required}"
DATA_DIR="${NEXUS_DATA_DIR:-/nexus-data}"
HEADER_NAME="${NEXUS_RUT_HEADER:-X-Remote-User}"
SCRIPT_NAME="self-hosted-rutauth"

# Defaults created when skipDefaultRepositories is off (or older installs).
DEFAULT_REPOS="maven-central maven-public maven-releases maven-snapshots nuget-group nuget-hosted nuget.org-proxy"

log() {
  echo "nexus-bootstrap: $*"
}

curl_auth() {
  local user="$1"
  local pass="$2"
  shift 2
  curl -sS -f -u "${user}:${pass}" "$@"
}

# /status is public; use a privileged endpoint to verify credentials.
auth_ok() {
  local user="$1"
  local pass="$2"
  curl -sS -f -o /dev/null -u "${user}:${pass}" \
    -H "Accept: application/json" \
    "${NEXUS_URL}/service/rest/v1/security/users" 2>/dev/null
}

wait_nexus() {
  local i
  log "waiting for ${NEXUS_URL}"
  for i in $(seq 1 60); do
    if curl -sS -f -o /dev/null "${NEXUS_URL}/service/rest/v1/status" 2>/dev/null; then
      log "nexus is up (try ${i})"
      # Prefer writable before mutating repos (avoids STARTED-state races).
      if curl -sS -f -o /dev/null "${NEXUS_URL}/service/rest/v1/status/writable" 2>/dev/null; then
        log "nexus writable"
      else
        log "nexus status ok; writable not ready yet (continuing)"
      fi
      return 0
    fi
    sleep 5
  done
  log "gave up waiting for nexus"
  return 1
}

# Prefer configured password; on first boot use generated admin.password then set ours.
resolve_admin_pass() {
  local generated=""

  if auth_ok "${ADMIN_USER}" "${ADMIN_PASS}"; then
    echo "${ADMIN_PASS}"
    return 0
  fi

  if [[ -f "${DATA_DIR}/admin.password" ]]; then
    generated="$(tr -d '[:space:]' <"${DATA_DIR}/admin.password")"
  fi

  if [[ -n "${generated}" ]] && auth_ok "${ADMIN_USER}" "${generated}"; then
    log "changing admin password from generated file"
    curl_auth "${ADMIN_USER}" "${generated}" \
      -X PUT \
      -H "Content-Type: text/plain" \
      --data-binary "${ADMIN_PASS}" \
      "${NEXUS_URL}/service/rest/v1/security/users/${ADMIN_USER}/change-password" \
      >/dev/null
    if ! auth_ok "${ADMIN_USER}" "${ADMIN_PASS}"; then
      log "password change did not stick"
      return 1
    fi
    echo "${ADMIN_PASS}"
    return 0
  fi

  log "no working admin credentials yet"
  return 1
}

json_script_body() {
  local name="$1"
  local content="$2"
  HEADER_NAME="${HEADER_NAME}" SCRIPT_NAME="${name}" GROOVY="${content}" python3 - <<'PY'
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

  curl -sS -o /dev/null -w "" -u "${ADMIN_USER}:${pass}" \
    -X DELETE \
    "${NEXUS_URL}/service/rest/v1/script/${SCRIPT_NAME}" 2>/dev/null || true

  log "installing groovy script ${SCRIPT_NAME}"
  curl_auth "${ADMIN_USER}" "${pass}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "${body}" \
    "${NEXUS_URL}/service/rest/v1/script" \
    >/dev/null

  log "running rutauth capability setup"
  result="$(curl_auth "${ADMIN_USER}" "${pass}" \
    -X POST \
    -H "Content-Type: text/plain" \
    -H "Accept: application/json" \
    "${NEXUS_URL}/service/rest/v1/script/${SCRIPT_NAME}/run")"
  log "rutauth script result: $(printf '%s' "${result}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("result", d))')"

  curl -sS -o /dev/null -w "" -u "${ADMIN_USER}:${pass}" \
    -X DELETE \
    "${NEXUS_URL}/service/rest/v1/script/${SCRIPT_NAME}" 2>/dev/null || true
}

ensure_realms() {
  local pass="$1"
  # Rut first so reverse-proxy identity wins for browser SSO; local for API basic auth.
  log "setting active realms"
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
  local repo code
  for repo in ${DEFAULT_REPOS}; do
    code="$(
      curl -sS -o /dev/null -w "%{http_code}" \
        -u "${ADMIN_USER}:${pass}" \
        -X DELETE \
        "${NEXUS_URL}/service/rest/v1/repositories/${repo}" || true
    )"
    case "${code}" in
      204) log "deleted default repo ${repo}" ;;
      404) ;;
      *) log "delete ${repo}: HTTP ${code}" ;;
    esac
  done
}

ensure_catalog_repos() {
  local pass="$1"
  local catalog="${NEXUS_CATALOG:-/init/catalog.json}"
  local script="${NEXUS_ENSURE_REPOS:-/init/ensure_repos.py}"

  if [[ ! -f "${catalog}" ]]; then
    log "catalog missing: ${catalog}"
    return 1
  fi
  if [[ ! -f "${script}" ]]; then
    log "ensure_repos missing: ${script}"
    return 1
  fi

  log "ensuring blob stores + hosted/proxy/group repos from ${catalog}"
  NEXUS_URL="${NEXUS_URL}" \
    NEXUS_ADMIN_USER="${ADMIN_USER}" \
    NEXUS_ADMIN_PASSWORD="${pass}" \
    NEXUS_CATALOG="${catalog}" \
    python3 "${script}"
}

verify_rut() {
  local code
  code="$(
    curl -sS -o /dev/null -w "%{http_code}" \
      -H "${HEADER_NAME}: ${ADMIN_USER}" \
      "${NEXUS_URL}/service/rest/v1/security/users" || true
  )"
  if [[ "${code}" != "200" ]]; then
    log "rut auth check failed (HTTP ${code})"
    return 1
  fi
  log "rut auth ok (${HEADER_NAME}=${ADMIN_USER})"
}

configure() {
  local pass
  wait_nexus
  pass="$(resolve_admin_pass)" || return 1
  ensure_rut_capability "${pass}"
  ensure_realms "${pass}"
  delete_default_repos "${pass}"
  ensure_catalog_repos "${pass}"
  verify_rut
  log "done (admin=${ADMIN_USER} rut=${HEADER_NAME})"
}

# Retry until success, then exit (background job under entrypoint).
while true; do
  if configure; then
    exit 0
  fi
  log "retry in 15s"
  sleep 15
done
