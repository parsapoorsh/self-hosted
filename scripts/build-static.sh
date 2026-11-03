#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

mkdir static/
cp docs/*.svg static/

./venv/bin/python3 docs/compiler/cli.py docs/*.md -o static/
