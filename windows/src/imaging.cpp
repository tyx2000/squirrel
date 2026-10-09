// Purpose: Implements the WIC, DIB and hashing helpers declared in imaging.h.

#include "imaging.h"

#include <bcrypt.h>

#include <algorithm>
#include <cstring>

namespace space::imaging {

IWICImagingFactory* Factory() {
    thread_local ComPtr<IWICImagingFactory> factory;
    if (!factory) {
        CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
    }
    return factory.Get();
}

EncodedFormat DetectFormat(const void* data, size_t size) {
    const auto* bytes = static_cast<const uint8_t*>(data);
    static const uint8_t kPng[] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    if (size >= sizeof(kPng) && std::memcmp(bytes, kPng, sizeof(kPng)) == 0) return EncodedFormat::Png;
    if (size >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return EncodedFormat::Jpeg;
    return EncodedFormat::Other;
}

namespace {

ComPtr<IWICBitmapFrameDecode> FirstFrameFromMemory(const void* data, size_t size, ComPtr<IWICStream>& stream) {
    IWICImagingFactory* factory = Factory();
    if (!factory || size == 0 || size > MAXDWORD) return nullptr;

    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(factory->CreateStream(&stream)) ||
        FAILED(stream->InitializeFromMemory(static_cast<BYTE*>(const_cast<void*>(data)), static_cast<DWORD>(size))) ||
        FAILED(factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder)) ||
        FAILED(decoder->GetFrame(0, &frame))) {
        return nullptr;
    }
    return frame;
}

std::optional<Bitmap> CopyConverted(IWICBitmapSource* source, REFWICPixelFormatGUID format, bool premultiplied) {
    IWICImagingFactory* factory = Factory();
    ComPtr<IWICFormatConverter> converter;
    if (!factory || FAILED(factory->CreateFormatConverter(&converter)) ||
        FAILED(converter->Initialize(source, format, WICBitmapDitherTypeNone, nullptr, 0.0,
                                     WICBitmapPaletteTypeMedianCut))) {
        return std::nullopt;
    }

    Bitmap bitmap;
    if (FAILED(converter->GetSize(&bitmap.width, &bitmap.height)) || bitmap.width == 0 || bitmap.height == 0) {
        return std::nullopt;
    }
    uint64_t byteCount = static_cast<uint64_t>(bitmap.width) * bitmap.height * 4;
    if (byteCount > 0x7FFFFFFF) return std::nullopt;
    bitmap.pixels.resize(static_cast<size_t>(byteCount));
    bitmap.premultiplied = premultiplied;
    if (FAILED(converter->CopyPixels(nullptr, bitmap.width * 4, static_cast<UINT>(byteCount), bitmap.pixels.data()))) {
        return std::nullopt;
    }
    return bitmap;
}

}  // namespace

bool ImageSize(const void* data, size_t size, UINT& width, UINT& height) {
    ComPtr<IWICStream> stream;
    auto frame = FirstFrameFromMemory(data, size, stream);
    return frame && SUCCEEDED(frame->GetSize(&width, &height));
}

bool ImageFileSize(const std::wstring& path, UINT& width, UINT& height) {
    IWICImagingFactory* factory = Factory();
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    return factory &&
           SUCCEEDED(factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
                                                        WICDecodeMetadataCacheOnDemand, &decoder)) &&
           SUCCEEDED(decoder->GetFrame(0, &frame)) && SUCCEEDED(frame->GetSize(&width, &height));
}

std::optional<Bitmap> DecodeFileFitting(const std::wstring& path, UINT maxWidth, UINT maxHeight) {
    IWICImagingFactory* factory = Factory();
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    UINT width = 0, height = 0;
    if (!factory ||
        FAILED(factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand,
                                                  &decoder)) ||
        FAILED(decoder->GetFrame(0, &frame)) || FAILED(frame->GetSize(&width, &height)) || width == 0 ||
        height == 0) {
        return std::nullopt;
    }

    double scale = std::min({1.0, static_cast<double>(maxWidth) / width, static_cast<double>(maxHeight) / height});
    ComPtr<IWICBitmapSource> source = frame;
    if (scale < 1.0) {
        UINT targetWidth = std::max<UINT>(1, static_cast<UINT>(width * scale + 0.5));
        UINT targetHeight = std::max<UINT>(1, static_cast<UINT>(height * scale + 0.5));
        ComPtr<IWICBitmapScaler> scaler;
        if (SUCCEEDED(factory->CreateBitmapScaler(&scaler)) &&
            SUCCEEDED(scaler->Initialize(frame.Get(), targetWidth, targetHeight, WICBitmapInterpolationModeFant))) {
            source = scaler;
        }
    }
    return CopyConverted(source.Get(), GUID_WICPixelFormat32bppPBGRA, true);
}

