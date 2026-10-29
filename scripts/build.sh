#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE_ENGINE=0
if [[ "${1:-}" == "--standalone" ]]; then BUNDLE_ENGINE=1
elif [[ -n "${1:-}" ]]; then printf 'Usage: build.sh [--standalone]\n' >&2; exit 1; fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --build-system native --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product Harbor
APP="${HARBOR_APP_PATH:-$PWD/dist/Harbor.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Harbor "$APP/Contents/MacOS/Harbor"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
swift scripts/icon.swift "$PWD/dist/Harbor.iconset" "$APP/Contents/Resources/Harbor.icns"
if [[ "$BUNDLE_ENGINE" == 1 ]]; then python3 scripts/bundle-engine.py "$APP"; fi
xattr -cr "$APP"
IDENTITY="${HARBOR_SIGN_IDENTITY:--}"
SIGN_FLAGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then SIGN_FLAGS+=(--options runtime --timestamp); fi
if [[ -d "$APP/Contents/Frameworks" ]]; then
  for library in "$APP"/Contents/Frameworks/*.dylib; do codesign "${SIGN_FLAGS[@]}" "$library"; done
fi
if [[ -f "$APP/Contents/Helpers/transmission-daemon" ]]; then
  codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Helpers/transmission-daemon"
fi
# File providers may attach Finder metadata while nested code is signed.
for attempt in 1 2 3; do
  xattr -cr "$APP"
  if codesign "${SIGN_FLAGS[@]}" "$APP"; then
    xattr -cr "$APP"
    if codesign --verify --deep --strict "$APP"; then break; fi
  fi
  if [[ "$attempt" == 3 ]]; then exit 1; fi
done
printf 'Built: %s\n' "$APP"
