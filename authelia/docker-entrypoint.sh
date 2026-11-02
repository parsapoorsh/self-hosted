#!/bin/sh
# Build runtime Authelia config (users + OIDC clients) then start the server.
# Image is Alpine/busybox — keep this POSIX sh (no bash).
set -eu

DATA="${AUTHELIA_DATA_DIR:-/data}"
RUNTIME="${AUTHELIA_RUNTIME_DIR:-/runtime}"
mkdir -p "${DATA}" "${RUNTIME}"

DOMAIN="${DOMAIN:-example.com}"
SCHEME="${APP_SCHEME:-http}"
# Prefer AUTH_*; fall back to KEYCLOAK_* for existing .env files.
ADMIN_USER="${AUTH_ADMIN:-}"
if [ -z "${ADMIN_USER}" ]; then
  ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
fi
ADMIN_PASS="${AUTH_ADMIN_PASSWORD:-}"
if [ -z "${ADMIN_PASS}" ]; then
  ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-}"
fi
ADMIN_EMAIL="${AUTH_ADMIN_EMAIL:-${ADMIN_USER}@${DOMAIN}}"

NC_CLIENT_ID="${OIDC_CLIENT_ID:-nextcloud}"
NC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-}"
NX_CLIENT_ID="${NEXUS_OIDC_CLIENT_ID:-nexus}"
NX_CLIENT_SECRET="${NEXUS_OIDC_CLIENT_SECRET:-}"

# Names avoid AUTHELIA_* so the process does not treat them as config env overrides.
SESSION_SECRET="${SESSION_SECRET:-}"
STORAGE_KEY="${STORAGE_ENCRYPTION_KEY:-}"
HMAC_SECRET="${OIDC_HMAC_SECRET:-}"

log() { echo "authelia: $*" >&2; }

die() { log "ERROR: $*"; exit 1; }

[ -n "${ADMIN_PASS}" ] || die "KEYCLOAK_ADMIN_PASSWORD (or AUTH_ADMIN_PASSWORD) required"
[ -n "${NC_CLIENT_SECRET}" ] || die "OIDC_CLIENT_SECRET required"
[ -n "${NX_CLIENT_SECRET}" ] || die "NEXUS_OIDC_CLIENT_SECRET required"
[ -n "${SESSION_SECRET}" ] || die "SESSION_SECRET required"
[ -n "${STORAGE_KEY}" ] || die "STORAGE_ENCRYPTION_KEY required"
[ -n "${HMAC_SECRET}" ] || die "OIDC_HMAC_SECRET required"

# Authelia session cookies require https:// and a cookie domain with a dot.
# Portal is always on TLS (nginx :443); APP_SCHEME still drives app redirect URIs.
PORTAL_SCHEME=https

# Username becomes a YAML key — keep it simple.
case "${ADMIN_USER}" in
  *[!a-zA-Z0-9_-]* | "")
    die "admin username must match [a-zA-Z0-9_-]+ (got '${ADMIN_USER}')"
    ;;
esac

