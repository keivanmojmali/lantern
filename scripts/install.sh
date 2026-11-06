#!/bin/bash
# Build Lantern + the `lantern` CLI and install them.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Lantern.xcodeproj -scheme Lantern -configuration Release -derivedDataPath build build -quiet
xcodebuild -project Lantern.xcodeproj -scheme lantern -configuration Release -derivedDataPath build build -quiet
APP_DIR="${LANTERN_INSTALL_APPS:-$HOME/Applications}"; BIN_DIR="${LANTERN_INSTALL_BIN:-$HOME/.local/bin}"
mkdir -p "$APP_DIR" "$BIN_DIR"
rm -rf "$APP_DIR/Lantern.app"
cp -R build/Build/Products/Release/Lantern.app "$APP_DIR/Lantern.app"
cp build/Build/Products/Release/lantern "$BIN_DIR/lantern"
echo "Installed $APP_DIR/Lantern.app and $BIN_DIR/lantern"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "Note: add $BIN_DIR to your PATH";; esac
echo "Let Claude drive the viewer:  claude mcp add --scope user lantern -- $BIN_DIR/lantern mcp"
