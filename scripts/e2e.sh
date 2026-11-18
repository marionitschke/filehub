#!/bin/bash
# Real run of the app (check build) against the Docker test server: connect, upload and
# download through the AppModel, with its own host key and log folder and no keychain.
# Second run with an exFAT image as external drive ("FH Test SSD"): start folder on it, attach,
# upload, not enough space, unplug, eject. The drive briefly shows up in Finder.
set -euo pipefail
cd "$(dirname "$0")/.."

nc -z 127.0.0.1 2222 2>/dev/null || scripts/testserver.sh
scripts/check.sh --server >/dev/null # confirms the host key in build/test/support
scripts/snapshot.sh build/snapshot >/dev/null

FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/filehub-e2e.XXXX")
mkdir -p "$FIXTURE/site/dist"
echo '<h1>Hallo</h1>' > "$FIXTURE/site/index.html"
echo 'RewriteEngine On' > "$FIXTURE/site/.htaccess"
echo 'console.log(1)' > "$FIXTURE/site/dist/app.js"
echo x > "$FIXTURE/site/.DS_Store"
echo x > "$FIXTURE/site/dist/.DS_Store"

# Old dist on the server: must disappear on upload without a confirmation.
docker exec filehub-testserver sh -c 'rm -rf /home/filehub/site && mkdir -p /home/filehub/site/dist && echo alt > /home/filehub/site/dist/alt.js && chown -R filehub:filehub /home/filehub/site'
FILEHUB_SNAPSHOT="$PWD/build/snapshot" FILEHUB_SUPPORT_DIR="$PWD/build/test/support" \
FILEHUB_E2E_FIXTURE="$FIXTURE" FILEHUB_E2E_KEY="$PWD/build/test/id_test" \
  build/FileHubSnapshot.app/Contents/MacOS/FileHub
docker exec filehub-testserver rm -rf /home/filehub/site
rm -rf "$FIXTURE"

# External drive: small exFAT image, where extended attributes create real ._ files.
VOLNAME="FH Test SSD"
IMAGE="$PWD/build/test/e2e-ssd.dmg"
hdiutil detach -quiet "/Volumes/$VOLNAME" 2>/dev/null || true
rm -f "$IMAGE"
hdiutil create -quiet -size 8m -fs ExFAT -volname "$VOLNAME" "$IMAGE"
hdiutil attach -quiet -noverify -noautoopen "$IMAGE"
SITE="/Volumes/$VOLNAME/web/site"
mkdir -p "$SITE/dist"
echo '<h1>SSD</h1>' > "$SITE/index.html"
echo 'RewriteEngine On' > "$SITE/.htaccess"
echo 'console.log(2)' > "$SITE/dist/app.js"
echo x > "$SITE/.DS_Store"
xattr -w com.apple.metadata:kMDItemWhereFroms filehub-test "$SITE/index.html"
xattr -w com.apple.metadata:kMDItemWhereFroms filehub-test "$SITE/dist/app.js"
echo "Auf dem Image: $(ls -A "$SITE" | tr '\n' ' ')| dist: $(ls -A "$SITE/dist" | tr '\n' ' ')"
hdiutil detach -quiet "/Volumes/$VOLNAME"

docker exec filehub-testserver sh -c 'rm -rf /home/filehub/site && head -c 12000000 /dev/zero > /home/filehub/big.bin && chown filehub:filehub /home/filehub/big.bin'
FILEHUB_SNAPSHOT="$PWD/build/snapshot" FILEHUB_SUPPORT_DIR="$PWD/build/test/support" \
FILEHUB_E2E_VOLUME_IMAGE="$IMAGE" FILEHUB_E2E_VOLUME_NAME="$VOLNAME" FILEHUB_E2E_KEY="$PWD/build/test/id_test" \
  build/FileHubSnapshot.app/Contents/MacOS/FileHub
hdiutil detach -quiet "/Volumes/$VOLNAME" 2>/dev/null || true
rm -f "$IMAGE"
docker exec filehub-testserver rm -rf /home/filehub/site /home/filehub/big.bin