yaml_sq() {
  # Single-quoted YAML scalar; double any embedded single quotes.
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

hash_password() {
  authelia crypto hash generate argon2 --password "$1" \
    | sed -n 's/^Digest: //p'
}

hash_client_secret() {
  authelia crypto hash generate pbkdf2 --variant sha512 --password "$1" \
    | sed -n 's/^Digest: //p'
}

ensure_jwks() {
  if [ -f "${DATA}/oidc_jwks.pem" ]; then
    return 0
  fi
  log "generating OIDC RSA signing key"
  authelia crypto pair rsa generate \
    --directory "${DATA}" \
    --file.private-key oidc_jwks.pem \
    --file.public-key oidc_jwks.pub.pem
  chmod 600 "${DATA}/oidc_jwks.pem"
}

indent_pem() {
  sed 's/^/          /' "$1"
}

# Persistent users file (volume). Managed by scripts/authelia-users.py after first boot.
USERS_DB="${DATA}/users_database.yml"

write_users_db() {
  # Keep existing accounts across restarts. Only seed admin on first boot.
  if [ -f "${USERS_DB}" ]; then
    log "using existing users database ${USERS_DB}"
    return 0
  fi
  digest="$(hash_password "${ADMIN_PASS}")"
  [ -n "${digest}" ] || die "failed to hash admin password"
  log "seeding users database with admin '${ADMIN_USER}'"
  cat >"${USERS_DB}" <<EOF
users:
  ${ADMIN_USER}:
    disabled: false
    displayname: "Admin"
    password: $(yaml_sq "${digest}")
    email: $(yaml_sq "${ADMIN_EMAIL}")
    groups:
      - admins
EOF
  chmod 600 "${USERS_DB}"
}

write_config() {
  nc_hash="$(hash_client_secret "${NC_CLIENT_SECRET}")"
  nx_hash="$(hash_client_secret "${NX_CLIENT_SECRET}")"
  [ -n "${nc_hash}" ] || die "failed to hash nextcloud client secret"
  [ -n "${nx_hash}" ] || die "failed to hash nexus client secret"

  # Unique redirect URIs for both APP_SCHEME and the opposite scheme + localhost.
  nc_redirects=$(
    {
      printf '%s\n' \
        "https://cloud.${DOMAIN}/apps/user_oidc/code" \
        "http://cloud.${DOMAIN}/apps/user_oidc/code" \
        "https://cloud.localhost/apps/user_oidc/code" \
        "https://cloud.${DOMAIN}/index.php/apps/user_oidc/code" \
        "http://cloud.${DOMAIN}/index.php/apps/user_oidc/code" \
        "https://cloud.localhost/index.php/apps/user_oidc/code"
    } | sort -u | sed "s/^/          - '/;s/$/'/"
  )
  nx_redirects=$(
    {
      printf '%s\n' \
        "https://nexus.${DOMAIN}/oauth2/callback" \
        "http://nexus.${DOMAIN}/oauth2/callback" \
        "https://nexus.localhost/oauth2/callback"
    } | sort -u | sed "s/^/          - '/;s/$/'/"
  )

  cat >"${RUNTIME}/configuration.yml" <<EOF
---
theme: auto
log:
  level: info
  format: text

server:
  address: 'tcp://0.0.0.0:9091/'

telemetry:
  metrics:
    enabled: false

totp:
  disable: true

webauthn:
  disable: true

authentication_backend:
  password_reset:
    disable: true
  refresh_interval: '5m'
  file:
    path: ${USERS_DB}

access_control:
  default_policy: deny
  rules:
    - domain: 'auth.${DOMAIN}'
      policy: bypass
    - domain: 'auth.localhost'
      policy: bypass

session:
  secret: $(yaml_sq "${SESSION_SECRET}")
  cookies:
    # Cookie domain is the IdP host (OIDC only; not forward-auth on other apps).
    - name: authelia_session
      domain: 'auth.${DOMAIN}'
      authelia_url: '${PORTAL_SCHEME}://auth.${DOMAIN}'
      default_redirection_url: '${PORTAL_SCHEME}://auth.${DOMAIN}/'
      same_site: lax
    - name: authelia_session
      domain: 'auth.localhost'
      authelia_url: 'https://auth.localhost'
      default_redirection_url: 'https://auth.localhost/'
      same_site: lax

regulation:
  max_retries: 8
  find_time: '2m'
  ban_time: '5m'

storage:
  encryption_key: $(yaml_sq "${STORAGE_KEY}")
  local:
    path: ${DATA}/db.sqlite3

notifier:
  disable_startup_check: true
  filesystem:
    filename: ${DATA}/notification.txt

identity_providers:
  oidc:
    hmac_secret: $(yaml_sq "${HMAC_SECRET}")
    jwks:
      - key_id: 'authelia'
        algorithm: 'RS256'
        use: 'sig'
        key: |
$(indent_pem "${DATA}/oidc_jwks.pem")
    cors:
      endpoints:
        - authorization
        - token
        - revocation
        - introspection
        - userinfo
      allowed_origins_from_client_redirect_uris: true
    clients:
      - client_id: '$(printf '%s' "${NC_CLIENT_ID}" | sed "s/'/''/g")'
        client_name: 'Nextcloud'
        client_secret: $(yaml_sq "${nc_hash}")
        public: false
        authorization_policy: one_factor
        consent_mode: implicit
        pre_configured_consent_duration: '1y'
        require_pkce: false
        pkce_challenge_method: 'S256'
        redirect_uris:
${nc_redirects}
        scopes:
          - openid
          - profile
          - email
          - groups
        response_types:
          - code
        grant_types:
          - authorization_code
        token_endpoint_auth_method: client_secret_basic
        userinfo_signed_response_alg: none
      - client_id: '$(printf '%s' "${NX_CLIENT_ID}" | sed "s/'/''/g")'
        client_name: 'Nexus'
        client_secret: $(yaml_sq "${nx_hash}")
        public: false
        authorization_policy: one_factor
        consent_mode: implicit
        pre_configured_consent_duration: '1y'
        require_pkce: true
        pkce_challenge_method: 'S256'
        redirect_uris:
${nx_redirects}
        scopes:
          - openid
          - profile
          - email
          - groups
        response_types:
          - code
        grant_types:
          - authorization_code
        token_endpoint_auth_method: client_secret_basic
        userinfo_signed_response_alg: none
EOF
}

log "building config for domain=${DOMAIN} scheme=${SCHEME} admin=${ADMIN_USER}"
ensure_jwks
write_users_db
write_config

log "validating configuration"
authelia validate-config --config "${RUNTIME}/configuration.yml"

log "starting"
exec authelia --config "${RUNTIME}/configuration.yml"
