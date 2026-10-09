// Purpose: Implements pinned screenshot windows drawn with Direct2D.

#include "pinned_image.h"

#include "graphics.h"

#include <dwmapi.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>

namespace space {

namespace {

constexpr wchar_t kPinnedWindowClass[] = L"SpacePinnedImage";
constexpr UINT kCloseCommand = 1;

}  // namespace

class PinnedImageWindow {
public:
    PinnedImageWindow(imaging::Bitmap image, std::function<void(PinnedImageWindow*)> onClose)
        : image_(std::move(image)), onClose_(std::move(onClose)) {}

    ~PinnedImageWindow() {
        if (hwnd_) {
            SetWindowLongPtrW(hwnd_, GWLP_USERDATA, 0);
            DestroyWindow(hwnd_);
        }
    }

    bool Create(const RECT& frame) {
        static bool registered = [] {
            WNDCLASSEXW windowClass{sizeof(windowClass)};
            windowClass.style = CS_DROPSHADOW;
            windowClass.lpfnWndProc = &PinnedImageWindow::WindowProc;
            windowClass.hInstance = GetModuleHandleW(nullptr);
            windowClass.hCursor = LoadCursorW(nullptr, IDC_SIZEALL);
            windowClass.lpszClassName = kPinnedWindowClass;
            return RegisterClassExW(&windowClass) != 0;
        }();
        if (!registered) return false;

        hwnd_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kPinnedWindowClass, L"Pinned Screenshot", WS_POPUP,
                                frame.left, frame.top, frame.right - frame.left, frame.bottom - frame.top, nullptr,
                                nullptr, GetModuleHandleW(nullptr), this);
        if (!hwnd_) return false;

        DWM_WINDOW_CORNER_PREFERENCE corners = DWMWCP_ROUNDSMALL;
        DwmSetWindowAttribute(hwnd_, DWMWA_WINDOW_CORNER_PREFERENCE, &corners, sizeof(corners));
        ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
        return true;
    }

    void Close() {
        if (hwnd_) PostMessageW(hwnd_, WM_CLOSE, 0, 0);
    }

private:
    static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
        if (message == WM_NCCREATE) {
            auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        }
        auto* self = reinterpret_cast<PinnedImageWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (!self) return DefWindowProcW(hwnd, message, wParam, lParam);
        return self->Handle(hwnd, message, wParam, lParam);
    }

    LRESULT Handle(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
        switch (message) {
            case WM_NCHITTEST:
                // The whole image drags the window, as the Mac pin does.
                return HTCAPTION;
            case WM_NCLBUTTONDBLCLK:
                return 0;
            case WM_NCRBUTTONUP: {
                HMENU menu = CreatePopupMenu();
                AppendMenuW(menu, MF_STRING, kCloseCommand, L"Close Pin\tEsc");
                SetForegroundWindow(hwnd);
                UINT command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, GET_X_LPARAM(lParam),
                                              GET_Y_LPARAM(lParam), 0, hwnd, nullptr);
                DestroyMenu(menu);
                if (command == kCloseCommand) Close();
                return 0;
            }
            case WM_KEYDOWN:
                if (wParam == VK_ESCAPE) Close();
                return 0;
            case WM_SIZE:
                if (target_) target_->Resize(D2D1::SizeU(LOWORD(lParam), HIWORD(lParam)));
                InvalidateRect(hwnd, nullptr, FALSE);
                return 0;
            case WM_DPICHANGED: {
                const RECT* suggested = reinterpret_cast<const RECT*>(lParam);
                SetWindowPos(hwnd, nullptr, suggested->left, suggested->top, suggested->right - suggested->left,
                             suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
                return 0;
            }
            case WM_ERASEBKGND:
                return 1;
            case WM_PAINT: {
                PAINTSTRUCT paint;
                BeginPaint(hwnd, &paint);
                Render(hwnd);
                EndPaint(hwnd, &paint);
                return 0;
            }
            case WM_CLOSE: {
                ShowWindow(hwnd, SW_HIDE);
                // The callback destroys this object, so call a copy and touch nothing after.
                auto onClose = onClose_;
                if (onClose) onClose(this);
                return 0;
            }
            default:
                return DefWindowProcW(hwnd, message, wParam, lParam);
        }
    }

    void Render(HWND hwnd) {
        RECT client{};
        GetClientRect(hwnd, &client);
        if (!target_) {
            D2D1_RENDER_TARGET_PROPERTIES properties = D2D1::RenderTargetProperties();
            properties.dpiX = properties.dpiY = 96.0f;
            if (FAILED(gfx::D2DFactory()->CreateHwndRenderTarget(
                    properties,
                    D2D1::HwndRenderTargetProperties(hwnd, D2D1::SizeU(client.right, client.bottom)), &target_))) {
                return;
            }
            D2D1_BITMAP_PROPERTIES bitmapProperties = D2D1::BitmapProperties(
                D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                                  image_.premultiplied ? D2D1_ALPHA_MODE_PREMULTIPLIED : D2D1_ALPHA_MODE_IGNORE));
            target_->CreateBitmap(D2D1::SizeU(image_.width, image_.height), image_.pixels.data(), image_.width * 4,
                                  bitmapProperties, &bitmap_);
        }

        target_->BeginDraw();
        target_->Clear(D2D1::ColorF(0, 0, 0, 1));
        if (bitmap_) {
            target_->DrawBitmap(bitmap_.Get(), D2D1::RectF(0, 0, static_cast<float>(client.right),
                                                           static_cast<float>(client.bottom)),
                                1.0f, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
        }
        if (target_->EndDraw() == D2DERR_RECREATE_TARGET) {
            bitmap_.Reset();
            target_.Reset();
        }
    }

    HWND hwnd_ = nullptr;
    imaging::Bitmap image_;
    std::function<void(PinnedImageWindow*)> onClose_;
    ComPtr<ID2D1HwndRenderTarget> target_;
    ComPtr<ID2D1Bitmap> bitmap_;
};

