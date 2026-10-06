#!/bin/bash
# Build ObjectScan and install it on the paired iPhone. Plug the phone in (or have it on the same Wi-Fi) and unlock it first.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
cd "$(dirname "$0")"
DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /physical/ && !/unavailable/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{36}$/) {print $i; exit}}')
if [ -z "$DEVICE" ]; then
  echo "No iPhone available. Plug it in with a cable, unlock it, and tap Trust if asked. Then rerun." >&2
  exit 1
fi
xcodebuild -project ObjectScan.xcodeproj -scheme ObjectScan -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates -quiet build
xcrun devicectl device install app --device "$DEVICE" build/DerivedData/Build/Products/Debug-iphoneos/ObjectScan.app
xcrun devicectl device process launch --device "$DEVICE" com.jonahobitz.ObjectScan || \
  echo "Installed. If it won't open: Settings > General > VPN & Device Management > trust your developer profile."
