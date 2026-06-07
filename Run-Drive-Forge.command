#!/bin/zsh
set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJ"

APP="$PROJ/dist/macOS Drive Forge.app"
MACOS="$APP/Contents/MacOS"
BIN="$PROJ/.build/release/DriveForge"

# Build the release binary if it doesn't exist yet.
[[ -f "$BIN" ]] || swift build -c release

# Assemble (or refresh) the .app bundle. dist/ is not tracked in git, so this
# recreates the bundle from scratch on a fresh clone.
mkdir -p "$MACOS"
if [[ ! -f "$APP/Contents/Info.plist" ]]; then
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DriveForge</string>
    <key>CFBundleIdentifier</key>
    <string>com.vortenia.driveforge</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>macOS Drive Forge</string>
    <key>CFBundleDisplayName</key>
    <string>macOS Drive Forge</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
fi
cp "$BIN" "$MACOS/DriveForge"

# Bundle the app icon.
mkdir -p "$APP/Contents/Resources"
cp "$PROJ/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

open "$APP"
