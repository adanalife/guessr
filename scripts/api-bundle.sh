#!/usr/bin/env bash
# Stage what the Python Worker ships into api/bundle/: the server package and
# the alias wordlist rules.py reads at import. api/wrangler.jsonc points its
# module root here, because wrangler uploads every .py under the module root and
# its rules cannot narrow that -- the repo root would ship every script and the
# whole .venv.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf api/bundle
mkdir -p api/bundle/web
rsync -a --exclude __pycache__ server api/bundle/
cp web/alias.json api/bundle/web/
