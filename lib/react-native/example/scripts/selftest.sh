#!/usr/bin/env bash
# Installs the built Debug app on a simulator, grants Photos access headlessly, launches it with
# -PicknickSelfTest. The PICKNICK_SELFTEST line appears in Metro, started with: npm start -- --client-logs
set -euo pipefail

SIM_ID="${1:-74E20555-2B42-46D2-86EB-16E498DFE7B3}"
BUNDLE_ID="org.reactjs.native.example.PicknickExample"
here="$(cd "$(dirname "$0")/.." && pwd)"
APP="$here/ios/build/Build/Products/Debug-iphonesimulator/PicknickExample.app"

xcrun simctl install "$SIM_ID" "$APP"
xcrun simctl privacy "$SIM_ID" grant photos "$BUNDLE_ID"
# simctl writes auth_version=1, which iOS treats as "not yet asked"; version 2 makes the grant stick.
TCC_DB="$HOME/Library/Developer/CoreSimulator/Devices/$SIM_ID/data/Library/TCC/TCC.db"
sqlite3 "$TCC_DB" "update access set auth_version=2 where client='$BUNDLE_ID' and service='kTCCServicePhotos'"
xcrun simctl spawn "$SIM_ID" launchctl kill TERM system/com.apple.tccd >/dev/null 2>&1 || true

xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" -PicknickSelfTest
