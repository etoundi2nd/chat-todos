#!/usr/bin/env bash
# Builds build/Chat Todos.app.
# Signing: SIGN_IDENTITY if set, else the "Chat Todos Local Signing" certificate from
# scripts/create-signing-cert.sh if present, else ad-hoc. Only a stable certificate keeps
# the Accessibility permission across rebuilds.
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

LOCAL_IDENTITY="Chat Todos Local Signing"
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-certificate -c "$LOCAL_IDENTITY" >/dev/null 2>&1; then
  SIGN_IDENTITY="$LOCAL_IDENTITY"
fi
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  echo "warning: ad-hoc signing; macOS will forget the Accessibility permission on every rebuild." >&2
  echo "         Run scripts/create-signing-cert.sh once to fix that." >&2
fi
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
