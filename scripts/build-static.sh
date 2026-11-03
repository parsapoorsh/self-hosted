#!/usr/bin/env bash
# Build landing HTML under static/ from docs/*.md (DOMAIN -> ${domain}).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

DOMAIN="${DOMAIN:-example.com}"
export DOMAIN

PY="${ROOT}/venv/bin/python3"
if [[ ! -x "${PY}" ]]; then
  echo "build-static: missing ${PY}" >&2
  echo "build-static: create venv and: pip install -r docs/compiler/requirements.txt" >&2
  exit 1
fi

echo "build-static: DOMAIN=${DOMAIN}"
mkdir -p static
# Clear previous build outputs only (keep directory mount stable).
find static -mindepth 1 -maxdepth 1 -exec rm -rf {} +

shopt -s nullglob
svgs=(docs/*.svg)
if ((${#svgs[@]} > 0)); then
  cp "${svgs[@]}" static/
fi

mapfile -t mds < <(find docs -maxdepth 1 -type f -name '*.md' | sort)
if ((${#mds[@]} == 0)); then
  echo "build-static: no docs/*.md" >&2
  exit 1
fi

"${PY}" docs/compiler/cli.py --domain "${DOMAIN}" "${mds[@]}" -o static/

if [[ ! -f static/index.html ]]; then
  echo "build-static: expected static/index.html (from docs/INDEX.md)" >&2
  exit 1
fi

echo "build-static: wrote $(find static -type f | wc -l) files under static/"