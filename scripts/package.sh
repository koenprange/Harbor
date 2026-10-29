#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/harbor-package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Harbor.app"
mkdir -p "$STAGE"
HARBOR_APP_PATH="$APP" bash scripts/build.sh --standalone
ln -sfn /Applications "$STAGE/Applications"
DMG="Harbor-$VERSION-arm64.dmg"
SOURCES="Harbor-$VERSION-engine-sources.tar.gz"
hdiutil create -volname Harbor -srcfolder "$STAGE" -format UDZO -ov "dist/$DMG"
COPYFILE_DISABLE=1 tar -czf "dist/$SOURCES" -C dist engine-sources
(cd dist && shasum -a 256 "$DMG" "$SOURCES" > "Harbor-$VERSION-SHA256SUMS.txt")
printf 'Created dist/%s and corresponding sources dist/%s\n' "$DMG" "$SOURCES"
printf 'This build is not notarized. Do not describe it as a signed public release.\n'
