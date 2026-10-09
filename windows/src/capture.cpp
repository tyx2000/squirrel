// Purpose: Implements the frozen-screen capture overlay (selection, resize handles,
// annotations, colour sampling) and the copy/pin output.

#include "capture.h"

#include "clipboard_store.h"
#include "graphics.h"

#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace space {

namespace {

constexpr wchar_t kOverlayWindowClass[] = L"SpaceCaptureOverlay";
constexpr UINT_PTR kConfirmationTimerId = 1;
constexpr UINT kConfirmationDurationMs = 1100;
constexpr UINT kWindowHideSettleMs = 120;
constexpr float kHeadAngle = 3.14159265f / 7.0f;

const D2D1_COLOR_F kAnnotationColor = gfx::Rgb(1.0f, 0.231f, 0.188f);

D2D1_RECT_F Normalized(D2D1_POINT_2F a, D2D1_POINT_2F b) {
    return D2D1::RectF(std::min(a.x, b.x), std::min(a.y, b.y), std::max(a.x, b.x), std::max(a.y, b.y));
}

float RectWidth(const D2D1_RECT_F& rect) { return rect.right - rect.left; }
float RectHeight(const D2D1_RECT_F& rect) { return rect.bottom - rect.top; }

D2D1_POINT_2F Clamp(D2D1_POINT_2F point, const D2D1_RECT_F& rect) {
    return D2D1::Point2F(std::min(std::max(point.x, rect.left), rect.right),
                         std::min(std::max(point.y, rect.top), rect.bottom));
}

// Keeps the rect's size and moves it inside `bounds`.
D2D1_RECT_F ClampInside(const D2D1_RECT_F& rect, const D2D1_RECT_F& bounds) {
    float width = RectWidth(rect), height = RectHeight(rect);
    float left = std::min(std::max(rect.left, bounds.left), bounds.right - width);
    float top = std::min(std::max(rect.top, bounds.top), bounds.bottom - height);
    return D2D1::RectF(left, top, left + width, top + height);
}

D2D1_RECT_F Offset(const D2D1_RECT_F& rect, float dx, float dy) {
    return D2D1::RectF(rect.left + dx, rect.top + dy, rect.right + dx, rect.bottom + dy);
}

bool RectContains(const D2D1_RECT_F& rect, D2D1_POINT_2F point) {
    return point.x >= rect.left && point.x <= rect.right && point.y >= rect.top && point.y <= rect.bottom;
}

float Distance(D2D1_POINT_2F a, D2D1_POINT_2F b) {
    return std::hypot(b.x - a.x, b.y - a.y);
}

void DrawAnnotation(ID2D1RenderTarget* target, ID2D1Brush* brush, const Annotation& annotation, float lineWidth,
                    float headLength) {
    switch (annotation.tool) {
        case AnnotationTool::Rectangle:
            target->DrawRectangle(Normalized(annotation.start, annotation.end), brush, lineWidth);
            break;
        case AnnotationTool::Line:
            target->DrawLine(annotation.start, annotation.end, brush, lineWidth);
            break;
        case AnnotationTool::Arrow: {
            D2D1_POINT_2F start = annotation.start, end = annotation.end;
            target->DrawLine(start, end, brush, lineWidth);
            float angle = std::atan2(end.y - start.y, end.x - start.x);
            D2D1_POINT_2F left = D2D1::Point2F(end.x - headLength * std::cos(angle - kHeadAngle),
                                               end.y - headLength * std::sin(angle - kHeadAngle));
            D2D1_POINT_2F right = D2D1::Point2F(end.x - headLength * std::cos(angle + kHeadAngle),
                                                end.y - headLength * std::sin(angle + kHeadAngle));
            target->DrawLine(end, left, brush, lineWidth);
            target->DrawLine(end, right, brush, lineWidth);
            break;
        }
    }
}

std::unique_ptr<ScreenSnapshot> TakeSnapshot(HMONITOR monitor) {
    MONITORINFO info{sizeof(info)};
    if (!GetMonitorInfoW(monitor, &info)) return nullptr;

    auto snapshot = std::make_unique<ScreenSnapshot>();
    snapshot->monitorRect = info.rcMonitor;
    snapshot->scale = DpiScaleForMonitor(monitor);
    int width = info.rcMonitor.right - info.rcMonitor.left;
    int height = info.rcMonitor.bottom - info.rcMonitor.top;
    if (width <= 0 || height <= 0) return nullptr;

    BITMAPINFO bitmapInfo{};
    bitmapInfo.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bitmapInfo.bmiHeader.biWidth = width;
    bitmapInfo.bmiHeader.biHeight = -height;  // top-down
    bitmapInfo.bmiHeader.biPlanes = 1;
    bitmapInfo.bmiHeader.biBitCount = 32;
    bitmapInfo.bmiHeader.biCompression = BI_RGB;

    HDC screen = GetDC(nullptr);
    HDC memory = CreateCompatibleDC(screen);
    void* bits = nullptr;
    HBITMAP dib = CreateDIBSection(screen, &bitmapInfo, DIB_RGB_COLORS, &bits, nullptr, 0);
    bool ok = false;
    if (memory && dib && bits) {
        HGDIOBJ previous = SelectObject(memory, dib);
        // CAPTUREBLT includes layered windows, which most modern apps' popups are.
        ok = BitBlt(memory, 0, 0, width, height, screen, info.rcMonitor.left, info.rcMonitor.top,
                    SRCCOPY | CAPTUREBLT) != FALSE;
        GdiFlush();
        if (ok) {
            snapshot->pixels.width = static_cast<UINT>(width);
            snapshot->pixels.height = static_cast<UINT>(height);
            snapshot->pixels.pixels.resize(static_cast<size_t>(width) * height * 4);
            std::memcpy(snapshot->pixels.pixels.data(), bits, snapshot->pixels.pixels.size());
            // GDI leaves the alpha byte undefined; screenshots are opaque.
            for (size_t i = 3; i < snapshot->pixels.pixels.size(); i += 4) snapshot->pixels.pixels[i] = 0xFF;
        }
        SelectObject(memory, previous);
    }
    if (dib) DeleteObject(dib);
    if (memory) DeleteDC(memory);
    ReleaseDC(nullptr, screen);
    return ok ? std::move(snapshot) : nullptr;
}

// The largest size with the same aspect ratio that fits within `maxPixelCount`.
SIZE FittedPixelSize(LONG width, LONG height, uint64_t maxPixelCount) {
    uint64_t count = static_cast<uint64_t>(width) * static_cast<uint64_t>(height);
    if (maxPixelCount == 0 || count <= maxPixelCount) return SIZE{width, height};
    double scale = std::sqrt(static_cast<double>(maxPixelCount) / static_cast<double>(count));
    return SIZE{std::max<LONG>(1, static_cast<LONG>(std::floor(width * scale))),
                std::max<LONG>(1, static_cast<LONG>(std::floor(height * scale)))};
}

enum class ColorFormat { Hex, Rgb };

struct SampledColor {
    uint8_t red, green, blue;

