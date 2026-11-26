#!/bin/sh
set -eu

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

INSTALL_DIR="${KLUA_INSTALL_DIR:-$HOME/.local/bin}"
URL="https://github.com${OS}-${ARCH}.tar.gz"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading klua for ${OS}-${ARCH}..."
curl -fsSL "$URL" -o "$TMP_DIR/klua.tar.gz"
tar -xzf "$TMP_DIR/klua.tar.gz" -C "$TMP_DIR"

mkdir -p "$INSTALL_DIR"
install -m 755 "$TMP_DIR/klua" "$INSTALL_DIR/klua"
echo "Installed klua to $INSTALL_DIR/klua"
