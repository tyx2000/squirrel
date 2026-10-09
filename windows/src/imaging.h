// Purpose: Windows Imaging Component helpers for reading, scaling and writing images, plus
// the DIB conversions the clipboard needs and SHA-256 fingerprints.

#pragma once

#include "common.h"

#include <wincodec.h>

namespace space::imaging {

// 32-bit BGRA pixels, top-down, stride width * 4.
struct Bitmap {
    UINT width = 0;
    UINT height = 0;
    std::vector<uint8_t> pixels;
    bool premultiplied = false;
};

enum class EncodedFormat { Png, Jpeg, Other };

// A factory for the calling thread; WIC objects stay on the thread that made them.
IWICImagingFactory* Factory();

EncodedFormat DetectFormat(const void* data, size_t size);
bool ImageSize(const void* data, size_t size, UINT& width, UINT& height);
bool ImageFileSize(const std::wstring& path, UINT& width, UINT& height);

// Decodes to premultiplied BGRA, scaled down (never up) to fit maxWidth x maxHeight.
std::optional<Bitmap> DecodeFileFitting(const std::wstring& path, UINT maxWidth, UINT maxHeight);
// Decodes to straight-alpha BGRA at full size.
std::optional<Bitmap> DecodeMemory(const void* data, size_t size);

// PNG bytes. An opaque image is written without its alpha plane, which only makes the
// file bigger.
std::optional<std::vector<uint8_t>> EncodePng(const Bitmap& bitmap);

// A clipboard CF_DIB/CF_DIBV5 payload re-encoded as PNG.
std::optional<std::vector<uint8_t>> DibToPng(const void* dib, size_t size, UINT& width, UINT& height);
// A packed CF_DIB payload: BITMAPINFOHEADER and bottom-up 32-bit rows.
std::vector<uint8_t> MakeDib(const Bitmap& bitmap);

std::wstring Sha256Hex(const void* data, size_t size);

}  // namespace space::imaging