    std::wstring Text(ColorFormat format) const {
        return format == ColorFormat::Hex ? FormatString(L"#%02X%02X%02X", red, green, blue)
                                          : FormatString(L"rgb(%u, %u, %u)", red, green, blue);
    }
};

}  // namespace

namespace handles {

std::vector<std::pair<ResizeHandle, D2D1_RECT_F>> Rects(const D2D1_RECT_F& rect, const ResizeHandleMetrics& metrics) {
    auto corner = [&](float x, float y) {
        return D2D1::RectF(x - metrics.cornerSize.width / 2, y - metrics.cornerSize.height / 2,
                           x + metrics.cornerSize.width / 2, y + metrics.cornerSize.height / 2);
    };
    auto edge = [&](float x, float y, bool horizontal) {
        float width = horizontal ? metrics.edgeLength : metrics.edgeThickness;
        float height = horizontal ? metrics.edgeThickness : metrics.edgeLength;
        return D2D1::RectF(x - width / 2, y - height / 2, x + width / 2, y + height / 2);
    };
    float midX = (rect.left + rect.right) / 2, midY = (rect.top + rect.bottom) / 2;
    return {
        {ResizeHandle::TopLeft, corner(rect.left, rect.top)},
        {ResizeHandle::Top, edge(midX, rect.top, true)},
        {ResizeHandle::TopRight, corner(rect.right, rect.top)},
        {ResizeHandle::Right, edge(rect.right, midY, false)},
        {ResizeHandle::BottomRight, corner(rect.right, rect.bottom)},
        {ResizeHandle::Bottom, edge(midX, rect.bottom, true)},
        {ResizeHandle::BottomLeft, corner(rect.left, rect.bottom)},
        {ResizeHandle::Left, edge(rect.left, midY, false)},
    };
}

std::optional<ResizeHandle> HandleAt(D2D1_POINT_2F point, const D2D1_RECT_F& rect, const ResizeHandleMetrics& metrics) {
    std::optional<ResizeHandle> best;
    float bestDistance = 0;
    for (const auto& [handle, handleRect] : Rects(rect, metrics)) {
        D2D1_RECT_F hit = gfx::Inset(handleRect, -metrics.hitOutset, -metrics.hitOutset);
        if (!RectContains(hit, point)) continue;
        float cx = (handleRect.left + handleRect.right) / 2, cy = (handleRect.top + handleRect.bottom) / 2;
        float distance = (point.x - cx) * (point.x - cx) + (point.y - cy) * (point.y - cy);
        if (!best || distance < bestDistance) {
            best = handle;
            bestDistance = distance;
        }
    }
    return best;
}

}  // namespace handles

class CaptureOverlay {
public:
    using CompleteCallback = std::function<void(CaptureOutputAction, D2D1_RECT_F, std::vector<Annotation>)>;

    CaptureOverlay(const ScreenSnapshot& snapshot, CompleteCallback onComplete, std::function<void()> onCancel)
        : snapshot_(snapshot), onComplete_(std::move(onComplete)), onCancel_(std::move(onCancel)) {
        float s = snapshot.scale;
        minimumSelectionSize_ = 6 * s;
        metrics_ = ResizeHandleMetrics{D2D1::SizeF(4 * s, 4 * s), 4 * s, 28 * s, 8 * s};
        toolbarSize_ = D2D1::SizeF(232 * s, 36 * s);
        toolbarGap_ = 12 * s;
        buttonSize_ = 28 * s;
        buttonSpacing_ = 8 * s;
        bounds_ = D2D1::RectF(0, 0, static_cast<float>(snapshot.pixels.width), static_cast<float>(snapshot.pixels.height));
    }

    ~CaptureOverlay() {
        if (hwnd_) {
            SetWindowLongPtrW(hwnd_, GWLP_USERDATA, 0);
            DestroyWindow(hwnd_);
        }
    }

    bool Show() {
        static bool registered = [] {
            WNDCLASSEXW windowClass{sizeof(windowClass)};
            windowClass.lpfnWndProc = &CaptureOverlay::WindowProc;
            windowClass.hInstance = GetModuleHandleW(nullptr);
            windowClass.lpszClassName = kOverlayWindowClass;
            return RegisterClassExW(&windowClass) != 0;
        }();
        if (!registered) return false;

        const RECT& frame = snapshot_.monitorRect;
        hwnd_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kOverlayWindowClass, L"Capture Area", WS_POPUP,
                                frame.left, frame.top, frame.right - frame.left, frame.bottom - frame.top, nullptr,
                                nullptr, GetModuleHandleW(nullptr), this);
        if (!hwnd_) return false;

        ShowWindow(hwnd_, SW_SHOW);
        UpdateWindow(hwnd_);
        BringToForeground(hwnd_);
        SetFocus(hwnd_);

        POINT cursor{};
        GetCursorPos(&cursor);
        ScreenToClient(hwnd_, &cursor);
        UpdateColorSample(D2D1::Point2F(static_cast<float>(cursor.x), static_cast<float>(cursor.y)));
        return true;
    }

