#!/usr/bin/env bash
# Runs once on first Postgres data-dir init (empty volume only).
# Creates one database + role per app. Add more create_app_db calls below
# when you introduce a new service. For an already-initialized volume, use:
#   ./scripts/pg-app-db.sh <db> <user> <password>
set -euo pipefail

# Escape a value for use inside a single-quoted SQL string literal.
sql_quote() {
  printf "%s" "${1//\'/\'\'}"
}

create_app_db() {
  local db="$1"
  local user="$2"
  local pass="$3"

  if [[ -z "$pass" ]]; then
    echo "skip ${db}: password env empty" >&2
    return 0
  fi

  local pass_sql
  pass_sql="$(sql_quote "$pass")"

  echo "ensuring database '${db}' owner '${user}'"

  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname postgres \
    -c "DO \$\$ BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${user}') THEN
            CREATE ROLE ${user} LOGIN PASSWORD '${pass_sql}';
          ELSE
            ALTER ROLE ${user} WITH LOGIN PASSWORD '${pass_sql}';
          END IF;
        END \$\$;"

  # CREATE DATABASE cannot run inside a DO block.
  if ! psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname postgres \
      -tAc "SELECT 1 FROM pg_database WHERE datname = '${db}'" | grep -q 1; then
    psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname postgres \
      -c "CREATE DATABASE ${db} OWNER ${user}"
  fi

  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname postgres \
    -c "GRANT ALL PRIVILEGES ON DATABASE ${db} TO ${user}"

  # PG 15+: app role needs schema rights inside its DB
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${db}" \
    -c "GRANT ALL ON SCHEMA public TO ${user}" \
    -c "ALTER SCHEMA public OWNER TO ${user}"
}

# --- app databases ---
create_app_db nextcloud nextcloud "${NEXTCLOUD_DB_PASSWORD:-}"
create_app_db authelia authelia "${AUTH_DB_PASSWORD:-}"
create_app_db mattermost mattermost "${MATTERMOST_DB_PASSWORD:-}"
