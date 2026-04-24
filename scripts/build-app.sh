#!/usr/bin/env bash
# Build a proper Laksh.app bundle from the swift-build output.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
if [[ "$CONFIG" == "release" ]]; then
    swift build -c release
    BIN=".build/release/Laksh"
else
    swift build
    BIN=".build/debug/Laksh"
fi

APP="build/Laksh.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Laksh"
chmod +x "$APP/Contents/MacOS/Laksh"

# Compile Metal shaders
echo "Compiling Metal shaders..."
SHADER_DIR="Sources/Laksh/Terminal"
if [[ -f "$SHADER_DIR/TerminalRenderer.metal" ]]; then
    xcrun metal -c "$SHADER_DIR/TerminalRenderer.metal" -o "$APP/Contents/Resources/TerminalRenderer.air" 2>/dev/null || true
    if [[ -f "$APP/Contents/Resources/TerminalRenderer.air" ]]; then
        xcrun metallib "$APP/Contents/Resources/TerminalRenderer.air" -o "$APP/Contents/Resources/default.metallib"
        rm "$APP/Contents/Resources/TerminalRenderer.air"
        echo "Metal shaders compiled."
    fi
fi

# Icon
bash scripts/make-icon.sh
cp build/Laksh.icns "$APP/Contents/Resources/Laksh.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>             <string>Laksh</string>
  <key>CFBundleDisplayName</key>      <string>Laksh</string>
  <key>CFBundleIdentifier</key>       <string>dev.abhay.laksh</string>
  <key>CFBundleVersion</key>          <string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key>       <string>Laksh</string>
  <key>CFBundleIconFile</key>         <string>Laksh</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>LSMinimumSystemVersion</key>   <string>14.0</string>
  <key>NSHighResolutionCapable</key>  <true/>
  <key>NSPrincipalClass</key>         <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Built $APP"
echo "Run: open $APP"