private:
    enum class ToolbarAction { Rectangle, Line, Arrow, Pin, Copy, Cancel };

    struct ToolbarButton {
        ToolbarAction action;
        D2D1_RECT_F rect;
    };

    static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
        if (message == WM_NCCREATE) {
            auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        }
        auto* self = reinterpret_cast<CaptureOverlay*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (!self) return DefWindowProcW(hwnd, message, wParam, lParam);
        return self->Handle(hwnd, message, wParam, lParam);
    }

    static D2D1_POINT_2F PointFrom(LPARAM lParam) {
        return D2D1::Point2F(static_cast<float>(GET_X_LPARAM(lParam)), static_cast<float>(GET_Y_LPARAM(lParam)));
    }

    LRESULT Handle(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
        switch (message) {
            case WM_LBUTTONDOWN:
                SetCapture(hwnd);
                MouseDown(PointFrom(lParam));
                return 0;
            case WM_MOUSEMOVE:
                if (wParam & MK_LBUTTON) MouseDragged(PointFrom(lParam));
                else MouseMoved(PointFrom(lParam));
                return 0;
            case WM_LBUTTONUP:
                ReleaseCapture();
                MouseUp(PointFrom(lParam));
                return 0;
            case WM_SETCURSOR:
                if (LOWORD(lParam) == HTCLIENT) {
                    SetCursor(cursor_);
                    return TRUE;
                }
                break;
            case WM_KEYDOWN:
                KeyDown(static_cast<UINT>(wParam), (lParam & (1 << 30)) != 0);
                return 0;
            case WM_KEYUP:
                if (wParam == VK_SHIFT) shiftDown_ = false;
                return 0;
            case WM_TIMER:
                if (wParam == kConfirmationTimerId) {
                    KillTimer(hwnd, kConfirmationTimerId);
                    ClearCopyConfirmation();
                }
                return 0;
            case WM_ERASEBKGND:
                return 1;
            case WM_PAINT: {
                PAINTSTRUCT paint;
                BeginPaint(hwnd, &paint);
                Render();
                EndPaint(hwnd, &paint);
                return 0;
            }
            case WM_DISPLAYCHANGE:
                // The frozen image no longer matches the screen.
                Cancel();
                return 0;
            default:
                break;
        }
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }

    void Invalidate() {
        if (hwnd_) InvalidateRect(hwnd_, nullptr, FALSE);
    }

    std::optional<D2D1_RECT_F> DraftSelection() const {
        if (!dragStart_ || !dragCurrent_) return std::nullopt;
        return Normalized(*dragStart_, *dragCurrent_);
    }

    // Below the selection, right-aligned, kept on screen.
    D2D1_RECT_F ToolbarRect() const {
        if (!selection_) return D2D1::RectF(0, 0, 0, 0);
        float x = std::min(std::max(selection_->right - toolbarSize_.width, 8.0f),
                           std::max(bounds_.right - toolbarSize_.width - 8, 8.0f));
        float y = std::min(selection_->bottom + toolbarGap_, bounds_.bottom - toolbarSize_.height - 8);
        y = std::max(y, 8.0f);
        return gfx::Rect(x, y, toolbarSize_.width, toolbarSize_.height);
    }

    std::vector<ToolbarButton> ToolbarButtons() const {
        if (!selection_) return {};
        static const ToolbarAction kActions[] = {ToolbarAction::Rectangle, ToolbarAction::Line, ToolbarAction::Arrow,
                                                 ToolbarAction::Pin, ToolbarAction::Copy, ToolbarAction::Cancel};
        D2D1_RECT_F toolbar = ToolbarRect();
        float total = 6 * buttonSize_ + 5 * buttonSpacing_;
        float x = (toolbar.left + toolbar.right) / 2 - total / 2;
        float y = (toolbar.top + toolbar.bottom) / 2 - buttonSize_ / 2;
        std::vector<ToolbarButton> buttons;
        for (ToolbarAction action : kActions) {
            buttons.push_back({action, gfx::Rect(x, y, buttonSize_, buttonSize_)});
            x += buttonSize_ + buttonSpacing_;
        }
        return buttons;
    }

    std::optional<ToolbarAction> ToolbarActionAt(D2D1_POINT_2F point) const {
        for (const auto& button : ToolbarButtons()) {
            if (RectContains(button.rect, point)) return button.action;
        }
        return std::nullopt;
    }

    static std::optional<AnnotationTool> ToolFor(ToolbarAction action) {
        switch (action) {
            case ToolbarAction::Rectangle: return AnnotationTool::Rectangle;
            case ToolbarAction::Line: return AnnotationTool::Line;
            case ToolbarAction::Arrow: return AnnotationTool::Arrow;
            default: return std::nullopt;
        }
    }

    void MouseDown(D2D1_POINT_2F point) {
        if (auto action = ToolbarActionAt(point)) {
            pressedAction_ = action;
            Invalidate();
            return;
        }

        if (selection_) {
            if (auto handle = handles::HandleAt(point, *selection_, metrics_)) {
                resizeHandle_ = handle;
                resizeOriginalRect_ = selection_;
                resizeOriginalAnnotations_ = annotations_;
            } else if (RectContains(*selection_, point)) {
                if (activeTool_) {
                    annotationStart_ = point;
                    annotationCurrent_ = point;
                } else {
                    moveStart_ = point;
                    moveOriginalRect_ = selection_;
                    moveOriginalAnnotations_ = annotations_;
                }
            } else {
                ClearSelectionState();
                dragStart_ = point;
                dragCurrent_ = point;
            }
        } else {
            dragStart_ = point;
            dragCurrent_ = point;
        }
        UpdateCursor(point);
        Invalidate();
    }

    void MouseDragged(D2D1_POINT_2F point) {
        if (pressedAction_) return;

        if (resizeHandle_) {
            ResizeSelection(point);
        } else if (moveStart_) {
            MoveSelection(point);
        } else if (selection_ && annotationStart_) {
            annotationCurrent_ = point;
        } else if (dragStart_) {
            dragCurrent_ = point;
        }
        UpdateColorSample(point);
        UpdateCursor(point);
        Invalidate();
    }

    void MouseUp(D2D1_POINT_2F point) {
        if (pressedAction_) {
            ToolbarAction action = *pressedAction_;
            pressedAction_.reset();
            if (ToolbarActionAt(point) == action) {
                HandleAction(action);  // may finish the capture; touch nothing after
                return;
            }
            UpdateCursor(point);
            Invalidate();
            return;
        }

        if (selection_ && activeTool_ && annotationStart_) {
            annotationCurrent_ = point;
            if (auto annotation = CurrentAnnotation(); annotation &&
                Distance(annotation->start, annotation->end) >= minimumSelectionSize_) {
                annotations_.push_back(*annotation);
            }
            annotationStart_.reset();
            annotationCurrent_.reset();
        } else if (resizeHandle_) {
            ResizeSelection(point);
            resizeHandle_.reset();
            resizeOriginalRect_.reset();
            resizeOriginalAnnotations_.clear();
        } else if (moveStart_) {
            MoveSelection(point);
            moveStart_.reset();
            moveOriginalRect_.reset();
            moveOriginalAnnotations_.clear();
        } else if (dragStart_) {
            dragCurrent_ = point;
            auto draft = DraftSelection();
            dragStart_.reset();
            dragCurrent_.reset();
            if (draft && RectWidth(*draft) >= minimumSelectionSize_ && RectHeight(*draft) >= minimumSelectionSize_) {
                selection_ = draft;
                activeTool_.reset();
            }
        }
        UpdateCursor(point);
        Invalidate();
    }

    void MouseMoved(D2D1_POINT_2F point) {
        UpdateCursor(point);
        UpdateColorSample(point);
    }

    void KeyDown(UINT key, bool isRepeat) {
        if (key == VK_ESCAPE) {
            Cancel();  // touch nothing after
            return;
        }
        if (key == VK_SHIFT) {
            if (!isRepeat && !shiftDown_) {
                colorFormat_ = colorFormat_ == ColorFormat::Hex ? ColorFormat::Rgb : ColorFormat::Hex;
                Invalidate();
            }
            shiftDown_ = true;
            return;
        }
        // Matched by key so it works whether Shift (RGB mode) is held or not.
        if (key == 'C') CopySampledColor();
    }

    void HandleAction(ToolbarAction action) {
        if (auto tool = ToolFor(action)) {
            activeTool_ = activeTool_ == tool ? std::nullopt : tool;
            Invalidate();
            return;
        }
        switch (action) {
            case ToolbarAction::Pin: Finish(CaptureOutputAction::Pin); return;
            case ToolbarAction::Copy: Finish(CaptureOutputAction::Copy); return;
            case ToolbarAction::Cancel: Cancel(); return;
            default: return;
        }
    }

    // Hides the overlay and reports; the owner destroys this object later.
    void Finish(CaptureOutputAction action) {
        if (finished_ || !selection_) return;
        finished_ = true;
        ShowWindow(hwnd_, SW_HIDE);
        auto onComplete = onComplete_;
        onComplete(action, *selection_, annotations_);
    }

    void Cancel() {
        if (finished_) return;
        finished_ = true;
        ShowWindow(hwnd_, SW_HIDE);
        auto onCancel = onCancel_;
        onCancel();
    }

    void ClearSelectionState() {
        selection_.reset();
        activeTool_.reset();
        annotationStart_.reset();
        annotationCurrent_.reset();
        annotations_.clear();
        moveStart_.reset();
        moveOriginalRect_.reset();
        moveOriginalAnnotations_.clear();
        resizeHandle_.reset();
        resizeOriginalRect_.reset();
        resizeOriginalAnnotations_.clear();
    }

    std::optional<Annotation> CurrentAnnotation() const {
        if (!activeTool_ || !annotationStart_ || !annotationCurrent_ || !selection_) return std::nullopt;
        return Annotation{*activeTool_, Clamp(*annotationStart_, *selection_), Clamp(*annotationCurrent_, *selection_)};
    }

    void MoveSelection(D2D1_POINT_2F point) {
        if (!moveStart_ || !moveOriginalRect_) return;
        D2D1_RECT_F moved = Offset(*moveOriginalRect_, point.x - moveStart_->x, point.y - moveStart_->y);
        D2D1_RECT_F clamped = ClampInside(moved, bounds_);
        float dx = clamped.left - moveOriginalRect_->left;
        float dy = clamped.top - moveOriginalRect_->top;

        selection_ = clamped;
        annotations_ = moveOriginalAnnotations_;
        for (auto& annotation : annotations_) {
            annotation.start = D2D1::Point2F(annotation.start.x + dx, annotation.start.y + dy);
            annotation.end = D2D1::Point2F(annotation.end.x + dx, annotation.end.y + dy);
        }
    }

    void ResizeSelection(D2D1_POINT_2F point) {
        if (!resizeHandle_ || !resizeOriginalRect_) return;
        D2D1_RECT_F resized = ResizedSelection(*resizeOriginalRect_, *resizeHandle_, point);
        selection_ = resized;
        annotations_ = resizeOriginalAnnotations_;
        for (auto& annotation : annotations_) {
            annotation.start = Clamp(annotation.start, resized);
            annotation.end = Clamp(annotation.end, resized);
        }
    }

    D2D1_RECT_F ResizedSelection(const D2D1_RECT_F& original, ResizeHandle handle, D2D1_POINT_2F point) const {
        float left = original.left, right = original.right, top = original.top, bottom = original.bottom;
        switch (handle) {
            case ResizeHandle::TopLeft: left = point.x; top = point.y; break;
            case ResizeHandle::Top: top = point.y; break;
            case ResizeHandle::TopRight: right = point.x; top = point.y; break;
            case ResizeHandle::Right: right = point.x; break;
            case ResizeHandle::BottomRight: right = point.x; bottom = point.y; break;
            case ResizeHandle::Bottom: bottom = point.y; break;
            case ResizeHandle::BottomLeft: left = point.x; bottom = point.y; break;
            case ResizeHandle::Left: left = point.x; break;
        }

        left = std::max(bounds_.left, left);
        right = std::min(bounds_.right, right);
        top = std::max(bounds_.top, top);
        bottom = std::min(bounds_.bottom, bottom);

        if (right - left < minimumSelectionSize_) {
            bool movesLeft = handle == ResizeHandle::Left || handle == ResizeHandle::TopLeft ||
                             handle == ResizeHandle::BottomLeft;
            if (movesLeft) left = std::max(bounds_.left, right - minimumSelectionSize_);
            else right = std::min(bounds_.right, left + minimumSelectionSize_);
        }
        if (bottom - top < minimumSelectionSize_) {
            bool movesTop = handle == ResizeHandle::Top || handle == ResizeHandle::TopLeft ||
                            handle == ResizeHandle::TopRight;
            if (movesTop) top = std::max(bounds_.top, bottom - minimumSelectionSize_);
            else bottom = std::min(bounds_.bottom, top + minimumSelectionSize_);
        }
        return D2D1::RectF(left, top, right, bottom);
    }

    static HCURSOR CursorFor(ResizeHandle handle) {
        switch (handle) {
            case ResizeHandle::Top:
            case ResizeHandle::Bottom: return LoadCursorW(nullptr, IDC_SIZENS);
            case ResizeHandle::Left:
            case ResizeHandle::Right: return LoadCursorW(nullptr, IDC_SIZEWE);
            case ResizeHandle::TopLeft:
            case ResizeHandle::BottomRight: return LoadCursorW(nullptr, IDC_SIZENWSE);
            case ResizeHandle::TopRight:
            case ResizeHandle::BottomLeft: return LoadCursorW(nullptr, IDC_SIZENESW);
        }
        return LoadCursorW(nullptr, IDC_CROSS);
    }

    void UpdateCursor(D2D1_POINT_2F point) {
        HCURSOR cursor = LoadCursorW(nullptr, IDC_CROSS);
        if (resizeHandle_) {
            cursor = CursorFor(*resizeHandle_);
        } else if (moveStart_) {
            cursor = LoadCursorW(nullptr, IDC_SIZEALL);
        } else if (annotationStart_ || !selection_) {
            cursor = LoadCursorW(nullptr, IDC_CROSS);
        } else if (auto handle = handles::HandleAt(point, *selection_, metrics_)) {
            cursor = CursorFor(*handle);
        } else if (ToolbarActionAt(point)) {
            cursor = LoadCursorW(nullptr, IDC_ARROW);
        } else if (RectContains(*selection_, point)) {
            cursor = LoadCursorW(nullptr, activeTool_ ? IDC_CROSS : IDC_SIZEALL);
        }
        if (cursor != cursor_) {
            cursor_ = cursor;
            SetCursor(cursor_);
        }
    }

    // Reads the frozen snapshot rather than the screen, so the dimming and the selection
    // border never tint the reported colour.
    std::optional<SampledColor> ColorAt(D2D1_POINT_2F point) const {
        const imaging::Bitmap& pixels = snapshot_.pixels;
        if (point.x < 0 || point.y < 0 || pixels.width == 0 || pixels.height == 0) return std::nullopt;
        UINT x = std::min(static_cast<UINT>(point.x), pixels.width - 1);
        UINT y = std::min(static_cast<UINT>(point.y), pixels.height - 1);
        const uint8_t* pixel = pixels.pixels.data() + (static_cast<size_t>(y) * pixels.width + x) * 4;
        return SampledColor{pixel[2], pixel[1], pixel[0]};
    }

    void UpdateColorSample(D2D1_POINT_2F point) {
        if (confirmationText_ && (!sampleLocation_ || sampleLocation_->x != point.x || sampleLocation_->y != point.y)) {
            ClearCopyConfirmation();
        }

        // The toolbar sits above the frozen image, so there is no meaningful colour there.
        if (selection_ && RectContains(ToolbarRect(), point)) {
            sampleLocation_.reset();
            sampledColor_.reset();
        } else {
            sampleLocation_ = point;
            sampledColor_ = ColorAt(point);
        }
        Invalidate();
    }

    void CopySampledColor() {
        if (!sampledColor_) return;
        std::wstring text = sampledColor_->Text(colorFormat_);
        if (OpenClipboard(hwnd_)) {
            EmptyClipboard();
            size_t bytes = (text.size() + 1) * sizeof(wchar_t);
            HGLOBAL global = GlobalAlloc(GMEM_MOVEABLE, bytes);
            if (global) {
                std::memcpy(GlobalLock(global), text.c_str(), bytes);
                GlobalUnlock(global);
                if (!SetClipboardData(CF_UNICODETEXT, global)) GlobalFree(global);
            }
            CloseClipboard();
        }
        confirmationText_ = text;
        SetTimer(hwnd_, kConfirmationTimerId, kConfirmationDurationMs, nullptr);
        Invalidate();
    }

    void ClearCopyConfirmation() {
        if (!confirmationText_) return;
        confirmationText_.reset();
        KillTimer(hwnd_, kConfirmationTimerId);
        Invalidate();
    }

    void EnsureTarget() {
        if (target_) return;
        RECT client{};
        GetClientRect(hwnd_, &client);
        D2D1_RENDER_TARGET_PROPERTIES properties = D2D1::RenderTargetProperties();
        // One unit per physical pixel, matching the snapshot.
        properties.dpiX = properties.dpiY = 96.0f;
        if (FAILED(gfx::D2DFactory()->CreateHwndRenderTarget(
                properties, D2D1::HwndRenderTargetProperties(hwnd_, D2D1::SizeU(client.right, client.bottom)),
                &target_))) {
            return;
        }
        const imaging::Bitmap& pixels = snapshot_.pixels;
        target_->CreateBitmap(D2D1::SizeU(pixels.width, pixels.height), pixels.pixels.data(), pixels.width * 4,
                              D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE)),
                              &snapshotBitmap_);
    }

    void Render() {
        EnsureTarget();
        if (!target_) return;
        gfx::Painter painter(target_.Get());
        float s = snapshot_.scale;

        target_->BeginDraw();
        target_->Clear(D2D1::ColorF(0, 0, 0, 1));
        if (snapshotBitmap_) {
            target_->DrawBitmap(snapshotBitmap_.Get(), bounds_, 1.0f, D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR);
        }

        auto shown = selection_ ? selection_ : DraftSelection();
        if (shown) {
            DrawDimmedBackground(painter, *shown, selection_.has_value());
            painter.Stroke(*shown, gfx::AccentColor(), 2 * s);
            for (const auto& annotation : annotations_) {
                DrawAnnotation(target_.Get(), painter.Brush(kAnnotationColor), annotation, 3 * s, 13 * s);
            }
            if (auto current = CurrentAnnotation()) {
                DrawAnnotation(target_.Get(), painter.Brush(kAnnotationColor), *current, 3 * s, 13 * s);
            }
            DrawSizeLabel(painter, *shown);
            if (selection_) {
                for (const auto& [handle, rect] : handles::Rects(*shown, metrics_)) {
                    painter.FillRounded(rect, 1 * s, gfx::Rgb(1, 1, 1, 0.96f));
                    painter.StrokeRounded(rect, 1 * s, gfx::AccentColor(), 1 * s);
                }
                DrawToolbar(painter);
            }
        } else {
            painter.Fill(bounds_, gfx::Rgb(0, 0, 0, 0.26f));
        }

        DrawColorReadout(painter);

        if (target_->EndDraw() == D2DERR_RECREATE_TARGET) {
            snapshotBitmap_.Reset();
            target_.Reset();
        }
    }

    void DrawDimmedBackground(gfx::Painter& painter, const D2D1_RECT_F& rect, bool exposingToolbar) {
        ID2D1Factory* factory = gfx::D2DFactory();
        std::vector<ComPtr<ID2D1Geometry>> geometries;
        ComPtr<ID2D1RectangleGeometry> all, hole;
        factory->CreateRectangleGeometry(bounds_, &all);
        factory->CreateRectangleGeometry(rect, &hole);
        geometries.push_back(all);
        geometries.push_back(hole);
        if (exposingToolbar) {
            float s = snapshot_.scale;
            ComPtr<ID2D1RoundedRectangleGeometry> toolbar;
            factory->CreateRoundedRectangleGeometry(
                D2D1::RoundedRect(gfx::Inset(ToolbarRect(), -2 * s, -2 * s), 9 * s, 9 * s), &toolbar);
            geometries.push_back(toolbar);
        }

        std::vector<ID2D1Geometry*> raw;
        for (auto& geometry : geometries) {
            if (geometry) raw.push_back(geometry.Get());
        }
        ComPtr<ID2D1GeometryGroup> group;
        if (SUCCEEDED(factory->CreateGeometryGroup(D2D1_FILL_MODE_ALTERNATE, raw.data(), static_cast<UINT32>(raw.size()),
                                                   &group))) {
            target_->FillGeometry(group.Get(), painter.Brush(gfx::Rgb(0, 0, 0, 0.26f)));
        }
    }

    void DrawSizeLabel(gfx::Painter& painter, const D2D1_RECT_F& rect) {
        float s = snapshot_.scale;
        std::wstring text = FormatString(L"%d × %d", static_cast<int>(RectWidth(rect)),
                                         static_cast<int>(RectHeight(rect)));
        IDWriteTextFormat* format = gfx::TextFormat(12 * s, DWRITE_FONT_WEIGHT_MEDIUM);
        D2D1_SIZE_F size = gfx::MeasureText(text, format);
        float width = size.width + 14 * s, height = size.height + 8 * s;
        float top = std::min(rect.bottom + 2 * s, bounds_.bottom - height - 8 * s);
        D2D1_RECT_F label = gfx::Rect(rect.left, std::max(top, 8 * s), width, height);
        painter.FillRounded(label, 5 * s, gfx::Rgb(0, 0, 0, 0.62f));
        painter.Text(text, format, label, gfx::Rgb(1, 1, 1), DWRITE_TEXT_ALIGNMENT_CENTER);
    }

    void DrawToolbar(gfx::Painter& painter) {
        float s = snapshot_.scale;
        D2D1_RECT_F toolbar = ToolbarRect();

        // A soft shadow below the bar.
        for (int i = 4; i >= 1; --i) {
            float spread = i * 2.5f * s;
            painter.FillRounded(gfx::Inset(Offset(toolbar, 0, 2 * s), -spread, -spread), 8 * s + spread,
                                gfx::Rgb(0, 0, 0, 0.035f));
        }
        const D2D1_COLOR_F background = gfx::Rgb(0.98f, 0.98f, 0.98f, 0.96f);
        painter.FillRounded(toolbar, 8 * s, background);

        for (const auto& button : ToolbarButtons()) {
            auto tool = ToolFor(button.action);
            bool selected = tool && activeTool_ == tool;
            bool pressed = pressedAction_ == button.action;
            D2D1_COLOR_F fill = selected ? gfx::WithAlpha(kAnnotationColor, 0.16f)
                                         : (pressed ? gfx::Rgb(0, 0, 0, 0.08f) : background);
            painter.FillRounded(button.rect, 6 * s, fill);

            D2D1_COLOR_F ink = selected ? kAnnotationColor : gfx::Rgb(0.1f, 0.1f, 0.1f, 0.9f);
            D2D1_RECT_F icon = gfx::Inset(button.rect, 8 * s, 8 * s);
            float stroke = 1.6f * s;
            switch (button.action) {
                case ToolbarAction::Rectangle:
                    painter.Stroke(gfx::Inset(icon, 0, 1.5f * s), ink, stroke);
                    break;
                case ToolbarAction::Line:
                    painter.Line(D2D1::Point2F(icon.left, icon.bottom), D2D1::Point2F(icon.right, icon.top), ink, stroke);
                    break;
                case ToolbarAction::Arrow:
                    DrawAnnotation(target_.Get(), painter.Brush(ink),
                                   Annotation{AnnotationTool::Arrow, D2D1::Point2F(icon.left, icon.bottom),
                                              D2D1::Point2F(icon.right, icon.top)},
                                   stroke, 6 * s);
                    break;
                case ToolbarAction::Pin: painter.Glyph(gfx::glyph::kPin, 14 * s, button.rect, ink); break;
                case ToolbarAction::Copy: painter.Glyph(gfx::glyph::kCopy, 14 * s, button.rect, ink); break;
                case ToolbarAction::Cancel: painter.Glyph(gfx::glyph::kCancel, 13 * s, button.rect, ink); break;
            }
        }
    }

    void DrawColorReadout(gfx::Painter& painter) {
        if (!sampledColor_ || !sampleLocation_) return;
        float s = snapshot_.scale;
        std::wstring text = confirmationText_ ? L"✓ " + *confirmationText_ : sampledColor_->Text(colorFormat_);

        IDWriteTextFormat* format = gfx::TextFormat(12 * s, DWRITE_FONT_WEIGHT_MEDIUM);
        D2D1_SIZE_F textSize = gfx::MeasureText(text, format);
        float padding = 8 * s, swatch = 15 * s, gap = 18 * s;
        D2D1_RECT_F readout = gfx::Rect(sampleLocation_->x + gap, sampleLocation_->y + gap,
                                        padding * 3 + swatch + textSize.width,
                                        std::max(textSize.height, swatch) + padding);
        readout = ClampInside(readout, gfx::Inset(bounds_, 8 * s, 8 * s));

        painter.FillRounded(readout, 6 * s, gfx::Rgb(0, 0, 0, 0.72f));
        float midY = (readout.top + readout.bottom) / 2;
        D2D1_RECT_F swatchRect = gfx::Rect(readout.left + padding, midY - swatch / 2, swatch, swatch);
        painter.FillRounded(swatchRect, 3 * s,
                            gfx::Rgb(sampledColor_->red / 255.0f, sampledColor_->green / 255.0f,
                                     sampledColor_->blue / 255.0f));
        painter.StrokeRounded(swatchRect, 3 * s, gfx::Rgb(1, 1, 1, 0.55f), 1 * s);
        painter.Text(text, format,
                     D2D1::RectF(swatchRect.right + padding, readout.top, readout.right, readout.bottom),
                     gfx::Rgb(1, 1, 1), DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_PARAGRAPH_ALIGNMENT_CENTER, false,
                     false);
    }

    const ScreenSnapshot& snapshot_;
    CompleteCallback onComplete_;
    std::function<void()> onCancel_;
    HWND hwnd_ = nullptr;
    ComPtr<ID2D1HwndRenderTarget> target_;
    ComPtr<ID2D1Bitmap> snapshotBitmap_;
    HCURSOR cursor_ = LoadCursorW(nullptr, IDC_CROSS);
    bool finished_ = false;

    D2D1_RECT_F bounds_{};
    float minimumSelectionSize_ = 6;
    ResizeHandleMetrics metrics_{};
    D2D1_SIZE_F toolbarSize_{};
    float toolbarGap_ = 12;
    float buttonSize_ = 28;
    float buttonSpacing_ = 8;

    std::optional<D2D1_POINT_2F> dragStart_;
    std::optional<D2D1_POINT_2F> dragCurrent_;
    std::optional<D2D1_RECT_F> selection_;
    std::optional<AnnotationTool> activeTool_;
    std::optional<D2D1_POINT_2F> annotationStart_;
    std::optional<D2D1_POINT_2F> annotationCurrent_;
    std::vector<Annotation> annotations_;
    std::optional<ToolbarAction> pressedAction_;
    std::optional<D2D1_POINT_2F> moveStart_;
    std::optional<D2D1_RECT_F> moveOriginalRect_;
    std::vector<Annotation> moveOriginalAnnotations_;
    std::optional<ResizeHandle> resizeHandle_;
    std::optional<D2D1_RECT_F> resizeOriginalRect_;
    std::vector<Annotation> resizeOriginalAnnotations_;

    std::optional<D2D1_POINT_2F> sampleLocation_;
    std::optional<SampledColor> sampledColor_;
    ColorFormat colorFormat_ = ColorFormat::Hex;
    bool shiftDown_ = false;
    std::optional<std::wstring> confirmationText_;
};

