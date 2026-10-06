#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release
APP="$ROOT/Replyline.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClientReplyCompanion "$APP/Contents/MacOS/ClientReplyCompanion"
cp AppInfo.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
