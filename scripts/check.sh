#!/bin/bash
# Builds and runs the checks (Tests/Checks.swift). Never touches a real server.
#
#   scripts/check.sh            → rules, listings, paths, encryption, askpass bridge
#   scripts/check.sh --server   → also against the Docker test server (started if needed)
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
./build.sh --overlay-only >/dev/null
FLAGS=(-O -swift-version 5 -parse-as-library -D CHECKS -target "$(uname -m)-apple-macos14.0")
[[ -f build/clt-overlay.yaml ]] && FLAGS+=(-vfsoverlay build/clt-overlay.yaml -Xcc -ivfsoverlay -Xcc build/clt-overlay.yaml)
swiftc "${FLAGS[@]}" -module-name FileHub -o build/filehub-checks Sources/FileHub/*.swift Tests/Checks.swift Tests/Integration.swift
codesign --force --sign - build/filehub-checks 2>/dev/null

if [[ "${1:-}" == "--server" ]]; then
  nc -z 127.0.0.1 2222 2>/dev/null || scripts/testserver.sh
fi

export FILEHUB_SUPPORT_DIR="$PWD/build/test/support"
export FILEHUB_TEST_CA="$PWD/build/test/ca.pem"
mkdir -p "$FILEHUB_SUPPORT_DIR"
build/filehub-checks "$@"
