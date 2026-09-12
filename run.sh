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

case "${CAPTION_CORRECTOR:-}" in
  qwen|llama|ollama|local)
    BASE="${LOCAL_BASE_URL:-${QWEN_BASE_URL:-http://localhost:11434/v1}}"
    MODEL="${LOCAL_MODEL:-${QWEN_MODEL:-qwen2.5:1.5b}}"
    if ! curl -sf -m 2 -o /dev/null "${BASE%/v1}/api/tags"; then
      echo "CAPTION_CORRECTOR=$CAPTION_CORRECTOR but no local model server is answering at $BASE." >&2
      echo "Start it with:  ollama serve" >&2
      echo "Then:           ollama pull $MODEL" >&2
      exit 1
    fi
    ;;
esac

if [ "${CAPTION_CORRECTOR:-}" = "gemini" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
  echo "CAPTION_CORRECTOR=gemini but GEMINI_API_KEY is empty." >&2
  echo "Correction would silently stay off. Add the key to .env.local." >&2
  exit 1
fi

BIN="$(./make_app.sh captiond ADI205Captions)"
echo "launching $BIN"
exec "$BIN"