std::optional<imaging::Bitmap> RenderCapture(const ScreenSnapshot& snapshot, const RECT& requested,
                                             const std::vector<Annotation>& annotations, uint64_t maxPixelCount) {
    const imaging::Bitmap& source = snapshot.pixels;
    RECT region{std::max<LONG>(requested.left, 0), std::max<LONG>(requested.top, 0),
                std::min<LONG>(requested.right, static_cast<LONG>(source.width)),
                std::min<LONG>(requested.bottom, static_cast<LONG>(source.height))};
    LONG cropWidth = region.right - region.left, cropHeight = region.bottom - region.top;
    if (cropWidth < 1 || cropHeight < 1) return std::nullopt;

    // Copy the region out so the full-screen snapshot can be freed.
    imaging::Bitmap crop;
    crop.width = static_cast<UINT>(cropWidth);
    crop.height = static_cast<UINT>(cropHeight);
    crop.premultiplied = true;  // opaque, so either reading is the same
    crop.pixels.resize(static_cast<size_t>(cropWidth) * cropHeight * 4);
    for (LONG y = 0; y < cropHeight; ++y) {
        std::memcpy(crop.pixels.data() + static_cast<size_t>(y) * cropWidth * 4,
                    source.pixels.data() + ((static_cast<size_t>(region.top) + y) * source.width + region.left) * 4,
                    static_cast<size_t>(cropWidth) * 4);
    }

    SIZE output = FittedPixelSize(cropWidth, cropHeight, maxPixelCount);
    if (annotations.empty() && output.cx == cropWidth && output.cy == cropHeight) return crop;

    // Everything is drawn in the region's own pixel coordinates and scaled together, so
    // image and annotations shrink as one.
    IWICImagingFactory* wic = imaging::Factory();
    ComPtr<IWICBitmap> bitmap;
    ComPtr<ID2D1RenderTarget> target;
    if (!wic || FAILED(wic->CreateBitmap(output.cx, output.cy, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad,
                                         &bitmap))) {
        return std::nullopt;
    }
    D2D1_RENDER_TARGET_PROPERTIES properties = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
        96.0f, 96.0f);
    if (FAILED(gfx::D2DFactory()->CreateWicBitmapRenderTarget(bitmap.Get(), properties, &target))) return std::nullopt;

    ComPtr<ID2D1Bitmap> cropBitmap;
    if (FAILED(target->CreateBitmap(D2D1::SizeU(crop.width, crop.height), crop.pixels.data(), crop.width * 4,
                                    D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                                                                             D2D1_ALPHA_MODE_PREMULTIPLIED)),
                                    &cropBitmap))) {
        return std::nullopt;
    }
    ComPtr<ID2D1SolidColorBrush> brush;
    target->CreateSolidColorBrush(kAnnotationColor, &brush);

    float scaleX = static_cast<float>(output.cx) / cropWidth;
    float scaleY = static_cast<float>(output.cy) / cropHeight;
    target->BeginDraw();
    target->Clear(D2D1::ColorF(0, 0, 0, 1));
    target->SetTransform(D2D1::Matrix3x2F::Scale(scaleX, scaleY));
    target->DrawBitmap(cropBitmap.Get(), D2D1::RectF(0, 0, static_cast<float>(cropWidth), static_cast<float>(cropHeight)),
                       1.0f, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
    target->SetTransform(D2D1::Matrix3x2F::Translation(static_cast<float>(-region.left), static_cast<float>(-region.top)) *
                         D2D1::Matrix3x2F::Scale(scaleX, scaleY));
    for (const auto& annotation : annotations) {
        DrawAnnotation(target.Get(), brush.Get(), annotation, 3 * snapshot.scale, 13 * snapshot.scale);
    }
    target->SetTransform(D2D1::Matrix3x2F::Identity());
    if (FAILED(target->EndDraw())) return std::nullopt;

    imaging::Bitmap result;
    result.width = static_cast<UINT>(output.cx);
    result.height = static_cast<UINT>(output.cy);
    result.premultiplied = true;
    result.pixels.resize(static_cast<size_t>(output.cx) * output.cy * 4);
    if (FAILED(bitmap->CopyPixels(nullptr, result.width * 4, static_cast<UINT>(result.pixels.size()),
                                  result.pixels.data()))) {
        return std::nullopt;
    }
    return result;
}

