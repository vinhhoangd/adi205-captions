#!/bin/bash
# Builds and launches the caption app with the settings in .env.local.
#
# The app is launched as a child of this shell rather than through `open`, so
# it inherits these variables. `open` hands the bundle to launchd, which does
# not pass the calling shell's environment along — that is why a key exported
# in a terminal appears to be ignored.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [ -f .env.local ]; then
  set -a; . ./.env.local; set +a
else
  echo "No .env.local — copy .env.example to .env.local and fill it in." >&2
fi

if [ "${CAPTION_CORRECTOR:-}" = "gemini" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
  echo "CAPTION_CORRECTOR=gemini but GEMINI_API_KEY is empty." >&2
  echo "Correction would silently stay off. Add the key to .env.local." >&2
  exit 1
fi

BIN="$(./make_app.sh captiond ADI205Captions)"
echo "launching $BIN"
exec "$BIN"
