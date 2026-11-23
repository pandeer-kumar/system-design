#!/usr/bin/env bash
# Builds the GitHub Pages site into build/site.
#   ./scripts/build-site.sh          build once
#   ./scripts/build-site.sh serve    live preview at http://127.0.0.1:8000
set -euo pipefail
export NO_MKDOCS_2_WARNING=1
cd "$(dirname "$0")/.."

rm -rf build/docs
mkdir -p build/docs
cp README.md build/docs/
cp -r [0-9][0-9]-*/ build/docs/

if [[ "${1:-}" == "serve" ]]; then
  # Re-copy on change is not automatic; rerun the script after editing files.
  mkdocs serve
else
  mkdocs build --strict
fi
