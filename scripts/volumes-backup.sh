#!/usr/bin/env bash
# Back up Compose named volumes to <output>/shbk-YYYY-MM-DD_HH-MM-SS/.
# Each volume becomes one .tar.gz (gzip -1), streamed from a helper container
# straight into the file - no intermediate tar or temporary copy is written.
#
# Usage: ./scripts/volumes-backup.sh OUTPUT_DIR [VOLUME...]
#
# Stop the stack first when you need a consistent database snapshot; a raw
# copy of a volume in use can capture a half-written database.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

IMAGE="${VOLUME_HELPER_IMAGE:-alpine:3}"
GZIP_LEVEL=1

# Compose project name: COMPOSE_PROJECT_NAME, else top-level `name:`, else dir.
compose_project() {
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    printf '%s\n' "${COMPOSE_PROJECT_NAME}"
    return 0
  fi
  local name
  name="$(sed -n 's/^name:[[:space:]]*//p' docker-compose.yml | head -1)"
  printf '%s\n' "${name:-$(basename "${ROOT}")}"
}

# Volume keys declared in the top-level `volumes:` block.
declared_volumes() {
  awk '
    /^volumes:[[:space:]]*$/ { in_volumes = 1; next }
    in_volumes && /^[^[:space:]]/ { exit }
    in_volumes && /^  [A-Za-z0-9_.-]+:/ {
      sub(/^  /, "")
      sub(/:.*/, "")
      print
    }
  ' docker-compose.yml
}

valid_volume_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

# Accept both the Compose key (mattermost_data) and the Docker name
# (self-hosted_mattermost_data).
resolve_volume() {
  local name="$1"
  if [[ "${name}" == "${PROJECT}_"* ]]; then
    printf '%s\n' "${name}"
  else
    printf '%s\n' "${PROJECT}_${name}"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") OUTPUT_DIR [VOLUME...]

Back up named volumes of Compose project "${PROJECT}" into a new
shbk-YYYY-MM-DD_HH-MM-SS/ directory under OUTPUT_DIR.

VOLUME is a Compose volume key (mattermost_data) or the full Docker name
(${PROJECT}_mattermost_data). Without VOLUME, every volume declared in
docker-compose.yml is backed up.

Each volume is written as <short-name>.tar.gz with gzip -1.

Environment:
  VOLUME_HELPER_IMAGE  Image providing tar (default: alpine:3)

Examples:
  $(basename "$0") /mnt/backups
  $(basename "$0") /mnt/backups mattermost_data postgres_data
EOF
}

PROJECT="$(compose_project)"

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi
case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
esac

OUT_DIR="$1"
shift

if ! valid_volume_name "${PROJECT}"; then
  echo "backup: invalid Compose project name: ${PROJECT}" >&2
  exit 1
fi

if ! command -v gzip >/dev/null 2>&1; then
  echo "backup: gzip not found on the host" >&2
  exit 1
fi

# All volumes when none are named; explicit volumes otherwise.
volumes=()
if [[ $# -eq 0 ]]; then
  while IFS= read -r key; do
    [[ -n "${key}" ]] && volumes+=("${PROJECT}_${key}")
  done < <(declared_volumes)
  if [[ "${#volumes[@]}" -eq 0 ]]; then
    echo "backup: no volumes declared in docker-compose.yml" >&2
    exit 1
  fi
else
  for name in "$@"; do
    if ! valid_volume_name "${name}"; then
      echo "backup: invalid volume name: ${name}" >&2
      exit 1
    fi
    volumes+=("$(resolve_volume "${name}")")
  done
fi

for volume in "${volumes[@]}"; do
  if ! docker volume inspect "${volume}" >/dev/null 2>&1; then
    echo "backup: no such volume: ${volume}" >&2
    exit 1
  fi
done

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
DEST="${OUT_DIR}/shbk-$(date +%Y-%m-%d_%H-%M-%S)"
if ! mkdir "${DEST}"; then
  echo "backup: cannot create ${DEST}" >&2
  exit 1
fi

echo "backup: project=${PROJECT} dest=${DEST}"

for volume in "${volumes[@]}"; do
  short="${volume#"${PROJECT}_"}"
  file="${DEST}/${short}.tar.gz"

  if [[ -n "$(docker ps -q --filter "volume=${volume}")" ]]; then
    echo "backup: warning: ${volume} is mounted by a running container;" \
      "the archive may be inconsistent" >&2
  fi

  echo "backup: ${volume} -> ${file}"
  # tar -> host gzip -> file. pipefail removes a partial file on failure.
  if ! docker run --rm --volume "${volume}:/source:ro" "${IMAGE}" \
    tar -C /source -cf - . | gzip "-${GZIP_LEVEL}" >"${file}"; then
    rm -f "${file}"
    echo "backup: failed for ${volume}" >&2
    exit 1
  fi
  echo "backup: wrote $(du -h "${file}" | cut -f1) ${file}"
done

echo "backup: done (${#volumes[@]} volume(s)) -> ${DEST}"