CaptureService::CaptureService(ClipboardStore& store, std::function<void(bool)> setPresentationSuppressed,
                               std::function<bool()> hidePanel)
    : store_(store), setPresentationSuppressed_(std::move(setPresentationSuppressed)), hidePanel_(std::move(hidePanel)) {}

CaptureService::~CaptureService() = default;

void CaptureService::Attach(HWND timerWindow) {
    timerWindow_ = timerWindow;
}

void CaptureService::ClearMessage() {
    SetMessage({});
}

void CaptureService::StartAreaCapture(std::function<void(const std::wstring&)> onFailure) {
    if (overlay_ || isPreparing_) return;
    onFailure_ = std::move(onFailure);

    setPresentationSuppressed_(true);
    bool didHidePanel = hidePanel_();
    isPreparing_ = true;

    // A hidden window only leaves the screen on the next composition, so let it go before
    // the screen is frozen into the snapshot.
    if (didHidePanel && timerWindow_) {
        SetTimer(timerWindow_, kSettleTimerId, kWindowHideSettleMs, nullptr);
    } else {
        ShowOverlay();
    }
}

bool CaptureService::HandleTimer(UINT_PTR timerId) {
    if (timerId == kSettleTimerId) {
        KillTimer(timerWindow_, kSettleTimerId);
        ShowOverlay();
        return true;
    }
    if (timerId == kFinishTimerId) {
        KillTimer(timerWindow_, kFinishTimerId);
        FinishOverlay();
        return true;
    }
    return false;
}

