#!/bin/sh
# ============================================================================
#  build.sh - builds node-streaming-server on Linux and macOS.
#
#  There is nothing to compile: the server is plain Node.js with zero npm
#  dependencies. "Building" therefore means
#
#    1. find a Node.js runtime (tools/node first, then PATH)
#    2. check every source file parses
#    3. stage a self-contained, runnable dist/ folder
#    4. actually start that dist/ and stream a frame through it
#
#    ./build.sh                  build and smoke-test
#    ./build.sh --no-test        build only, skip the smoke test
#    ./build.sh --bundle-node    also copy tools/node into dist/node, so the
#                                dist/ folder runs on a machine with no Node
# ============================================================================
set -eu
cd "$(dirname "$0")"

MIN_MAJOR=18
DIST="$PWD/dist"
SKIPTEST=
BUNDLE=

for arg in "$@"; do
  case "$arg" in
    --no-test | --skip-tests) SKIPTEST=1 ;;
    --bundle-node) BUNDLE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

die() {
  echo
  echo "BUILD FAILED" >&2
  exit 1
}

echo "=== node-streaming-server : build ==="
echo

# ------------------------------------------------------- [1/5] the toolchain
echo "[1/5] locating Node.js ..."
if [ -x "tools/node/bin/node" ]; then
  NODE="$PWD/tools/node/bin/node"
elif command -v node >/dev/null 2>&1; then
  NODE=node
else
  echo
  echo "[FAIL] no Node.js found." >&2
  echo "       Run  ./download-tools.sh  first, or install Node.js >= v$MIN_MAJOR" >&2
  echo "       from https://nodejs.org" >&2
  die
fi

NODEVER="$("$NODE" --version 2>/dev/null || echo '')"
[ -n "$NODEVER" ] || { echo "[FAIL] \"$NODE\" is not a working Node.js binary." >&2; die; }
NODEMAJOR="$(printf '%s' "${NODEVER#v}" | cut -d. -f1)"
case "$NODEMAJOR" in ''|*[!0-9]*) NODEMAJOR=0 ;; esac
if [ "$NODEMAJOR" -lt "$MIN_MAJOR" ]; then
  echo "[FAIL] Node.js $NODEVER is too old - v$MIN_MAJOR or newer is required." >&2
  echo "       Run  ./download-tools.sh --force  to fetch a supported version." >&2
  die
fi
echo "      Node.js $NODEVER  ($NODE)"

# -------------------------------------------------------- [2/5] the sources
echo "[2/5] checking sources ..."
MISSING=
for f in server.js package.json public/index.html; do
  [ -f "$f" ] || MISSING="$MISSING $f"
done
if [ -n "$MISSING" ]; then
  echo "[FAIL] missing source file(s):$MISSING" >&2
  die
fi

"$NODE" --check server.js || die
"$NODE" --check scripts/smoke-test.js || die
"$NODE" -e "const p = JSON.parse(require('fs').readFileSync('package.json', 'utf8')); if (p.name === undefined || p.version === undefined) { throw new Error('package.json needs a name and a version'); } console.log('      ' + p.name + ' v' + p.version);" || die
echo "      server.js parses, package.json is valid"

# --------------------------------------------------------- [3/5] stage dist
echo "[3/5] staging dist/ ..."
rm -rf "$DIST"
mkdir -p "$DIST"
cp server.js package.json "$DIST/"
cp -R public "$DIST/public"
cp scripts/run-template.cmd "$DIST/run.cmd"
cp scripts/run-template.sh "$DIST/run.sh"
chmod +x "$DIST/run.sh"
if [ -f readme.md ]; then cp readme.md "$DIST/README.md"; fi
if [ -f LICENSE ]; then cp LICENSE "$DIST/LICENSE"; fi
echo "      server.js + public/ + run.cmd / run.sh"

if [ -n "$BUNDLE" ]; then
  if [ ! -x "tools/node/bin/node" ]; then
    echo "[FAIL] --bundle-node needs tools/node - run ./download-tools.sh --force" >&2
    die
  fi
  echo "      bundling the portable Node.js runtime ..."
  cp -R tools/node "$DIST/node"
fi

# ---------------------------------------------------------- [4/5] smoke test
if [ -n "$SKIPTEST" ]; then
  echo "[4/5] smoke test skipped (--no-test)"
else
  echo "[4/5] smoke test - starting dist/server.js and relaying a frame ..."
  if ! "$NODE" scripts/smoke-test.js "$DIST"; then
    echo
    echo "[FAIL] the built server did not pass the smoke test." >&2
    die
  fi
fi

# ---------------------------------------------------------------- [5/5] done
echo "[5/5] done"
echo
echo "BUILD OK"
echo
echo "  Run it:            ./dist/run.sh"
echo "  Or directly:       \"$NODE\" dist/server.js"
echo
echo "  The viewer page and the stream endpoint share one TCP port; the server"
echo "  prints it on startup (it prefers 80, then 8080, then 8000)."
echo
