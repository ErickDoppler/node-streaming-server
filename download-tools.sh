#!/bin/sh
# ============================================================================
#  download-tools.sh - fetches every tool needed to build and run this project
#  on Linux and macOS.
#
#  The server has zero npm dependencies, so the one and only build tool is the
#  Node.js runtime. It is fetched as a portable tarball into tools/node/ -
#  nothing is installed system-wide, no sudo, no package manager.
#
#    ./download-tools.sh           reuse the Node.js already on PATH if it is
#                                  new enough, otherwise download a portable one
#    ./download-tools.sh --force   always download the portable Node.js
#
#  Override the version with:  NODE_VERSION=v20.18.1 ./download-tools.sh
# ============================================================================
set -eu

cd "$(dirname "$0")"

NODE_VERSION="${NODE_VERSION:-v22.12.0}"
MIN_MAJOR=18
TOOLS="$PWD/tools"
NODE_HOME="$TOOLS/node"
NODE_EXE="$NODE_HOME/bin/node"
DL="$TOOLS/download"

FORCE=
case "${1:-}" in
  --force | -f) FORCE=1 ;;
  '') ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

echo "=== node-streaming-server : download-tools ==="
echo

summary() {
  echo
  echo "All build tools are in place."
  echo "Next:  ./build.sh"
  echo
  exit 0
}

# ------------------------------------------------------------------ already?
if [ -z "$FORCE" ] && [ -x "$NODE_EXE" ]; then
  echo "[ok]   portable Node.js $("$NODE_EXE" --version) is already in tools/node"
  summary
fi

# ------------------------------------------------------------ Node on PATH?
if [ -z "$FORCE" ] && command -v node >/dev/null 2>&1; then
  SYSVER="$(node --version 2>/dev/null || echo '')"
  SYSMAJOR="$(printf '%s' "${SYSVER#v}" | cut -d. -f1)"
  case "$SYSMAJOR" in
    ''|*[!0-9]*) SYSMAJOR=0 ;;
  esac
  if [ "$SYSMAJOR" -ge "$MIN_MAJOR" ]; then
    echo "[ok]   Node.js $SYSVER found on PATH - new enough, no download needed"
    echo "       (run \"./download-tools.sh --force\" to get a portable copy anyway)"
    summary
  fi
  echo "[..]   Node.js $SYSVER on PATH is older than v$MIN_MAJOR"
else
  [ -n "$FORCE" ] || echo "[..]   no Node.js on PATH"
fi

# --------------------------------------------------- pick the right tarball
case "$(uname -s)" in
  Linux)  OS=linux ;;
  Darwin) OS=darwin ;;
  *)
    echo "[FAIL] unsupported OS: $(uname -s)." >&2
    echo "       Install Node.js >= v$MIN_MAJOR yourself from https://nodejs.org" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64 | amd64)  ARCH=x64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  armv7l)          ARCH=armv7l ;;
  ppc64le)         ARCH=ppc64le ;;
  s390x)           ARCH=s390x ;;
  *)
    echo "[FAIL] unsupported CPU: $(uname -m)." >&2
    echo "       Install Node.js >= v$MIN_MAJOR yourself from https://nodejs.org" >&2
    exit 1
    ;;
esac

# Official builds are glibc-linked; musl systems (Alpine) need their own.
if [ "$OS" = linux ] && [ -f /etc/alpine-release ]; then
  echo "[FAIL] Alpine/musl detected - nodejs.org builds are glibc-only." >&2
  echo "       Install Node.js with:  apk add nodejs" >&2
  exit 1
fi

PKG="node-$NODE_VERSION-$OS-$ARCH"
TGZ="$PKG.tar.gz"
BASE="https://nodejs.org/dist/$NODE_VERSION"

# ------------------------------------------------------------------- fetch
fetch() { # fetch <url> <destination>
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --proto '=https' -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only -O "$2" "$1"
  else
    echo "[FAIL] neither curl nor wget is available." >&2
    echo "       Install one of them, or install Node.js >= v$MIN_MAJOR" >&2
    echo "       yourself from https://nodejs.org" >&2
    exit 1
  fi
}

echo "[..]   downloading Node.js $NODE_VERSION ($OS-$ARCH) ..."
mkdir -p "$DL"
fetch "$BASE/$TGZ" "$DL/$TGZ"
fetch "$BASE/SHASUMS256.txt" "$DL/SHASUMS256.txt"

# --- verify against the checksums published by nodejs.org -------------------
echo "[..]   verifying SHA-256 ..."
WANT="$(grep " $TGZ\$" "$DL/SHASUMS256.txt" | head -n 1 | cut -d' ' -f1)"
if command -v sha256sum >/dev/null 2>&1; then
  GOT="$(sha256sum "$DL/$TGZ" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  GOT="$(shasum -a 256 "$DL/$TGZ" | cut -d' ' -f1)"
else
  GOT=""
  echo "[warn] no sha256sum/shasum available - skipping checksum verification"
fi
if [ -n "$GOT" ]; then
  if [ -z "$WANT" ] || [ "$WANT" != "$GOT" ]; then
    echo "[FAIL] SHA-256 of $TGZ does not match nodejs.org SHASUMS256.txt." >&2
    echo "       The download was corrupted or tampered with - nothing installed." >&2
    rm -f "$DL/$TGZ"
    exit 1
  fi
  echo "[ok]   checksum matches nodejs.org SHASUMS256.txt"
fi

# ------------------------------------------------------------------ unpack
echo "[..]   unpacking ..."
rm -rf "$DL/unpack"
mkdir -p "$DL/unpack"
tar -xzf "$DL/$TGZ" -C "$DL/unpack"
[ -x "$DL/unpack/$PKG/bin/node" ] || {
  echo "[FAIL] could not unpack $TGZ." >&2
  exit 1
}

rm -rf "$NODE_HOME"
mkdir -p "$TOOLS"
mv "$DL/unpack/$PKG" "$NODE_HOME"
rm -rf "$DL"

echo "[ok]   portable Node.js $("$NODE_EXE" --version) installed in tools/node"
summary
