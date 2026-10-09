// Purpose: Implements the Direct2D/DirectWrite helpers and the generated tray icons.

#include "graphics.h"

#include "imaging.h"

#include <algorithm>
#include <cstring>
#include <map>
#include <tuple>

namespace space::gfx {

ID2D1Factory* D2DFactory() {
    static ComPtr<ID2D1Factory> factory = [] {
        ComPtr<ID2D1Factory> created;
        D2D1_FACTORY_OPTIONS options{};
        D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory), &options,
                          reinterpret_cast<void**>(created.GetAddressOf()));
        return created;
    }();
    return factory.Get();
}

IDWriteFactory* DWriteFactory() {
    static ComPtr<IDWriteFactory> factory = [] {
        ComPtr<IDWriteFactory> created;
        DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                            reinterpret_cast<IUnknown**>(created.GetAddressOf()));
        return created;
    }();
    return factory.Get();
}

D2D1_COLOR_F Rgb(float red, float green, float blue, float alpha) {
    return D2D1::ColorF(red, green, blue, alpha);
}

D2D1_COLOR_F WithAlpha(D2D1_COLOR_F color, float alpha) {
    color.a = alpha;
    return color;
}

D2D1_COLOR_F AccentColor() {
    static D2D1_COLOR_F accent = [] {
        DWORD value = 0;
        DWORD size = sizeof(value);
        // Stored as 0xAABBGGRR.
        if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\DWM", L"AccentColor", RRF_RT_REG_DWORD,
                         nullptr, &value, &size) == ERROR_SUCCESS) {
            return Rgb((value & 0xFF) / 255.0f, ((value >> 8) & 0xFF) / 255.0f, ((value >> 16) & 0xFF) / 255.0f);
        }
        return Rgb(0.0f, 0.404f, 0.753f);
    }();
    return accent;
}

const wchar_t* IconFamily() {
    static const wchar_t* family = [] {
        ComPtr<IDWriteFontCollection> fonts;
        UINT32 index = 0;
        BOOL exists = FALSE;
        if (DWriteFactory() && SUCCEEDED(DWriteFactory()->GetSystemFontCollection(&fonts, FALSE)) &&
            SUCCEEDED(fonts->FindFamilyName(L"Segoe Fluent Icons", &index, &exists)) && exists) {
            return L"Segoe Fluent Icons";
        }
        return L"Segoe MDL2 Assets";
    }();
    return family;
}

IDWriteTextFormat* TextFormat(float size, DWRITE_FONT_WEIGHT weight, const wchar_t* family) {
    static std::map<std::tuple<std::wstring, int, int>, ComPtr<IDWriteTextFormat>> cache;
    auto key = std::make_tuple(std::wstring(family), static_cast<int>(size * 100), static_cast<int>(weight));
    auto found = cache.find(key);
    if (found != cache.end()) return found->second.Get();

    ComPtr<IDWriteTextFormat> format;
    DWriteFactory()->CreateTextFormat(family, nullptr, weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                      size, L"", &format);
    cache[key] = format;
    return format.Get();
}

D2D1_SIZE_F MeasureText(const std::wstring& text, IDWriteTextFormat* format, float maxWidth) {
    ComPtr<IDWriteTextLayout> layout;
    if (!format || FAILED(DWriteFactory()->CreateTextLayout(text.c_str(), static_cast<UINT32>(text.size()), format,
                                                            maxWidth, 100000.0f, &layout))) {
        return D2D1::SizeF(0, 0);
    }
    layout->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    DWRITE_TEXT_METRICS metrics{};
    layout->GetMetrics(&metrics);
    return D2D1::SizeF(metrics.widthIncludingTrailingWhitespace, metrics.height);
}

Painter::Painter(ID2D1RenderTarget* target) : target_(target) {
    target_->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &brush_);
}

ID2D1SolidColorBrush* Painter::Brush(D2D1_COLOR_F color) {
    brush_->SetColor(color);
    return brush_.Get();
}

void Painter::Fill(const D2D1_RECT_F& rect, D2D1_COLOR_F color) {
    target_->FillRectangle(rect, Brush(color));
}

void Painter::FillRounded(const D2D1_RECT_F& rect, float radius, D2D1_COLOR_F color) {
    target_->FillRoundedRectangle(D2D1::RoundedRect(rect, radius, radius), Brush(color));
}

