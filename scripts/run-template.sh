#!/bin/sh
# ============================================================================
#  run.sh - starts the Streaming Server from this folder and opens the viewer
#  page. Copied here by build.sh; edit the original in scripts/run-template.sh.
#
#  Node.js is looked for in this order:
#    1. node/bin/node        (bundled by "./build.sh --bundle-node")
#    2. ../tools/node        (fetched by ./download-tools.sh)
#    3. node on PATH
# ============================================================================
set -eu
cd "$(dirname "$0")"

if [ -x "node/bin/node" ]; then
  NODE="$PWD/node/bin/node"
elif [ -x "../tools/node/bin/node" ]; then
  NODE="$(cd .. && pwd)/tools/node/bin/node"
elif command -v node >/dev/null 2>&1; then
  NODE=node
else
  echo "No Node.js found." >&2
  echo "Run ./download-tools.sh in the project folder, or install Node.js" >&2
  echo "version 18 or newer from https://nodejs.org" >&2
  exit 1
fi

echo "Starting Streaming Server ..."
"$NODE" server.js &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' INT TERM

# The server writes .ports.json with the port it managed to bind.
TRIES=0
while [ ! -f .ports.json ] && [ "$TRIES" -lt 30 ]; do
  sleep 1
  TRIES=$((TRIES + 1))
done

if [ -f .ports.json ]; then
  PORT="$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' .ports.json)"
  URL="http://localhost:$PORT/"
  echo "Viewer page: $URL"
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$URL" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then
    open "$URL" >/dev/null 2>&1 || true
  else
    echo "Open $URL in a browser."
  fi
else
  echo "The server started but reported no port - check the output above."
fi

wait "$SERVER_PID"