void CaptureService::ShowOverlay() {
    isPreparing_ = false;

    POINT cursor{};
    GetCursorPos(&cursor);
    snapshot_ = TakeSnapshot(MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST));
    if (!snapshot_) {
        setPresentationSuppressed_(false);
        Fail(L"Capture Area could not create the screenshot image.");
        return;
    }

    // The overlay reports from inside its own window procedure, so it is destroyed on
    // the next timer tick rather than while it is still running.
    overlay_ = std::make_unique<CaptureOverlay>(
        *snapshot_,
        [this](CaptureOutputAction action, D2D1_RECT_F selection, std::vector<Annotation> annotations) {
            pending_ = PendingResult{action, selection, std::move(annotations)};
            SetTimer(timerWindow_, kFinishTimerId, 1, nullptr);
        },
        [this] {
            pending_.reset();
            SetTimer(timerWindow_, kFinishTimerId, 1, nullptr);
        });
    if (!overlay_->Show()) {
        overlay_.reset();
        snapshot_.reset();
        setPresentationSuppressed_(false);
        Fail(L"Capture Area could not show its overlay.");
    }
}

void CaptureService::FinishOverlay() {
    overlay_.reset();
    setPresentationSuppressed_(false);
    if (pending_) {
        PendingResult result = std::move(*pending_);
        pending_.reset();
        Complete(result);
    }
    snapshot_.reset();
}

