#!/bin/bash
# Exposes the running caption server on a public HTTPS URL so someone off your
# network can watch. Prints one link that already carries the access token.
#
# This puts a live microphone behind a public URL. The token stops strangers
# reaching it, but treat the link like a password: send it to one person, and
# stop the tunnel (Ctrl-C) when you are done.
set -euo pipefail
PORT="${CAPTION_PORT:-8420}"
TOKEN="${CAPTION_TOKEN:-}"

if [ -z "$TOKEN" ]; then
  echo "Refusing to share without a token."
  echo "Start the app with one, then run this again:"
  echo
  echo "  CAPTION_TOKEN=\"\$(openssl rand -hex 6)\" open -a build/ADI205Captions.app"
  exit 1
fi
if ! curl -sf -o /dev/null "http://localhost:$PORT/?k=$TOKEN"; then
  echo "No caption server answering on port $PORT with that token."
  echo "Is the app running, and was it started with this CAPTION_TOKEN?"
  exit 1
fi

echo "Opening a public tunnel to localhost:$PORT …"
echo "Share the https URL below WITH ?k=$TOKEN appended."
echo
exec cloudflared tunnel --url "http://localhost:$PORT"