void Painter::StrokeRounded(const D2D1_RECT_F& rect, float radius, D2D1_COLOR_F color, float width) {
    // Inset by half the stroke so the line stays inside the shape, as AppKit draws it.
    D2D1_RECT_F inset = Inset(rect, width / 2, width / 2);
    target_->DrawRoundedRectangle(D2D1::RoundedRect(inset, radius, radius), Brush(color), width);
}

void Painter::Stroke(const D2D1_RECT_F& rect, D2D1_COLOR_F color, float width) {
    target_->DrawRectangle(rect, Brush(color), width);
}

void Painter::FillEllipse(D2D1_POINT_2F center, float radiusX, float radiusY, D2D1_COLOR_F color) {
    target_->FillEllipse(D2D1::Ellipse(center, radiusX, radiusY), Brush(color));
}

void Painter::Line(D2D1_POINT_2F from, D2D1_POINT_2F to, D2D1_COLOR_F color, float width) {
    target_->DrawLine(from, to, Brush(color), width);
}

void Painter::Text(const std::wstring& text, IDWriteTextFormat* format, const D2D1_RECT_F& rect, D2D1_COLOR_F color,
                   DWRITE_TEXT_ALIGNMENT alignment, DWRITE_PARAGRAPH_ALIGNMENT paragraph, bool wrap, bool trim) {
    if (text.empty() || !format) return;
    float width = std::max(0.0f, rect.right - rect.left);
    float height = std::max(0.0f, rect.bottom - rect.top);

    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(DWriteFactory()->CreateTextLayout(text.c_str(), static_cast<UINT32>(text.size()), format, width, height,
                                                 &layout))) {
        return;
    }
    layout->SetTextAlignment(alignment);
    layout->SetParagraphAlignment(paragraph);
    layout->SetWordWrapping(wrap ? DWRITE_WORD_WRAPPING_WRAP : DWRITE_WORD_WRAPPING_NO_WRAP);
    if (trim) {
        DWRITE_TRIMMING trimming{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        ComPtr<IDWriteInlineObject> ellipsis;
        DWriteFactory()->CreateEllipsisTrimmingSign(format, &ellipsis);
        layout->SetTrimming(&trimming, ellipsis.Get());
    }

    target_->PushAxisAlignedClip(rect, D2D1_ANTIALIAS_MODE_ALIASED);
    target_->DrawTextLayout(D2D1::Point2F(rect.left, rect.top), layout.Get(), Brush(color),
                            D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
    target_->PopAxisAlignedClip();
}

void Painter::Glyph(wchar_t glyph, float size, const D2D1_RECT_F& rect, D2D1_COLOR_F color) {
    wchar_t text[2] = {glyph, 0};
    Text(text, TextFormat(size, DWRITE_FONT_WEIGHT_NORMAL, IconFamily()), rect, color, DWRITE_TEXT_ALIGNMENT_CENTER,
         DWRITE_PARAGRAPH_ALIGNMENT_CENTER, false, false);
}

namespace {

// Renders with `draw` into a transparent size x size bitmap and wraps it as an icon.
HICON RenderIcon(int size, const std::function<void(ID2D1RenderTarget*)>& draw) {
    IWICImagingFactory* wic = imaging::Factory();
    ComPtr<IWICBitmap> bitmap;
    ComPtr<ID2D1RenderTarget> target;
    if (!wic || size <= 0 ||
        FAILED(wic->CreateBitmap(size, size, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, &bitmap))) {
        return nullptr;
    }
    D2D1_RENDER_TARGET_PROPERTIES properties = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
        96.0f, 96.0f);
    if (FAILED(D2DFactory()->CreateWicBitmapRenderTarget(bitmap.Get(), properties, &target))) return nullptr;

    target->BeginDraw();
    target->Clear(D2D1::ColorF(0, 0, 0, 0));
    draw(target.Get());
    if (FAILED(target->EndDraw())) return nullptr;

    std::vector<uint8_t> pixels(static_cast<size_t>(size) * size * 4);
    if (FAILED(bitmap->CopyPixels(nullptr, size * 4, static_cast<UINT>(pixels.size()), pixels.data()))) return nullptr;

    bool anyInk = false;
    for (size_t i = 0; i < pixels.size(); i += 4) {
        uint8_t alpha = pixels[i + 3];
        if (alpha) anyInk = true;
        // Icons store straight alpha.
        if (alpha && alpha != 0xFF) {
            for (int c = 0; c < 3; ++c) pixels[i + c] = static_cast<uint8_t>(std::min(255, pixels[i + c] * 255 / alpha));
        }
    }
    if (!anyInk) return nullptr;

    BITMAPV5HEADER header{};
    header.bV5Size = sizeof(header);
    header.bV5Width = size;
    header.bV5Height = -size;
    header.bV5Planes = 1;
    header.bV5BitCount = 32;
    header.bV5Compression = BI_BITFIELDS;
    header.bV5RedMask = 0x00FF0000;
    header.bV5GreenMask = 0x0000FF00;
    header.bV5BlueMask = 0x000000FF;
    header.bV5AlphaMask = 0xFF000000;

    void* bits = nullptr;
    HDC screen = GetDC(nullptr);
    HBITMAP color = CreateDIBSection(screen, reinterpret_cast<BITMAPINFO*>(&header), DIB_RGB_COLORS, &bits, nullptr, 0);
    ReleaseDC(nullptr, screen);
    if (!color || !bits) return nullptr;
    std::memcpy(bits, pixels.data(), pixels.size());

    HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
    ICONINFO info{};
    info.fIcon = TRUE;
    info.hbmColor = color;
    info.hbmMask = mask;
    HICON icon = CreateIconIndirect(&info);
    DeleteObject(color);
    DeleteObject(mask);
    return icon;
}

}  // namespace

