#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --build-system native --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product Harbor
APP="${HARBOR_APP_PATH:-$PWD/dist/Harbor.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Harbor "$APP/Contents/MacOS/Harbor"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
swift scripts/icon.swift "$PWD/dist/Harbor.iconset" "$APP/Contents/Resources/Harbor.icns"
xattr -cr "$APP"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
