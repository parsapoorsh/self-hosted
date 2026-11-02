#!/usr/bin/env bash
# Start Nexus, then (re)apply admin/Rut Auth/default-repo cleanup in the background.
set -euo pipefail

BOOTSTRAP=/init/bootstrap.sh

# Build the ContentUsage override JAR before Nexus starts; loader.path loads it
# ahead of the copy inside the main JAR.
python3 /init/patch-usage-limit.py || true

# Keep base telemetry on loopback so an air-gapped instance never reaches the
# 10-day upload grace period and switches to read-only mode.
(
  set +e
  while true; do
    python3 /init/telemetry-sink.py
    echo "nexus: telemetry sink exited; restarting" >&2
    sleep 2
  done
) &

(
  echo "nexus: bootstrap waiting for REST API" >&2
  for i in $(seq 1 120); do
    if curl -sS -f -o /dev/null "http://127.0.0.1:8081/service/rest/v1/status" 2>/dev/null; then
      echo "nexus: bootstrap API up (try ${i})" >&2
      export NEXUS_URL=http://127.0.0.1:8081
      export NEXUS_DATA_DIR=/nexus-data
      # Give first-boot admin.password a moment to appear before configure runs.
      sleep 5
      exec /bin/bash "${BOOTSTRAP}"
    fi
    sleep 5
  done
  echo "nexus: bootstrap gave up waiting for REST API" >&2
  exit 1
) &

exec /opt/sonatype/start-nexus-repository-manager.sh
