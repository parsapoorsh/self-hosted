#!/usr/bin/env bash
# Create (or update password for) an app database on the shared postgres service.
# Use this after the volume already exists — init scripts only run on first boot.
#
# Usage:
#   ./scripts/pg-app-db.sh <db> <user> <password>
#   ./scripts/pg-app-db.sh gitea gitea 'secret'
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <db> <user> <password>" >&2
  exit 2
fi

DB="$1"
USER_NAME="$2"
PASS="$3"

# Identifiers only: keep names simple so we do not need full SQL identifier quoting.
if [[ ! "$DB" =~ ^[a-z][a-z0-9_]*$ ]] || [[ ! "$USER_NAME" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "db and user must match [a-z][a-z0-9_]*" >&2
  exit 2
fi

sql_quote() {
  printf "%s" "${1//\'/\'\'}"
}

PASS_SQL="$(sql_quote "$PASS")"

docker compose exec -T postgres \
  psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres \
  -c "DO \$\$ BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${USER_NAME}') THEN
          CREATE ROLE ${USER_NAME} LOGIN PASSWORD '${PASS_SQL}';
        ELSE
          ALTER ROLE ${USER_NAME} WITH LOGIN PASSWORD '${PASS_SQL}';
        END IF;
      END \$\$;"

EXISTS="$(
  docker compose exec -T postgres \
    psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres \
    -tAc "SELECT 1 FROM pg_database WHERE datname = '${DB}'" | tr -d '[:space:]'
)"

if [[ "$EXISTS" != "1" ]]; then
  docker compose exec -T postgres \
    psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres \
    -c "CREATE DATABASE ${DB} OWNER ${USER_NAME}"
fi

docker compose exec -T postgres \
  psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres \
  -c "GRANT ALL PRIVILEGES ON DATABASE ${DB} TO ${USER_NAME}"

docker compose exec -T postgres \
  psql -v ON_ERROR_STOP=1 --username postgres --dbname "${DB}" \
  -c "GRANT ALL ON SCHEMA public TO ${USER_NAME}" \
  -c "ALTER SCHEMA public OWNER TO ${USER_NAME}"

echo "ok: database=${DB} user=${USER_NAME}"
