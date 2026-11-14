#!/bin/bash
# Packs the source into build/FileHub-<version>.zip for a Mac without access to the repo.
# Unpack there and run ./build.sh --install in the filehub folder (needs Command Line Tools).
# Contains no credentials: connections move via "Verbindungen exportieren …".
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
NAME="FileHub-$VERSION"
STAGE="build/pack/$NAME"

rm -rf build/pack
mkdir -p "$STAGE/filehub"
rsync -a --exclude /build --exclude /.git --exclude .DS_Store --exclude '*.filehub' --exclude CLAUDE.md ./ "$STAGE/filehub/"

rm -f "build/$NAME.zip"
ditto -c -k --keepParent "$STAGE" "build/$NAME.zip"
rm -rf build/pack
echo "Fertig: build/$NAME.zip"
