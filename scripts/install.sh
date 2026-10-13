#!/usr/bin/env bash
# Builds and installs Chat Todos into /Applications, then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh
pkill -x ChatTodos 2>/dev/null || true
rm -rf "/Applications/Chat Todos.app"
cp -R "build/Chat Todos.app" /Applications/
open "/Applications/Chat Todos.app"
echo "Installed to /Applications/Chat Todos.app"
