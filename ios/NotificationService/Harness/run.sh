#!/usr/bin/env bash
# Runs the Notification Service Extension's sync on the Mac, against a booted
# simulator's App Group data.
#
# Why this exists: `xcrun simctl push` hands a notification straight to the
# system and never starts a service extension, so without an Apple developer
# account (and a real APNs push) there is no way to watch the extension run in
# the simulator. This compiles the extension's own code -- not a copy -- into a
# Mac program against the host build of the Go core, and points it at the same
# files the extension would open. What it cannot show is the extension being
# hosted by iOS and its notification being displayed.
#
# Usage:
#   ios/NotificationService/Harness/run.sh sync            # one wake
#   ios/NotificationService/Harness/run.sh hold 5          # hold accounts 5s
#   SIMULATOR=<udid> ios/NotificationService/Harness/run.sh sync
#
# Put the app in the background first: in the foreground it holds its accounts
# and the harness reports them as such, exactly as the extension would.
set -euo pipefail

cd "$(dirname "$0")"
REPO="$(cd ../../.. && pwd)"
SIMULATOR="${SIMULATOR:-booted}"

DYLIB="$REPO/native/libfreizonecore.dylib"
if [ ! -f "$DYLIB" ]; then
  (cd "$REPO/native" && go build -buildmode=c-shared -o libfreizonecore.dylib . && rm -f libfreizonecore.h)
fi

OUT="$REPO/build/wake_harness"
mkdir -p "$OUT"
swiftc -O -import-objc-header ../FreizoneCore.h \
  ../NotificationService.swift ../../Runner/SharedStorage.swift main.swift \
  -L "$REPO/native" -lfreizonecore -o "$OUT/harness"
# The host core's install name is bare; point the harness at it directly.
install_name_tool -change libfreizonecore.dylib "$DYLIB" "$OUT/harness" 2>/dev/null
codesign -s - -f "$OUT/harness" 2>/dev/null

GROUP="$(xcrun simctl get_app_container "$SIMULATOR" de.behringer24.freizone groups \
  | awk '$1 == "group.de.behringer24.freizone" { print $2 }')"
if [ -z "$GROUP" ]; then
  echo "no App Group container for Freizone on simulator '$SIMULATOR'" >&2
  echo "(with several simulators booted, name one: SIMULATOR=<udid>)" >&2
  exit 1
fi

"$OUT/harness" "$GROUP/Freizone" "$@"
