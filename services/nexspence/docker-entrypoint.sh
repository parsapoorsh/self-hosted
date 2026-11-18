#!/bin/bash
# Start Nexspence, then (re)apply anonymous + catalog repos in the background.
set -euo pipefail

bootstrap_loop() {
  echo "nexspence: bootstrap waiting for REST API" >&2
  local i code
  for i in $(seq 1 90); do
    # status may be 401 until anonymous is enabled; any HTTP answer means up.
    code="$(
      curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 \
        "http://127.0.0.1:8081/api/v1/auth/config" 2>/dev/null || echo 000
    )"
    if [[ "${code}" == "200" ]]; then
      echo "nexspence: bootstrap API up (try ${i})" >&2
      export NEXSPENCE_URL=http://127.0.0.1:8081
      /init/bootstrap.sh
      return $?
    fi
    sleep 2
  done
  echo "nexspence: bootstrap gave up waiting for REST API" >&2
  return 1
}

(
  set +e
  while true; do
    bootstrap_loop
    status=$?
    if [[ "${status}" -eq 0 ]]; then
      exit 0
    fi
    echo "nexspence: bootstrap failed (exit ${status}); retry in 20s" >&2
    sleep 20
  done
) &

# Image entrypoint generates JWT secret when unset, then execs the binary.
exec /app/entrypoint.sh serve --config /app/config.yaml
