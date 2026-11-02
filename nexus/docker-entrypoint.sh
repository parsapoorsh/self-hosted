#!/usr/bin/env bash
# Start Nexus, then (re)apply admin/Rut Auth/default-repo cleanup in the background.
set -euo pipefail

BOOTSTRAP=/init/bootstrap.sh

(
  echo "nexus: bootstrap waiting for REST API"
  for i in $(seq 1 120); do
    if curl -sS -f -o /dev/null "http://127.0.0.1:8081/service/rest/v1/status" 2>/dev/null; then
      echo "nexus: bootstrap API up (try ${i})"
      export NEXUS_URL=http://127.0.0.1:8081
      export NEXUS_DATA_DIR=/nexus-data
      exec /bin/bash "${BOOTSTRAP}"
    fi
    sleep 5
  done
  echo "nexus: bootstrap gave up waiting for REST API" >&2
  exit 1
) &

exec /opt/sonatype/start-nexus-repository-manager.sh
