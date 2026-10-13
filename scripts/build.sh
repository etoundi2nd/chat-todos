#!/usr/bin/env bash
# Builds build/Chat Todos.app. Set SIGN_IDENTITY to sign with a real certificate
# (keeps the Accessibility grant across rebuilds); defaults to ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Chat Todos.app"
ICON="Resources/AppIcon.icns"

if [[ ! -f "$ICON" ]]; then
  swift scripts/make-icon.swift "$ICON"
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ChatTodos"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ChatTodos"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