PinnedImageController::PinnedImageController() = default;
PinnedImageController::~PinnedImageController() = default;

D2D1_SIZE_F PinnedImageController::DisplaySize(D2D1_SIZE_F selection) {
    const float maxWidth = 720, maxHeight = 520;
    float scale = std::min({1.0f, maxWidth / std::max(selection.width, 1.0f), maxHeight / std::max(selection.height, 1.0f)});
    return D2D1::SizeF(std::max(selection.width * scale, 80.0f), std::max(selection.height * scale, 60.0f));
}

uint64_t PinnedImageController::MaxPixelCount(SIZE selectionPixels, float scale) {
    scale = std::max(scale, 1.0f);
    D2D1_SIZE_F display = DisplaySize(D2D1::SizeF(selectionPixels.cx / scale, selectionPixels.cy / scale));
    return static_cast<uint64_t>(std::ceil(display.width * scale)) * static_cast<uint64_t>(std::ceil(display.height * scale));
}

PinnedImageController::Result PinnedImageController::Pin(imaging::Bitmap image, POINT origin, SIZE selectionPixels,
                                                         float scale) {
    Result result;

    // Evict the oldest at the cap so memory stays bounded.
    if (windows_.size() >= kMaxPinnedImages) {
        windows_.erase(windows_.begin());
        result.didEvict = true;
    }

    scale = std::max(scale, 1.0f);
    D2D1_SIZE_F display = DisplaySize(D2D1::SizeF(selectionPixels.cx / scale, selectionPixels.cy / scale));
    RECT frame{origin.x, origin.y, origin.x + static_cast<LONG>(std::lround(display.width * scale)),
               origin.y + static_cast<LONG>(std::lround(display.height * scale))};

    auto window = std::make_unique<PinnedImageWindow>(std::move(image), [this](PinnedImageWindow* closed) {
        Remove(closed);
    });
    if (window->Create(frame)) windows_.push_back(std::move(window));
    result.count = windows_.size();
    return result;
}

void PinnedImageController::Remove(PinnedImageWindow* window) {
    auto found = std::find_if(windows_.begin(), windows_.end(),
                              [window](const std::unique_ptr<PinnedImageWindow>& candidate) {
                                  return candidate.get() == window;
                              });
    if (found != windows_.end()) windows_.erase(found);
}

}  // namespace space
