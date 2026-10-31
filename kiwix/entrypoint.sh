#!/bin/sh
set -eu

ZIM_DIR="${ZIM_DIR:-/zim}"
LIBRARY_XML="${LIBRARY_XML:-/data/library.xml}"
KIWIX_PORT="${KIWIX_PORT:-9393}"
KIWIX_THREADS="${KIWIX_THREADS:-$(nproc)}"

rm -f "$LIBRARY_XML"

find "$ZIM_DIR" -type f -name '*.zim' -print0 \
  | xargs -0 -r kiwix-manage "$LIBRARY_XML" add

if [ ! -s "$LIBRARY_XML" ]; then
  echo "WARNING: No .zim files found in $ZIM_DIR" >&2
  if [ ! -f "$LIBRARY_XML" ]; then
    printf '%s\n' '<library version="20110515"></library>' > "$LIBRARY_XML"
  fi
fi

# Port, threads, and bind address come from env; remaining args are extra flags
set -- --port "$KIWIX_PORT" --threads "$KIWIX_THREADS" "$@"

if [ -n "${KIWIX_HOST:-}" ]; then
  set -- --address "$KIWIX_HOST" "$@"
fi

exec kiwix-serve --library "$LIBRARY_XML" "$@"
