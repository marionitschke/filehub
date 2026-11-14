#!/bin/bash
# Builds a check build (with Tests/Snapshot.swift) and saves images of the windows.
# Demo data, no network, no keychain, changes nothing.
#
#   scripts/snapshot.sh [target folder]   → default: build/snapshot/
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/snapshot}"
./build.sh >/dev/null

FLAGS=(-O -swift-version 5 -parse-as-library -D SNAPSHOT -target "$(uname -m)-apple-macos14.0")
[[ -f build/clt-overlay.yaml ]] && FLAGS+=(-vfsoverlay build/clt-overlay.yaml -Xcc -ivfsoverlay -Xcc build/clt-overlay.yaml)
swiftc "${FLAGS[@]}" -module-name FileHub -o build/FileHubSnapshot Sources/FileHub/*.swift Tests/Snapshot.swift

APP="build/FileHubSnapshot.app"
rm -rf "$APP"
cp -R build/FileHub.app "$APP"
cp build/FileHubSnapshot "$APP/Contents/MacOS/FileHub"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.filehub.snapshot" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null

rm -rf "$OUT"
mkdir -p "$OUT"
FILEHUB_SNAPSHOT="$(cd "$OUT" && pwd)" "$APP/Contents/MacOS/FileHub"
echo "Bilder: $OUT"
