#!/bin/zsh
# Builds LocalFlow.app from the SwiftPM package with xcodebuild (needed so MLX's Metal shaders get compiled;
# plain `swift build` cannot do that). Requires Xcode + the Metal Toolchain component.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="com.gaelen.localflow"
APP="build/LocalFlow.app"
DERIVED="build/DerivedData"

xcodebuild -scheme LocalFlow -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  -skipMacroValidation -skipPackagePluginValidation \
  build | grep -E "error:|warning: .*LocalFlow|BUILD (SUCCEEDED|FAILED)" || true

PRODUCTS="$DERIVED/Build/Products/Release"
[[ -x "$PRODUCTS/LocalFlow" ]] || { echo "Build failed: no executable at $PRODUCTS/LocalFlow"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/LocalFlow" "$APP/Contents/MacOS/LocalFlow"

# SwiftPM resource bundles (MLX's compiled Metal library lives in one of these).
for b in "$PRODUCTS"/*.bundle(N); do
  cp -R "$b" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>LocalFlow</string>
  <key>CFBundleExecutable</key><string>LocalFlow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>LocalFlow tells Spotify to play a song when you say a music phrase.</string>
  <key>NSMicrophoneUsageDescription</key><string>LocalFlow records your voice on-device to transcribe it. Audio never leaves this Mac.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign, but pin the designated requirement to the bundle id. macOS privacy permissions
# (Accessibility, Input Monitoring, Microphone) then survive rebuilds instead of resetting each time.
codesign --force --deep --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP"

echo "Built $APP"
ls "$APP/Contents/Resources"
