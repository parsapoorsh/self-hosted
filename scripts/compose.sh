#!/usr/bin/env bash
# docker compose wrapper: refresh derived secrets, then run compose with both env files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

./scripts/sync-secrets.sh

exec docker compose \
  --env-file .env \
  --env-file .env.secrets \
  "$@"