std::optional<Bitmap> DecodeMemory(const void* data, size_t size) {
    ComPtr<IWICStream> stream;
    auto frame = FirstFrameFromMemory(data, size, stream);
    if (!frame) return std::nullopt;
    return CopyConverted(frame.Get(), GUID_WICPixelFormat32bppBGRA, false);
}

std::optional<std::vector<uint8_t>> EncodePng(const Bitmap& bitmap) {
    IWICImagingFactory* factory = Factory();
    if (!factory || bitmap.width == 0 || bitmap.height == 0) return std::nullopt;

    bool opaque = true;
    for (size_t i = 3; i < bitmap.pixels.size(); i += 4) {
        if (bitmap.pixels[i] != 0xFF) {
            opaque = false;
            break;
        }
    }

    // Straight alpha is what PNG stores; undo premultiplication for translucent pixels.
    std::vector<uint8_t> rows;
    UINT stride = 0;
    WICPixelFormatGUID format{};
    if (opaque) {
        format = GUID_WICPixelFormat24bppBGR;
        stride = bitmap.width * 3;
        rows.resize(static_cast<size_t>(stride) * bitmap.height);
        const uint8_t* source = bitmap.pixels.data();
        uint8_t* target = rows.data();
        for (size_t i = 0, count = static_cast<size_t>(bitmap.width) * bitmap.height; i < count; ++i) {
            target[0] = source[0];
            target[1] = source[1];
            target[2] = source[2];
            source += 4;
            target += 3;
        }
    } else {
        format = GUID_WICPixelFormat32bppBGRA;
        stride = bitmap.width * 4;
        rows = bitmap.pixels;
        if (bitmap.premultiplied) {
            for (size_t i = 0; i + 3 < rows.size(); i += 4) {
                uint8_t alpha = rows[i + 3];
                if (alpha == 0 || alpha == 0xFF) continue;
                for (int c = 0; c < 3; ++c) {
                    rows[i + c] = static_cast<uint8_t>(std::min(255, rows[i + c] * 255 / alpha));
                }
            }
        }
    }

    ComPtr<IStream> stream;
    ComPtr<IWICBitmapEncoder> encoder;
    ComPtr<IWICBitmapFrameEncode> frame;
    ComPtr<IPropertyBag2> options;
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream)) ||
        FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) ||
        FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache)) ||
        FAILED(encoder->CreateNewFrame(&frame, &options)) || FAILED(frame->Initialize(options.Get())) ||
        FAILED(frame->SetSize(bitmap.width, bitmap.height))) {
        return std::nullopt;
    }

    WICPixelFormatGUID accepted = format;
    if (FAILED(frame->SetPixelFormat(&accepted)) || accepted != format) return std::nullopt;
    if (FAILED(frame->WritePixels(bitmap.height, stride, static_cast<UINT>(rows.size()), rows.data())) ||
        FAILED(frame->Commit()) || FAILED(encoder->Commit())) {
        return std::nullopt;
    }

    HGLOBAL global = nullptr;
    if (FAILED(GetHGlobalFromStream(stream.Get(), &global))) return std::nullopt;
    STATSTG stat{};
    if (FAILED(stream->Stat(&stat, STATFLAG_NONAME))) return std::nullopt;

    std::vector<uint8_t> png(static_cast<size_t>(stat.cbSize.QuadPart));
    void* locked = GlobalLock(global);
    if (!locked) return std::nullopt;
    std::memcpy(png.data(), locked, png.size());
    GlobalUnlock(global);
    return png;
}