void CaptureService::Complete(const PendingResult& result) {
    if (!snapshot_) return;
    RECT region{static_cast<LONG>(std::floor(result.selection.left)), static_cast<LONG>(std::floor(result.selection.top)),
                static_cast<LONG>(std::ceil(result.selection.right)), static_cast<LONG>(std::ceil(result.selection.bottom))};
    SIZE selectionPixels{region.right - region.left, region.bottom - region.top};

    // A copied screenshot goes to the clipboard and to history, and history refuses
    // anything over its pixel cap, so size it to fit rather than let the two disagree.
    // A pin is never shown larger than its window, so it keeps no more than that.
    uint64_t maxPixels = result.action == CaptureOutputAction::Pin
        ? PinnedImageController::MaxPixelCount(selectionPixels, snapshot_->scale)
        : ClipboardStore::kMaxImagePixels;

    auto image = RenderCapture(*snapshot_, region, result.annotations, maxPixels);
    if (!image) {
        Fail(L"Capture Area could not create the screenshot image.");
        return;
    }

    if (result.action == CaptureOutputAction::Pin) {
        POINT origin{snapshot_->monitorRect.left + region.left, snapshot_->monitorRect.top + region.top};
        auto pinned = pins_.Pin(std::move(*image), origin, selectionPixels, snapshot_->scale);
        SetMessage(pinned.didEvict ? FormatString(L"Pinned images capped at 5 — oldest pin removed (%zu remaining).",
                                                  pinned.count)
                                   : std::wstring());
        return;
    }

    auto png = imaging::EncodePng(*image);
    if (!png) {
        Fail(L"Capture Area could not create the screenshot image.");
        return;
    }
    store_.SetClipboardImage(*png);
    if (store_.AddImage(*png, imaging::Sha256Hex(png->data(), png->size()), L"Screenshot", UnixNow())) {
        SetMessage({});
    } else {
        SetMessage(store_.LastError().empty() ? L"Screenshot was not saved to history." : store_.LastError());
    }
}

void CaptureService::Fail(const std::wstring& message) {
    SetMessage(message);
    if (onFailure_) onFailure_(message);
}

void CaptureService::SetMessage(std::wstring message) {
    lastMessage_ = std::move(message);
    if (onChange) onChange();
}

}  // namespace space
