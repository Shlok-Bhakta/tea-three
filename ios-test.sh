#!/usr/bin/env bash
# Gala Engine gate: TeaThreeKit unit and recorded-contract tests, then a launch
# check: the app must start in the simulator and still be running 10 s later.
# (Code review and unit tests can't catch a crash on launch.)
set -euo pipefail

: "${GALA_BUILD_DIR:?Gala build directory is required}"
ROOT="$(pwd)"
(cd Packages/TeaThreeKit && swift test --scratch-path "$GALA_BUILD_DIR/KitTests")

command -v xcodegen >/dev/null && xcodegen generate >/dev/null
xcodebuild -project TeaThree.xcodeproj -scheme TeaThree -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$GALA_BUILD_DIR/LaunchCheck" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build -quiet
APP="$GALA_BUILD_DIR/LaunchCheck/Build/Products/Debug-iphonesimulator/TeaThree.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

DEVICE="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = [d for runtime in json.load(sys.stdin)["devices"].values() for d in runtime if d["name"].startswith("iPhone")]
booted = [d for d in devices if d["state"] == "Booted"]
print((booted or devices)[0]["udid"])')"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"

LOG="$GALA_BUILD_DIR/launch-check.log"
xcrun simctl launch --console-pty "$DEVICE" "$BUNDLE_ID" >"$LOG" 2>&1 &
sleep 10
if grep -q "Terminating app\|uncaught exception\|Fatal error" "$LOG" \
   || ! xcrun simctl spawn "$DEVICE" launchctl list | grep -q "$BUNDLE_ID"; then
  echo "Launch check failed: the app didn't stay running." >&2
  tail -20 "$LOG" >&2
  exit 1
fi
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
echo "Launch check passed"
cd "$ROOT"
