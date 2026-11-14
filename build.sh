#!/bin/bash
# Builds FileHub.app with the Command Line Tools only, no Xcode and no developer certificate.
#
#   ./build.sh            → build/FileHub.app
#   ./build.sh --install  → also copy to /Applications/StudioHub (with the other Hub apps)
#   ./build.sh --icon     → redraw the app icon (Resources/AppIcon.icns)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/FileHub.app"
mkdir -p build

FLAGS=(-O -swift-version 5 -target "$(uname -m)-apple-macos14.0")

# Some Command Line Tools installs ship an outdated module.modulemap that collides with
# bridging.modulemap ("redefinition of module 'SwiftBridging'"). It is hidden via a VFS overlay
# during compilation; nothing on the system is changed.
SWIFT_INCLUDE="$(dirname "$(dirname "$(xcrun -f swiftc)")")/include/swift"
rm -f build/clt-overlay.yaml
if [[ -f "$SWIFT_INCLUDE/module.modulemap" && -f "$SWIFT_INCLUDE/bridging.modulemap" ]]; then
  : > build/empty.modulemap
  cat > build/clt-overlay.yaml <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "name": "$SWIFT_INCLUDE", "type": "directory",
  "contents": [ { "name": "module.modulemap", "type": "file", "external-contents": "$PWD/build/empty.modulemap" } ] } ] }
EOF
  FLAGS+=(-vfsoverlay build/clt-overlay.yaml -Xcc -ivfsoverlay -Xcc build/clt-overlay.yaml)
fi

[[ "${1:-}" == "--overlay-only" ]] && exit 0

if [[ "${1:-}" == "--icon" ]]; then
  swiftc "${FLAGS[@]}" -o build/make-icon scripts/make-icon.swift
  rm -rf build/AppIcon.iconset
  build/make-icon build/AppIcon.iconset
  mkdir -p Resources
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
  echo "Icon aktualisiert: Resources/AppIcon.icns"
  exit 0
fi

echo "Kompiliere …"
swiftc "${FLAGS[@]}" -parse-as-library -module-name FileHub -o build/FileHub Sources/FileHub/*.swift

echo "Erstelle $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/FileHub "$APP/Contents/MacOS/FileHub"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad hoc signature ("-") with Hardened Runtime: needs no certificate or Apple account, but
# prevents injecting foreign libraries into the running app.
codesign --force --options runtime --sign - "$APP"
# Verify signature and Hardened Runtime: no install without both.
codesign --verify --strict "$APP"
[[ "$(codesign -dv "$APP" 2>&1)" == *"flags="*"runtime"* ]] || { echo "Hardened Runtime fehlt in der Signatur." >&2; exit 1; }

if [[ "${1:-}" == "--install" ]]; then
  if pgrep -xq FileHub; then
    echo "FileHub läuft noch – bitte beenden und erneut ausführen." >&2
    exit 1
  fi
  mkdir -p /Applications/StudioHub
  rm -rf /Applications/StudioHub/FileHub.app
  cp -R "$APP" /Applications/StudioHub/
  echo "Installiert: /Applications/StudioHub/FileHub.app"
fi

echo "Fertig: $APP"
