#!/usr/bin/env bash
# Optional: build, install, and launch on the first connected iPhone without opening Xcode.
# Xcode's Cmd-R does the same thing with a nicer signing UI; this is for quick CLI rebuilds.
#   ./ios/run-on-device.sh
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f CitrusSquad.xcodeproj/project.pbxproj ]; then
  echo "No project yet. Run ./setup.sh first."
  exit 1
fi

UDID=$(xcrun xctrace list devices 2>/dev/null \
  | grep -i iphone | grep -v Simulator \
  | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}' | head -1)

if [ -z "${UDID:-}" ]; then
  echo "No connected iPhone found. Plug it in, unlock it, and trust this Mac."
  exit 1
fi
echo "Building for device $UDID…"

xcodebuild -project CitrusSquad.xcodeproj -scheme CitrusSquad \
  -destination "id=$UDID" -configuration Debug \
  -derivedDataPath ./build -allowProvisioningUpdates build

APP="./build/Build/Products/Debug-iphoneos/CitrusSquad.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")

echo "Installing…"
xcrun devicectl device install app --device "$UDID" "$APP"
echo "Launching $BUNDLE_ID…"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" || \
  echo "Install succeeded; launch was blocked (unlock the phone and tap the app icon)."
