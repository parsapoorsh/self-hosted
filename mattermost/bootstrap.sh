#!/usr/bin/env bash
# Idempotent Mattermost post-start setup (host-side; image has no shell):
#   - mark first-admin onboarding complete (skip org / tools wizard)
#   - set OrganizationName + ensure public team from ORG_NAME (.env)
#   - remove default Off-Topic channel (only Town Square)
#   - add existing non-bot users to that team
#
# Called from compose.sh after `up -d`. Safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

log() {
  echo "mattermost-bootstrap: $*" >&2
}

if [[ ! -f .env || ! -f .env.secrets ]]; then
  log "missing .env or .env.secrets"
  exit 1
fi

# shellcheck disable=SC1091
set -a
source "${ROOT}/.env"
set +a

ORG_NAME="${ORG_NAME:-}"
if [[ -z "${ORG_NAME}" ]]; then
  log "ORG_NAME required in .env"
  exit 1
fi
COMPOSE=(docker compose --env-file .env --env-file .env.secrets)

mmctl() {
  "${COMPOSE[@]}" exec -T mattermost \
    /mattermost/bin/mmctl --local "$@"
}

psql_mm() {
  "${COMPOSE[@]}" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U postgres -d mattermost "$@"
}

wait_mattermost() {
  local i id ip code
  log "waiting for mattermost API"
  for i in $(seq 1 60); do
    id="$("${COMPOSE[@]}" ps -q mattermost 2>/dev/null | head -1 || true)"
    if [[ -n "${id}" ]]; then
      ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${id}" 2>/dev/null || true)"
      if [[ -n "${ip}" ]]; then
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
          "http://${ip}:8065/api/v4/system/ping" 2>/dev/null || echo 000)"
        if [[ "${code}" == "200" ]]; then
          log "API up"
          return 0
        fi
      fi
    fi
    sleep 2
  done
  log "gave up waiting for mattermost"
  return 1
}

# Systems rows are not config.json; set via SQL so fresh volumes skip the wizard.
ensure_systems() {
  log "ensuring OrganizationName=${ORG_NAME} and FirstAdminSetupComplete"
  psql_mm -c "
    INSERT INTO systems (name, value) VALUES ('OrganizationName', '${ORG_NAME}')
    ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value;
    INSERT INTO systems (name, value) VALUES ('FirstAdminSetupComplete', 'true')
    ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value;
  " >/dev/null
}

ensure_team() {
  local teams
  teams="$(mmctl team list 2>/dev/null || true)"
  if ! grep -qx "${ORG_NAME}" <<<"${teams}"; then
    log "creating team ${ORG_NAME}"
    mmctl team create \
      --name "${ORG_NAME}" \
      --display-name "${ORG_NAME}" \
      >/dev/null
  else
    log "team ${ORG_NAME} already exists"
  fi

  # Public + open invite so SSO users can join without a link.
  mmctl team modify "${ORG_NAME}" --public >/dev/null 2>&1 || true
  psql_mm -c "
    UPDATE teams
    SET allowopeninvite = true,
        type = 'O',
        displayname = '${ORG_NAME}'
    WHERE name = '${ORG_NAME}' AND deleteat = 0;
  " >/dev/null
}

# ExperimentalDefaultChannels=town-square skips Off-Topic on new teams; clean
# up any that already exist (team create still used the old defaults once).
remove_off_topic() {
  local channels
  channels="$(mmctl channel list "${ORG_NAME}" 2>/dev/null || true)"
  if ! grep -qx 'off-topic' <<<"${channels}"; then
    return 0
  fi
  log "deleting ${ORG_NAME}:off-topic"
  mmctl channel delete --confirm "${ORG_NAME}:off-topic" >/dev/null 2>&1 || true
}

# Bots ship with the server; only add human (and SSO) accounts.
add_users_to_team() {
  local user
  while IFS= read -r user; do
    [[ -n "${user}" ]] || continue
    log "ensuring ${user} on team ${ORG_NAME}"
    mmctl team users add "${ORG_NAME}" "${user}" >/dev/null 2>&1 || true
  done < <(
    # mmctl --json still prints a count line before the array.
    mmctl --json user list 2>/dev/null \
      | python3 -c '
import json, sys
raw = sys.stdin.read()
start = raw.find("[")
if start < 0:
    sys.exit(0)
for u in json.loads(raw[start:]):
    if u.get("is_bot") or u.get("delete_at"):
        continue
    print(u.get("username") or "")
'
  )
}

# Calls "test mode" (DefaultEnabled=false) limits starts to system admins.
# mmctl config set cannot write nested plugin keys; use config patch instead.
ensure_calls_enabled() {
  local patch
  log "enabling Calls for all users (DefaultEnabled=true)"
  patch="$(mktemp)"
  printf '%s\n' \
    '{"PluginSettings":{"Plugins":{"com.mattermost.calls":{"defaultenabled":true}}}}' \
    >"${patch}"
  chmod 644 "${patch}"
  # Write into config volume as mattermost uid so mmctl can read the file.
  docker run --rm \
    -v self-hosted_mattermost_config:/c \
    -v "${patch}:/patch.json:ro" \
    alpine \
    sh -c 'cp /patch.json /c/mm-calls-enabled.json && chown 2000:2000 /c/mm-calls-enabled.json'
  rm -f "${patch}"
  if ! mmctl config patch /mattermost/config/mm-calls-enabled.json >/dev/null; then
    log "warn: could not patch Calls DefaultEnabled"
    return 0
  fi
}

wait_mattermost
ensure_systems
ensure_team
remove_off_topic
add_users_to_team
ensure_calls_enabled
log "done"
