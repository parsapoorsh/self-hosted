#!/usr/bin/env bash
# Tear down the stack and wipe named volumes (postgres, nextcloud, nexus).
# Containers, networks, and compose-declared volumes are removed.
#
# Usage:
#   ./scripts/reset.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "stopping stack and removing containers, networks, volumes..."
docker compose down -v --remove-orphans

echo "done. start again with: docker compose up -d"
