// Purpose: Direct2D and DirectWrite helpers shared by every custom-drawn window: factories,
// cached text formats, a brush-holding painter, icon glyphs and generated icons.

#pragma once

#include "common.h"

#include <d2d1.h>
#include <dwrite.h>

namespace space::gfx {

ID2D1Factory* D2DFactory();
IDWriteFactory* DWriteFactory();

D2D1_COLOR_F Rgb(float red, float green, float blue, float alpha = 1.0f);
D2D1_COLOR_F WithAlpha(D2D1_COLOR_F color, float alpha);
// The Windows accent colour, read from DWM's settings, or the default blue.
D2D1_COLOR_F AccentColor();

inline constexpr wchar_t kTextFamily[] = L"Segoe UI";
inline constexpr wchar_t kMonoFamily[] = L"Consolas";
// Segoe Fluent Icons on Windows 11, Segoe MDL2 Assets on Windows 10; both use the same
// code points for the glyphs below.
const wchar_t* IconFamily();

namespace glyph {
inline constexpr wchar_t kClipboard = 0xE77F;
inline constexpr wchar_t kKeyboard = 0xE765;
inline constexpr wchar_t kPower = 0xE7E8;
inline constexpr wchar_t kCopy = 0xE8C8;
inline constexpr wchar_t kDelete = 0xE74D;
inline constexpr wchar_t kClose = 0xE8BB;
inline constexpr wchar_t kMinimize = 0xE921;
inline constexpr wchar_t kCancel = 0xE711;
inline constexpr wchar_t kPin = 0xE718;
inline constexpr wchar_t kWarning = 0xE7BA;
inline constexpr wchar_t kErrorBadge = 0xE783;
inline constexpr wchar_t kInfo = 0xE946;
inline constexpr wchar_t kCheckMark = 0xE73E;
inline constexpr wchar_t kPicture = 0xE8B9;
inline constexpr wchar_t kVideo = 0xE714;
}  // namespace glyph

IDWriteTextFormat* TextFormat(float size, DWRITE_FONT_WEIGHT weight = DWRITE_FONT_WEIGHT_NORMAL,
                              const wchar_t* family = kTextFamily);

D2D1_SIZE_F MeasureText(const std::wstring& text, IDWriteTextFormat* format, float maxWidth = 100000.0f);

inline D2D1_RECT_F Rect(float left, float top, float width, float height) {
    return D2D1::RectF(left, top, left + width, top + height);
}
inline bool Contains(const D2D1_RECT_F& rect, float x, float y) {
    return x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom;
}
inline D2D1_RECT_F Inset(const D2D1_RECT_F& rect, float dx, float dy) {
    return D2D1::RectF(rect.left + dx, rect.top + dy, rect.right - dx, rect.bottom - dy);
}

// Draws with one reusable brush.
class Painter {
public:
    explicit Painter(ID2D1RenderTarget* target);

    ID2D1RenderTarget* Target() const { return target_; }
    ID2D1SolidColorBrush* Brush(D2D1_COLOR_F color);

    void Fill(const D2D1_RECT_F& rect, D2D1_COLOR_F color);
    void FillRounded(const D2D1_RECT_F& rect, float radius, D2D1_COLOR_F color);
    void StrokeRounded(const D2D1_RECT_F& rect, float radius, D2D1_COLOR_F color, float width);
    void Stroke(const D2D1_RECT_F& rect, D2D1_COLOR_F color, float width);
    void FillEllipse(D2D1_POINT_2F center, float radiusX, float radiusY, D2D1_COLOR_F color);
    void Line(D2D1_POINT_2F from, D2D1_POINT_2F to, D2D1_COLOR_F color, float width);

    // Text inside `rect`; `trim` adds an ellipsis when it does not fit.
    void Text(const std::wstring& text, IDWriteTextFormat* format, const D2D1_RECT_F& rect, D2D1_COLOR_F color,
              DWRITE_TEXT_ALIGNMENT alignment = DWRITE_TEXT_ALIGNMENT_LEADING,
              DWRITE_PARAGRAPH_ALIGNMENT paragraph = DWRITE_PARAGRAPH_ALIGNMENT_CENTER, bool wrap = false,
              bool trim = true);
    void Glyph(wchar_t glyph, float size, const D2D1_RECT_F& rect, D2D1_COLOR_F color);

private:
    ID2D1RenderTarget* target_;
    ComPtr<ID2D1SolidColorBrush> brush_;
};

// A colour emoji rendered with Segoe UI Emoji into an icon of `size` pixels, or nullptr.
HICON CreateEmojiIcon(const wchar_t* emoji, int size);
// A red recording dot.
HICON CreateRecordingIcon(int size);

}  // namespace space::gfx
