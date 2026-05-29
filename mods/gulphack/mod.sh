#!/bin/sh

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
PYTHON="$ROOT/.venv/bin/python3"
if [ ! -x "$PYTHON" ]; then
    PYTHON=python3
fi

exec "$PYTHON" "$ROOT/tools/mod-builder/main.py"
