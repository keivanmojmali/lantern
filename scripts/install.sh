#!/bin/bash
# Build Lantern + the `lantern` CLI, install them, and verify the install with an isolated smoke test.
#   LANTERN_INSTALL_APPS (default /Applications)   LANTERN_INSTALL_BIN (default ~/.local/bin)
set -euo pipefail
cd "$(dirname "$0")/.."
APP_DIR="${LANTERN_INSTALL_APPS:-/Applications}"; BIN_DIR="${LANTERN_INSTALL_BIN:-$HOME/.local/bin}"

xcodegen generate >/dev/null
for scheme in Lantern lantern; do
  xcodebuild -project Lantern.xcodeproj -scheme "$scheme" -configuration Release -derivedDataPath build build -quiet 2>&1 | grep -E "error:" | grep -v DVT || true
done
SRC_APP=build/Build/Products/Release/Lantern.app; SRC_CLI=build/Build/Products/Release/lantern
[[ -d $SRC_APP && -x $SRC_CLI ]] || { echo "build failed"; exit 1; }
codesign --verify --deep --strict "$SRC_APP"

# stop a running copy so the new one is what launches next
pkill -f "Lantern.app/Contents/MacOS/Lantern" 2>/dev/null || true; sleep 0.5

mkdir -p "$APP_DIR" "$BIN_DIR"
rm -rf "$APP_DIR/Lantern.app"; ditto "$SRC_APP" "$APP_DIR/Lantern.app"
rm -f "$BIN_DIR/lantern"            # never write through an old symlink
cp "$SRC_CLI" "$BIN_DIR/lantern"; chmod 755 "$BIN_DIR/lantern"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR/Lantern.app" >/dev/null 2>&1 || true

# other copies the CLI could pick up instead
for d in /Applications "$HOME/Applications"; do
  [[ "$d" != "$APP_DIR" && -d "$d/Lantern.app" ]] && echo "WARNING: another $d/Lantern.app exists and may shadow this install"
done

# smoke test: isolated data dir, no window on screen, nothing of yours touched
T=$(mktemp -d /tmp/lantern-smoke.XXXX); printf '# Smoke\n\n- [x] installed\n' > "$T/p.md"
export LANTERN_HOME="$T/home" LANTERN_TEST=1 LANTERN_APP="$APP_DIR/Lantern.app"
if "$BIN_DIR/lantern" open --window "$T/p.md" >/dev/null && sleep 1 && "$BIN_DIR/lantern" list | grep -q p.md; then OK=1; else OK=0; fi
"$BIN_DIR/lantern" close >/dev/null 2>&1 || true; pkill -f "$APP_DIR/Lantern.app/Contents/MacOS/Lantern" 2>/dev/null || true; rm -rf "$T"
[[ $OK == 1 ]] || { echo "SMOKE TEST FAILED: installed app did not open a plan"; exit 1; }

echo "Installed $APP_DIR/Lantern.app and $BIN_DIR/lantern (smoke test passed)"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "Note: add $BIN_DIR to your PATH";; esac
echo "Let Claude drive the viewer:  claude mcp add --scope user lantern -- $BIN_DIR/lantern mcp"
