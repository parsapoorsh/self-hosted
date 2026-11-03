#!/usr/bin/env bash
# Show RAM used by this compose stack: per container and total.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# compose.yml requires CALLS_ICE_HOST_OVERRIDE for interpolation (same as compose.sh).
if [[ -z "${CALLS_ICE_HOST_OVERRIDE:-}" ]]; then
  if [[ -f .env ]]; then
    # shellcheck disable=SC1091
    set -a
    source .env
    set +a
  fi
fi
if [[ -z "${CALLS_ICE_HOST_OVERRIDE:-}" ]]; then
  CALLS_ICE_HOST_OVERRIDE="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
  export CALLS_ICE_HOST_OVERRIDE
fi
if [[ -z "${CALLS_ICE_HOST_OVERRIDE:-}" ]]; then
  echo "usage-ram: set CALLS_ICE_HOST_OVERRIDE in .env (or use ./scripts/compose.sh)" >&2
  exit 1
fi
export CALLS_ICE_HOST_OVERRIDE

COMPOSE=(docker compose --env-file .env --env-file .env.secrets)

# Human size from docker stats (e.g. 21.35MiB, 1.2GiB) -> bytes.
to_bytes() {
  local raw="$1"
  local num unit
  num="$(printf '%s' "${raw}" | sed -E 's/[^0-9.]//g')"
  unit="$(printf '%s' "${raw}" | sed -E 's/[0-9.]+//g' | tr '[:lower:]' '[:upper:]')"
  case "${unit}" in
    B|"")
      awk -v n="${num}" 'BEGIN { printf "%.0f", n }'
      ;;
    KIB|KB)
      awk -v n="${num}" 'BEGIN { printf "%.0f", n * 1024 }'
      ;;
    MIB|MB)
      awk -v n="${num}" 'BEGIN { printf "%.0f", n * 1024 * 1024 }'
      ;;
    GIB|GB)
      awk -v n="${num}" 'BEGIN { printf "%.0f", n * 1024 * 1024 * 1024 }'
      ;;
    TIB|TB)
      awk -v n="${num}" 'BEGIN { printf "%.0f", n * 1024 * 1024 * 1024 * 1024 }'
      ;;
    *)
      echo 0
      ;;
  esac
}

# Bytes -> short human string (MiB / GiB).
fmt_bytes() {
  local b="$1"
  awk -v b="${b}" 'BEGIN {
    if (b >= 1024 * 1024 * 1024) {
      printf "%.2f GiB", b / (1024 * 1024 * 1024)
    } else if (b >= 1024 * 1024) {
      printf "%.2f MiB", b / (1024 * 1024)
    } else if (b >= 1024) {
      printf "%.2f KiB", b / 1024
    } else {
      printf "%d B", b
    }
  }'
}

ids=()
while IFS= read -r id; do
  [[ -n "${id}" ]] && ids+=("${id}")
done < <("${COMPOSE[@]}" ps -q 2>/dev/null || true)

if [[ "${#ids[@]}" -eq 0 ]]; then
  echo "usage-ram: no running containers in this compose project" >&2
  exit 1
fi

# name | used | limit | percent
mapfile -t lines < <(
  docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}' "${ids[@]}"
)

total=0
printf '%-36s %12s %12s %8s\n' "CONTAINER" "USED" "LIMIT" "%RAM"
printf '%-36s %12s %12s %8s\n' "------------------------------------" "------------" "------------" "--------"

for line in "${lines[@]}"; do
  name="$(printf '%s' "${line}" | cut -f1)"
  usage="$(printf '%s' "${line}" | cut -f2)"
  perc="$(printf '%s' "${line}" | cut -f3)"
  used_raw="${usage%% /*}"
  limit_raw="${usage##*/ }"
  used_b="$(to_bytes "${used_raw}")"
  total=$((total + used_b))
  printf '%-36s %12s %12s %8s\n' \
    "${name}" \
    "${used_raw}" \
    "${limit_raw}" \
    "${perc}"
done

printf '%-36s %12s %12s %8s\n' "------------------------------------" "------------" "------------" "--------"
printf '%-36s %12s\n' "TOTAL" "$(fmt_bytes "${total}")"
