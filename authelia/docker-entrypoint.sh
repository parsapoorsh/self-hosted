#!/bin/sh
# Render configuration.yml.template with secrets, seed users DB, start Authelia.
# Image is Alpine/busybox - keep this POSIX sh (no bash).
set -eu

DATA="${AUTHELIA_DATA_DIR:-/data}"
RUNTIME="${AUTHELIA_RUNTIME_DIR:-/runtime}"
TEMPLATE="${AUTHELIA_TEMPLATE:-/init/configuration.yml.template}"
mkdir -p "${DATA}" "${RUNTIME}"

DOMAIN="${DOMAIN:-example.com}"
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
NX_CLIENT_ID="${MIRROR_OIDC_CLIENT_ID:-mirror}"
NX_CLIENT_SECRET="${MIRROR_OIDC_CLIENT_SECRET:-}"
MM_CLIENT_ID="${MATTERMOST_OIDC_CLIENT_ID:-mattermost}"
MM_CLIENT_SECRET="${MATTERMOST_OIDC_CLIENT_SECRET:-}"

# Names avoid AUTHELIA_* so the process does not treat them as config env overrides.
SESSION_SECRET="${SESSION_SECRET:-}"
STORAGE_KEY="${STORAGE_ENCRYPTION_KEY:-}"
HMAC_SECRET="${OIDC_HMAC_SECRET:-}"
# AUTH_DB_PASSWORD (not AUTHELIA_*) - Authelia maps AUTHELIA_* env to config keys.
DB_PASSWORD="${AUTH_DB_PASSWORD:-}"

log() { echo "authelia: $*" >&2; }

die() { log "ERROR: $*"; exit 1; }

[ -f "${TEMPLATE}" ] || die "missing template ${TEMPLATE}"
[ -n "${ADMIN_PASS}" ] || die "KEYCLOAK_ADMIN_PASSWORD (or AUTH_ADMIN_PASSWORD) required"
[ -n "${NC_CLIENT_SECRET}" ] || die "OIDC_CLIENT_SECRET required"
[ -n "${NX_CLIENT_SECRET}" ] || die "MIRROR_OIDC_CLIENT_SECRET required"
[ -n "${MM_CLIENT_SECRET}" ] || die "MATTERMOST_OIDC_CLIENT_SECRET required"
[ -n "${SESSION_SECRET}" ] || die "SESSION_SECRET required"
[ -n "${STORAGE_KEY}" ] || die "STORAGE_ENCRYPTION_KEY required"
[ -n "${HMAC_SECRET}" ] || die "OIDC_HMAC_SECRET required"
[ -n "${DB_PASSWORD}" ] || die "AUTH_DB_PASSWORD required"

# Username becomes a YAML key in the users file - keep it simple.
case "${ADMIN_USER}" in
  *[!a-zA-Z0-9_-]* | "")
    die "admin username must match [a-zA-Z0-9_-]+ (got '${ADMIN_USER}')"
    ;;
esac

# DOMAIN is substituted into hostnames - allow simple DNS labels only.
case "${DOMAIN}" in
  *[!a-zA-Z0-9.-]* | "" | .* | *..* | *- | *-.* )
    die "invalid DOMAIN: ${DOMAIN}"
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

# Persistent users file (volume). Managed by scripts/authelia-users.py after first boot.
USERS_DB="${DATA}/users_database.yml"

write_users_db() {
  if [ -f "${USERS_DB}" ]; then
    log "using existing users database ${USERS_DB}"
    return 0
  fi
  digest="$(hash_password "${ADMIN_PASS}")"
  [ -n "${digest}" ] || die "failed to hash admin password"
  log "seeding users database with admin '${ADMIN_USER}'"
  {
    printf 'users:\n'
    printf '  %s:\n' "${ADMIN_USER}"
    printf '    disabled: false\n'
    printf '    displayname: "Admin"\n'
    printf '    password: %s\n' "$(yaml_sq "${digest}")"
    printf '    email: %s\n' "$(yaml_sq "${ADMIN_EMAIL}")"
    printf '    groups:\n'
    printf '      - admins\n'
  } >"${USERS_DB}"
  chmod 600 "${USERS_DB}"
}

# Escape a string for use as a sed replacement (delimiter |).
sed_repl_escape() {
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

# Replace all PLACEHOLDER occurrences in a file (in place via temp).
# Values must not contain newlines (use inject_jwks for PEM).
subst_one() {
  file="$1"
  placeholder="$2"
  value="$3"
  esc="$(sed_repl_escape "${value}")"
  sed "s|${placeholder}|${esc}|g" "${file}" >"${file}.tmp"
  mv "${file}.tmp" "${file}"
}

inject_jwks() {
  file="$1"
  pem="$2"
  awk -v pemfile="${pem}" '
    /__JWKS_PEM__/ {
      while ((getline line < pemfile) > 0) {
        print "          " line
      }
      close(pemfile)
      next
    }
    { print }
  ' "${file}" >"${file}.tmp"
  mv "${file}.tmp" "${file}"
}

render_config() {
  nc_hash="$(hash_client_secret "${NC_CLIENT_SECRET}")"
  nx_hash="$(hash_client_secret "${NX_CLIENT_SECRET}")"
  mm_hash="$(hash_client_secret "${MM_CLIENT_SECRET}")"
  [ -n "${nc_hash}" ] || die "failed to hash nextcloud client secret"
  [ -n "${nx_hash}" ] || die "failed to hash mirror client secret"
  [ -n "${mm_hash}" ] || die "failed to hash mattermost client secret"

  out="${RUNTIME}/configuration.yml"
  cp "${TEMPLATE}" "${out}"

  subst_one "${out}" '__DOMAIN__' "${DOMAIN}"
  subst_one "${out}" '__SESSION_SECRET__' "${SESSION_SECRET}"
  subst_one "${out}" '__STORAGE_ENCRYPTION_KEY__' "${STORAGE_KEY}"
  subst_one "${out}" '__OIDC_HMAC_SECRET__' "${HMAC_SECRET}"
  subst_one "${out}" '__AUTHELIA_DB_PASSWORD__' "${DB_PASSWORD}"
  subst_one "${out}" '__OIDC_CLIENT_ID__' "${NC_CLIENT_ID}"
  subst_one "${out}" '__OIDC_CLIENT_SECRET_HASH__' "${nc_hash}"
  subst_one "${out}" '__MIRROR_OIDC_CLIENT_ID__' "${NX_CLIENT_ID}"
  subst_one "${out}" '__MIRROR_OIDC_CLIENT_SECRET_HASH__' "${nx_hash}"
  subst_one "${out}" '__MATTERMOST_OIDC_CLIENT_ID__' "${MM_CLIENT_ID}"
  subst_one "${out}" '__MATTERMOST_OIDC_CLIENT_SECRET_HASH__' "${mm_hash}"
  inject_jwks "${out}" "${DATA}/oidc_jwks.pem"

  # No leftover placeholders.
  if grep -q '__[A-Z0-9_]*__' "${out}"; then
    log "ERROR: unreplaced placeholders:"
    grep -o '__[A-Z0-9_]*__' "${out}" | sort -u >&2
    exit 1
  fi
}

log "building config for domain=${DOMAIN} admin=${ADMIN_USER}"
ensure_jwks
write_users_db
render_config

log "validating configuration"
authelia validate-config --config "${RUNTIME}/configuration.yml"

log "starting"
exec authelia --config "${RUNTIME}/configuration.yml"
