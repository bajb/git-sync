#!/bin/sh
# Builds build/GitSync.app. Pass "run" to launch it afterwards.
set -eu
cd "$(dirname "$0")"

swift build -c release

APP="build/GitSync.app"
mkdir -p "$APP/Contents/MacOS"
cp -f .build/release/GitSync "$APP/Contents/MacOS/GitSync"
cp -f Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "run" ]; then
    open "$APP"
fi
