#!/bin/sh
# Streaming Server launcher: finds or downloads Node.js, starts the server,
# then opens the viewer page in a browser when possible.
cd "$(dirname "$0")" || exit 1

NODE_VER=v22.12.0
# Reuse the portable Node.js that download-tools.sh puts in tools/node, so the
# two scripts never fetch two separate copies of the runtime.
if [ -x "tools/node/bin/node" ]; then
  NODE="$PWD/tools/node/bin/node"
elif command -v node >/dev/null 2>&1; then
  NODE=node
else
  case "$(uname -m)" in
    x86_64) ARCH=x64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    armv7l) ARCH=armv7l ;;
    *) ARCH=x64 ;;
  esac
  DIR="node-portable/node-$NODE_VER-linux-$ARCH"
  NODE="$DIR/bin/node"
  if [ ! -x "$NODE" ]; then
    echo "Node.js not found - downloading portable $NODE_VER ..."
    mkdir -p node-portable
    TARBALL="node-$NODE_VER-linux-$ARCH.tar.xz"
    if command -v curl >/dev/null 2>&1; then
      curl -fL "https://nodejs.org/dist/$NODE_VER/$TARBALL" \
        -o "node-portable/$TARBALL" || exit 1
    elif command -v wget >/dev/null 2>&1; then
      wget -O "node-portable/$TARBALL" \
        "https://nodejs.org/dist/$NODE_VER/$TARBALL" || exit 1
    else
      echo "Neither curl nor wget available - install Node.js manually."
      exit 1
    fi
    tar -xf "node-portable/$TARBALL" -C node-portable || exit 1
    rm -f "node-portable/$TARBALL"
    [ -x "$NODE" ] || { echo "Node.js unpack failed."; exit 1; }
  fi
fi

echo "Starting Streaming Server ..."
"$NODE" server.js &
SERVER_PID=$!

# Wait for the sticky port file, then open the viewer page.
TRIES=0
while [ ! -f .ports.json ] && [ "$TRIES" -lt 30 ]; do
  sleep 1
  TRIES=$((TRIES + 1))
done
if [ -f .ports.json ]; then
  PORT=$(sed -n 's/.*"viewer":\([0-9]*\).*/\1/p' .ports.json)
  URL="http://localhost:$PORT/"
  echo "Viewer page: $URL"
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$URL" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then
    open "$URL" || true
  else
    echo "Open $URL in a browser."
  fi
else
  echo "Server started but no port file appeared - check the output above."
fi

wait $SERVER_PID