std::optional<std::vector<uint8_t>> DibToPng(const void* dib, size_t size, UINT& width, UINT& height) {
    if (size < sizeof(BITMAPINFOHEADER)) return std::nullopt;
    const auto* header = static_cast<const BITMAPINFOHEADER*>(dib);
    if (header->biSize < sizeof(BITMAPINFOHEADER) || header->biSize > size) return std::nullopt;

    // A DIB is a BMP file without its 14-byte file header; put one back so WIC's BMP
    // decoder can read it, which handles bit fields, palettes and both row orders.
    size_t pixelOffset = header->biSize;
    if (header->biSize == sizeof(BITMAPINFOHEADER) && header->biCompression == BI_BITFIELDS) pixelOffset += 12;
    if (header->biBitCount <= 8) {
        size_t colors = header->biClrUsed ? header->biClrUsed : (static_cast<size_t>(1) << header->biBitCount);
        pixelOffset += colors * sizeof(RGBQUAD);
    } else {
        pixelOffset += static_cast<size_t>(header->biClrUsed) * sizeof(RGBQUAD);
    }
    if (pixelOffset > size) return std::nullopt;

    std::vector<uint8_t> file(sizeof(BITMAPFILEHEADER) + size);
    BITMAPFILEHEADER fileHeader{};
    fileHeader.bfType = 0x4D42;  // "BM"
    fileHeader.bfSize = static_cast<DWORD>(file.size());
    fileHeader.bfOffBits = static_cast<DWORD>(sizeof(BITMAPFILEHEADER) + pixelOffset);
    std::memcpy(file.data(), &fileHeader, sizeof(fileHeader));
    std::memcpy(file.data() + sizeof(fileHeader), dib, size);

    auto bitmap = DecodeMemory(file.data(), file.size());
    if (!bitmap) return std::nullopt;

    // 32-bit DIBs usually carry no alpha at all, which reads as fully transparent.
    bool allTransparent = true;
    for (size_t i = 3; i < bitmap->pixels.size(); i += 4) {
        if (bitmap->pixels[i] != 0) {
            allTransparent = false;
            break;
        }
    }
    if (allTransparent) {
        for (size_t i = 3; i < bitmap->pixels.size(); i += 4) bitmap->pixels[i] = 0xFF;
    }

    width = bitmap->width;
    height = bitmap->height;
    return EncodePng(*bitmap);
}

std::vector<uint8_t> MakeDib(const Bitmap& bitmap) {
    BITMAPINFOHEADER header{};
    header.biSize = sizeof(header);
    header.biWidth = static_cast<LONG>(bitmap.width);
    header.biHeight = static_cast<LONG>(bitmap.height);  // positive: bottom-up rows
    header.biPlanes = 1;
    header.biBitCount = 32;
    header.biCompression = BI_RGB;
    header.biSizeImage = bitmap.width * bitmap.height * 4;

    std::vector<uint8_t> dib(sizeof(header) + header.biSizeImage);
    std::memcpy(dib.data(), &header, sizeof(header));
    size_t stride = static_cast<size_t>(bitmap.width) * 4;
    for (UINT y = 0; y < bitmap.height; ++y) {
        std::memcpy(dib.data() + sizeof(header) + (bitmap.height - 1 - y) * stride,
                    bitmap.pixels.data() + y * stride, stride);
    }
    return dib;
}

std::wstring Sha256Hex(const void* data, size_t size) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    uint8_t digest[32] = {};
    bool ok = BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0)) &&
              BCRYPT_SUCCESS(BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0));

    const auto* bytes = static_cast<const uint8_t*>(data);
    while (ok && size > 0) {
        ULONG chunk = static_cast<ULONG>(std::min<size_t>(size, 1u << 30));
        ok = BCRYPT_SUCCESS(BCryptHashData(hash, const_cast<PUCHAR>(bytes), chunk, 0));
        bytes += chunk;
        size -= chunk;
    }
    ok = ok && BCRYPT_SUCCESS(BCryptFinishHash(hash, digest, sizeof(digest), 0));

    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    if (!ok) return {};

    std::wstring hex;
    hex.reserve(64);
    for (uint8_t byte : digest) hex += FormatString(L"%02x", byte);
    return hex;
}

}  // namespace space::imaging
