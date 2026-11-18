#!/usr/bin/env bash
# Restore Compose named volumes from .tar, .tar.gz, or .tar.xz archives.
# Archives are decompressed on the host and streamed into a helper container -
# no intermediate extraction directory or temporary copy is written.
#
# Usage: ./scripts/volumes-restore.sh [OPTIONS] PATH...
#
# PATH may be one archive, a directory containing archives, or a glob such as
# backup/shbk-2026-11-18_14-30-41/mattermost_*. A directory restores every
# .tar/.tar.gz/.tar.xz file directly inside it and ignores other files.
#
# Stop the services that use a volume before restoring it. The script refuses
# to restore a volume mounted by a running container unless --force is given.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

IMAGE="${VOLUME_HELPER_IMAGE:-alpine:3}"

compose_project() {
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    printf '%s\n' "${COMPOSE_PROJECT_NAME}"
    return 0
  fi
  local name
  name="$(sed -n 's/^name:[[:space:]]*//p' docker-compose.yml | head -1)"
  printf '%s\n' "${name:-$(basename "${ROOT}")}"
}

valid_volume_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

resolve_volume() {
  local name="$1"
  if [[ "${name}" == "${PROJECT}_"* ]]; then
    printf '%s\n' "${name}"
  else
    printf '%s\n' "${PROJECT}_${name}"
  fi
}

# Volume key without the archive suffix, or non-zero for other files.
archive_key() {
  local base
  base="$(basename -- "$1")"
  case "${base}" in
    *.tar.gz) base="${base%.tar.gz}" ;;
    *.tar.xz) base="${base%.tar.xz}" ;;
    *.tar) base="${base%.tar}" ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${base}"
}

decompress() {
  local path="$1"
  case "${path}" in
    *.tar.gz) gzip -dc -- "${path}" ;;
    *.tar.xz) xz -dc -- "${path}" ;;
    *.tar) cat -- "${path}" ;;
  esac
}

die() {
  echo "restore: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clear] [--force] PATH...

Restore Compose project "${PROJECT}" volumes from archives.

PATH is a .tar/.tar.gz/.tar.xz file, a directory holding such files, or a
glob. Archives are matched to volumes by filename:
  mattermost_data.tar.gz        -> volume ${PROJECT}_mattermost_data
  ${PROJECT}_mattermost_data.tar -> volume ${PROJECT}_mattermost_data

Only one archive per volume may be given; duplicates are rejected before
anything is restored. A directory restores all supported archives directly
inside it and ignores everything else.

Options:
  --clear   Remove the volume's current contents before extracting
  --force   Restore even when a running container mounts the volume
  -h, --help

Environment:
  VOLUME_HELPER_IMAGE  Image providing tar (default: alpine:3)

Examples:
  $(basename "$0") /mnt/backups/shbk-2026-11-18_14-30-41/
  $(basename "$0") /mnt/backups/shbk-2026-11-18_14-30-41/mattermost_*
EOF
}

PROJECT="$(compose_project)"
if ! valid_volume_name "${PROJECT}"; then
  echo "restore: invalid Compose project name: ${PROJECT}" >&2
  exit 1
fi

clear_volume=0
force=0
inputs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clear)
      clear_volume=1
      ;;
    --force)
      force=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      inputs+=("$@")
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      inputs+=("$1")
      ;;
  esac
  shift
done

if [[ "${#inputs[@]}" -eq 0 ]]; then
  usage >&2
  exit 2
fi

if ! command -v gzip >/dev/null 2>&1 || ! command -v xz >/dev/null 2>&1; then
  die "gzip and xz are required on the host"
fi

archives=()

add_directory() {
  local dir="$1"
  local found=0
  local path
  while IFS= read -r -d '' path; do
    archives+=("${path}")
    found=1
  done < <(
    find "${dir}" -mindepth 1 -maxdepth 1 -type f \
      \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tar.xz' \) \
      -print0 | sort -z
  )
  if [[ "${found}" -eq 0 ]]; then
    die "no .tar/.tar.gz/.tar.xz files in ${dir}"
  fi
}

add_archive() {
  local path="$1"
  if ! archive_key "${path}" >/dev/null; then
    die "not a .tar/.tar.gz/.tar.xz file: ${path}"
  fi
  archives+=("${path}")
}

# Expand shell globs that reached the script quoted, then walk each input.
for input in "${inputs[@]}"; do
  if [[ -d "${input}" ]]; then
    add_directory "${input}"
    continue
  fi
  if [[ -f "${input}" ]]; then
    add_archive "${input}"
    continue
  fi

  mapfile -t matches < <(compgen -G "${input}" || true)
  if [[ "${#matches[@]}" -eq 0 ]]; then
    die "no such file, directory, or glob match: ${input}"
  fi
  for match in "${matches[@]}"; do
    if [[ -d "${match}" ]]; then
      add_directory "${match}"
    elif [[ -f "${match}" ]]; then
      add_archive "${match}"
    fi
  done
done

# Validate every input and map archives to volumes before touching anything.
declare -A seen=()
restore_volumes=()
restore_files=()
for path in "${archives[@]}"; do
  key="$(archive_key "${path}")"
  volume="$(resolve_volume "${key}")"
  if ! valid_volume_name "${volume}"; then
    die "invalid volume name from ${path}: ${volume}"
  fi
  if [[ -n "${seen[${volume}]:-}" ]]; then
    die "multiple archives for volume ${volume}: ${seen[${volume}]} and ${path}"
  fi
  seen["${volume}"]="${path}"
  restore_volumes+=("${volume}")
  restore_files+=("${path}")
done

if [[ "${#restore_volumes[@]}" -eq 0 ]]; then
  die "nothing to restore"
fi

for i in "${!restore_volumes[@]}"; do
  volume="${restore_volumes[$i]}"
  file="${restore_files[$i]}"

  if [[ "${force}" -eq 0 ]] \
    && [[ -n "$(docker ps -q --filter "volume=${volume}")" ]]; then
    die "${volume} is mounted by a running container;" \
      "stop it or pass --force"
  fi

  echo "restore: ${file} -> ${volume}"
  # decompressor -> tar in helper container. pipefail catches a corrupt or
  # truncated archive on either side of the pipe.
  if ! decompress "${file}" | docker run --rm -i \
    --env CLEAR="${clear_volume}" \
    --volume "${volume}:/target" \
    "${IMAGE}" \
    sh -c '
      set -e
      if [ "${CLEAR}" = "1" ]; then
        find /target -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      fi
      tar -C /target -xf -
    '; then
    die "failed to restore ${volume} from ${file}"
  fi
done

echo "restore: done (${#restore_volumes[@]} volume(s))"
