#!/usr/bin/env bash
# Purpose: Builds res/space.ico from the macOS app icon PNGs, using only sips and python3
# so it runs on a stock Mac. Small sizes are stored as 32-bit DIBs, which every icon
# consumer reads (NSIS included); 256px is stored as PNG, as Windows expects.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$here/../Space/Assets.xcassets/AppIcon.appiconset"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pick_source() {
    case "$1" in
        16) echo "$source_dir/AppIcon-16.png" ;;
        20|24|32) echo "$source_dir/AppIcon-32.png" ;;
        40|48|64) echo "$source_dir/AppIcon-64.png" ;;
        *) echo "$source_dir/AppIcon-256.png" ;;
    esac
}

for size in 16 20 24 32 40 48 64; do
    sips -z "$size" "$size" -s format bmp "$(pick_source "$size")" --out "$work/$size.bmp" >/dev/null
done
cp "$source_dir/AppIcon-256.png" "$work/256.png"

python3 - "$work" "$here/res/space.ico" <<'PY'
import struct, sys

work, out = sys.argv[1], sys.argv[2]

def dib_entry(path):
    data = open(path, "rb").read()
    offset = struct.unpack_from("<I", data, 10)[0]
    header_size = struct.unpack_from("<I", data, 14)[0]
    width, height, _, bpp, compression = struct.unpack_from("<iiHHI", data, 18)
    assert bpp == 32, path
    masks = struct.unpack_from("<IIII", data, 54) if compression == 3 else (0xFF0000, 0xFF00, 0xFF, 0xFF000000)
    top_down = height < 0
    height = abs(height)
    pixels = data[offset:offset + width * height * 4]

    def channel(value, mask):
        if mask == 0:
            return 255
        shift = (mask & -mask).bit_length() - 1
        return (value & mask) >> shift

    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            value = struct.unpack_from("<I", pixels, (y * width + x) * 4)[0]
            r, g, b, a = (channel(value, m) for m in masks)
            row += bytes((b, g, r, a))
        rows.append(bytes(row))
    if top_down:
        rows.reverse()  # ICO DIBs are bottom-up.

    and_stride = ((width + 31) // 32) * 4
    header = struct.pack("<IiiHHIIiiII", 40, width, height * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    return width, header + b"".join(rows) + b"\0" * (and_stride * height)

entries = [dib_entry(f"{work}/{s}.bmp") for s in (16, 20, 24, 32, 40, 48, 64)]
entries.append((256, open(f"{work}/256.png", "rb").read()))

directory = struct.pack("<HHH", 0, 1, len(entries))
offset = 6 + 16 * len(entries)
blobs = b""
for size, blob in entries:
    directory += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(blob), offset)
    offset += len(blob)
    blobs += blob
open(out, "wb").write(directory + blobs)
print(f"wrote {out} ({len(entries)} sizes)")
PY
