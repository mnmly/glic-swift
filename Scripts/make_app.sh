#!/bin/bash
# Build GlicStudio and assemble a proper .app bundle so macOS camera access
# (NSCameraUsageDescription) works. Run, then `open GlicStudio.app`.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building GlicStudio (release)…"
swift build -c release --product GlicStudio

APP="GlicStudio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/GlicStudio" "$APP/Contents/MacOS/GlicStudio"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>GlicStudio</string>
    <key>CFBundleIdentifier</key><string>com.mnmly.glicstudio</string>
    <key>CFBundleName</key><string>GLIC Studio</string>
    <key>CFBundleDisplayName</key><string>GLIC Studio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSCameraUsageDescription</key>
    <string>GLIC Studio glitches your camera feed in real time.</string>
</dict>
</plist>
PLIST

# Ad-hoc codesign so TCC can attribute the camera grant to a stable identity.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "warning: ad-hoc codesign failed (camera permission may re-prompt)"

echo "Built $APP"
echo "Run it with:  open $APP"
