#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if command -v python3 >/dev/null 2>&1; then
  if [ "$#" -eq 0 ]; then
    python3 "$SCRIPT_DIR/patch_codex_gpt56.py" --guided
  else
    python3 "$SCRIPT_DIR/patch_codex_gpt56.py" --yes "$@"
  fi
elif command -v node >/dev/null 2>&1; then
  echo "Python was not found. Running the Node.js configuration-only fallback."
  if [ "$#" -eq 0 ]; then
    node "$SCRIPT_DIR/configure_codex_gpt56.mjs" --guided
  else
    node "$SCRIPT_DIR/configure_codex_gpt56.mjs" --yes "$@"
  fi
else
  echo "Neither Python nor Node.js was found."
  echo "Install Python 3.10+ for the full Desktop patch, or Node.js 20+ for configuration-only mode."
  exit 2
fi
printf '\nPress Return to close...'
read answer
