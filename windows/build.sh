#!/usr/bin/env bash
# Purpose: Cross-compiles Space for Windows x64 with MinGW-w64 and packages it with NSIS.
#
#   ./build.sh            build/Space.exe and ../dist/Space-<version>-windows-x64-<stamp>-setup.exe
#   ./build.sh exe        build/Space.exe only
#
# Needs x86_64-w64-mingw32-g++/windres (Homebrew: mingw-w64) and makensis (Homebrew: makensis).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

version="1.0.0"
short_version="1.0"
target="${TARGET:-x86_64-w64-mingw32}"
cxx="${CXX:-$target-g++}"
windres="${WINDRES:-$target-windres}"
jobs="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"

build="$here/build"
obj="$build/obj"
mkdir -p "$obj"

cxxflags=(
    -std=c++20 -O2 -g0
    -Wall -Wextra -Wno-missing-field-initializers
    -municode -mwindows
    -DUNICODE -D_UNICODE -DNOMINMAX -DWIN32_LEAN_AND_MEAN
    -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -DNTDDI_VERSION=0x0A000007
    -Ires
)
libs=(
    -ld2d1 -ldwrite -lwindowscodecs -ld3d11 -ldxgi -ldwmapi
    -lmfuuid -lole32 -loleaut32 -luuid -lruntimeobject
    -lcomctl32 -lshell32 -lshcore -lbcrypt -lversion -ladvapi32 -luser32 -lgdi32
)

echo "==> Compiling resources"
"$windres" -I res -O coff \
    -DSPACE_VERSION_STRING="\\\"$version.0\\\"" -DSPACE_VERSION_COMMAS="${version//./,},0" \
    -i res/space.rc -o "$obj/space.res.o"

echo "==> Compiling sources"
pids=()
for source in src/*.cpp; do
    name="$(basename "$source" .cpp)"
    "$cxx" "${cxxflags[@]}" -c "$source" -o "$obj/$name.o" &
    pids+=($!)
    if (( ${#pids[@]} >= jobs )); then
        wait "${pids[0]}"
        pids=("${pids[@]:1}")
    fi
done
for pid in "${pids[@]}"; do wait "$pid"; done

echo "==> Linking"
"$cxx" -municode -mwindows -static -static-libgcc -static-libstdc++ -s \
    "$obj"/*.o -o "$build/Space.exe" "${libs[@]}"
echo "    $build/Space.exe ($(du -h "$build/Space.exe" | cut -f1))"

if [[ "${1:-}" == "exe" ]]; then
    exit 0
fi

echo "==> Packaging installer"
dist="$(cd "$here/.." && pwd)/dist"
mkdir -p "$dist"
stamp="$(date +%Y%m%d-%H%M)"
installer="$dist/Space-$short_version-windows-x64-$stamp-setup.exe"
# makensis crashes building its language tables under the C locale, which is what a shell
# without LANG gets.
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 makensis -V2 -INPUTCHARSET UTF8 \
    -DVERSION="$version" \
    -DSOURCE_DIR="$build" \
    -DICON="$here/res/space.ico" \
    -DOUTFILE="$installer" \
    installer/space.nsi
echo "    $installer ($(du -h "$installer" | cut -f1))"
