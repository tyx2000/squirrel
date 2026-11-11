#!/usr/bin/env bash
# Purpose: Builds the macOS Release app, checks it is a plain release build, and optionally
# installs it or packages a disk image.
#
#   scripts/build-macos.sh            build/macos/Space.app
#   scripts/build-macos.sh install    also replace /Applications/Space.app and relaunch it
#   scripts/build-macos.sh dmg        also write dist/Space-<version>-macos-<stamp>.dmg
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

derived="$root/build/DerivedData"
out="$root/build/macos"
app="$out/Space.app"
bundle_id="onmyown.Squirrel"

echo "==> Building Release"
# Coverage is off explicitly: a build made with Xcode's test settings carried profiling
# counters into the installed app.
xcodebuild -project Space.xcodeproj -scheme Space -configuration Release \
    -derivedDataPath "$derived" \
    CLANG_COVERAGE_MAPPING=NO CLANG_ENABLE_CODE_COVERAGE=NO \
    build -quiet

rm -rf "$out"
mkdir -p "$out"
ditto "$derived/Build/Products/Release/Space.app" "$app"

binary="$app/Contents/MacOS/Space"
if otool -l "$binary" | grep -q "__llvm_covmap\|__llvm_prf_cnts"; then
    echo "error: $binary contains coverage instrumentation" >&2
    exit 1
fi
echo "    $app ($(du -sh "$app" | cut -f1))"

case "${1:-}" in
install)
    echo "==> Installing to /Applications"
    if pgrep -x Space >/dev/null; then
        osascript -e "quit app id \"$bundle_id\"" >/dev/null 2>&1 || true
        for _ in $(seq 1 50); do pgrep -x Space >/dev/null || break; sleep 0.1; done
        pkill -x Space 2>/dev/null || true
    fi
    rm -rf /Applications/Space.app
    ditto "$app" /Applications/Space.app
    open /Applications/Space.app
    echo "    /Applications/Space.app"
    ;;
dmg)
    echo "==> Packaging disk image"
    version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
    mkdir -p "$root/dist"
    image="$root/dist/Space-$version-macos-$(date +%Y%m%d-%H%M).dmg"
    staging="$(mktemp -d)"
    ditto "$app" "$staging/Space.app"
    ln -s /Applications "$staging/Applications"
    hdiutil create -quiet -volname Space -srcfolder "$staging" -format UDZO "$image"
    rm -rf "$staging"
    echo "    $image"
    ;;
"") ;;
*)
    echo "usage: $0 [install|dmg]" >&2
    exit 2
    ;;
esac
