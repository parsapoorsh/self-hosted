#!/usr/bin/env bash
# Tear down the stack and wipe named volumes (postgres, nextcloud, nexus).
# Containers, networks, and compose-declared volumes are removed.
#
# Usage:
#   ./scripts/reset.sh
#   ./scripts/compose.sh up -d    # always use compose.sh (loads .env.secrets)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "stopping stack and removing containers, networks, volumes..."
if [[ -f .env && -x ./scripts/compose.sh ]]; then
  ./scripts/compose.sh down -v --remove-orphans
else
  docker compose down -v --remove-orphans
fi

echo "done. start again with: ./scripts/compose.sh up -d"
