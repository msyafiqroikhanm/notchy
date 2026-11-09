#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
VERSION=1.0.0
APP="dist/Notchy.app"
build() {
  command -v cmake >/dev/null || { echo 'CMake required: brew install cmake' >&2; exit 1; }
  cmake -S Vendor/mediaremote-adapter -B .build/mediaremote -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
  cmake --build .build/mediaremote --config Release --parallel
  swift build -c release
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp .build/release/Notchy "$APP/Contents/MacOS/Notchy"
  cp Resources/Info.plist "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  ditto .build/mediaremote/MediaRemoteAdapter.framework "$APP/Contents/Resources/MediaRemoteAdapter.framework"
  cp .build/mediaremote/MediaRemoteAdapterTestClient "$APP/Contents/Resources/"
  cp Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$APP/Contents/Resources/"
  cp Vendor/mediaremote-adapter/LICENSE "$APP/Contents/Resources/mediaremote-adapter-LICENSE"
  codesign --force --sign - "$APP/Contents/Resources/MediaRemoteAdapter.framework"
  codesign --force --sign - "$APP/Contents/Resources/MediaRemoteAdapterTestClient"
  codesign --force --sign - --identifier com.notchy.app "$APP"
  echo "Built $APP"
}
case "${1:-build}" in
  build) build ;;
  run) build; open "$APP" ;;
  selftest) build; "$APP/Contents/MacOS/Notchy" --selftest ;;
  dmg)
    build
    stage=$(mktemp -d "${TMPDIR:-/tmp}/notchy-dmg.XXXXXX")
    trap 'rm -rf "$stage"' EXIT
    ditto "$APP" "$stage/Notchy.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create -ov -volname Notchy -srcfolder "$stage" -format UDZO dist/Notchy.dmg
    ;;
  *) echo 'Usage: ./build.sh {build|run|selftest|dmg}' >&2; exit 2 ;;
esac