HICON CreateEmojiIcon(const wchar_t* emoji, int size) {
    return RenderIcon(size, [&](ID2D1RenderTarget* target) {
        // Emoji carry their own colour, so this draws them as they are rather than as a
        // silhouette. Centre on the drawn ink, not the line box, which sits it low.
        std::wstring text(emoji);
        float fontSize = size * 0.8f;
        ComPtr<IDWriteTextFormat> format;
        ComPtr<IDWriteTextLayout> layout;
        if (FAILED(DWriteFactory()->CreateTextFormat(L"Segoe UI Emoji", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
                                                     DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, fontSize,
                                                     L"", &format)) ||
            FAILED(DWriteFactory()->CreateTextLayout(text.c_str(), static_cast<UINT32>(text.size()), format.Get(),
                                                     static_cast<float>(size) * 4, static_cast<float>(size) * 4,
                                                     &layout))) {
            return;
        }
        DWRITE_OVERHANG_METRICS overhang{};
        DWRITE_TEXT_METRICS metrics{};
        layout->GetMetrics(&metrics);
        layout->GetOverhangMetrics(&overhang);
        float inkLeft = -overhang.left;
        float inkTop = -overhang.top;
        float inkWidth = metrics.layoutWidth + overhang.right + overhang.left;
        float inkHeight = metrics.layoutHeight + overhang.bottom + overhang.top;
        if (inkWidth <= 0 || inkHeight <= 0) return;

        float available = size * 0.92f;
        float scale = std::min(available / inkWidth, available / inkHeight);
        float x = (size - inkWidth * scale) / 2 - inkLeft * scale;
        float y = (size - inkHeight * scale) / 2 - inkTop * scale;

        ComPtr<ID2D1SolidColorBrush> brush;
        target->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &brush);
        target->SetTransform(D2D1::Matrix3x2F::Scale(scale, scale) * D2D1::Matrix3x2F::Translation(x, y));
        target->DrawTextLayout(D2D1::Point2F(0, 0), layout.Get(), brush.Get(),
                               D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
        target->SetTransform(D2D1::Matrix3x2F::Identity());
    });
}

HICON CreateRecordingIcon(int size) {
    return RenderIcon(size, [&](ID2D1RenderTarget* target) {
        ComPtr<ID2D1SolidColorBrush> brush;
        target->CreateSolidColorBrush(Rgb(1.0f, 0.231f, 0.188f), &brush);
        float radius = size * 0.42f;
        target->FillEllipse(D2D1::Ellipse(D2D1::Point2F(size / 2.0f, size / 2.0f), radius, radius), brush.Get());
        brush->SetColor(D2D1::ColorF(1, 1, 1, 1));
        float inner = size * 0.14f;
        target->FillEllipse(D2D1::Ellipse(D2D1::Point2F(size / 2.0f, size / 2.0f), inner, inner), brush.Get());
    });
}

}  // namespace space::gfx
