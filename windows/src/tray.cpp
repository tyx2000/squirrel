// Purpose: Implements the notification-area icon, its menu, and the recording pill.

#include "tray.h"

#include "graphics.h"
#include "recording.h"
#include "resource.h"

#include <commctrl.h>
#include <shellapi.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace space {

namespace {

constexpr UINT kTrayIconId = 1;
constexpr UINT kMenuStop = 1;
constexpr UINT kMenuOpen = 2;
constexpr UINT kMenuQuit = 3;
constexpr wchar_t kPillWindowClass[] = L"SpaceRecordingPill";
// The night-with-stars emoji the Mac build shows in the menu bar.
constexpr wchar_t kTrayEmoji[] = L"\U0001F303";

}  // namespace

std::wstring ElapsedText(ULONGLONG milliseconds) {
    ULONGLONG total = milliseconds / 1000;
    ULONGLONG hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60;
    return hours > 0 ? FormatString(L"%llu:%02llu:%02llu", hours, minutes, seconds)
                     : FormatString(L"%02llu:%02llu", minutes, seconds);
}

TrayController::TrayController(RecordingService& recording) : recording_(recording) {}

TrayController::~TrayController() {
    Remove();
    if (pill_) DestroyWindow(pill_);
    if (ownsNormalIcon_ && normalIcon_) DestroyIcon(normalIcon_);
    if (recordingIcon_) DestroyIcon(recordingIcon_);
}

void TrayController::Install(HWND messageWindow) {
    messageWindow_ = messageWindow;
    int size = GetSystemMetrics(SM_CXSMICON);

    normalIcon_ = gfx::CreateEmojiIcon(kTrayEmoji, size);
    ownsNormalIcon_ = normalIcon_ != nullptr;
    if (!normalIcon_) {
        LoadIconMetric(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP), LIM_SMALL, &normalIcon_);
    }
    recordingIcon_ = gfx::CreateRecordingIcon(size);

    NOTIFYICONDATAW data{sizeof(data)};
    data.hWnd = messageWindow_;
    data.uID = kTrayIconId;
    data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    data.uCallbackMessage = WM_APP_TRAY;
    data.hIcon = normalIcon_;
    wcscpy_s(data.szTip, L"Open Space");
    installed_ = Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
    data.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &data);

    if (recording_.IsRecording()) ShowRecordingState();
}

void TrayController::Remove() {
    if (!installed_) return;
    NOTIFYICONDATAW data{sizeof(data)};
    data.hWnd = messageWindow_;
    data.uID = kTrayIconId;
    Shell_NotifyIconW(NIM_DELETE, &data);
    installed_ = false;
}

void TrayController::HandleTaskbarCreated() {
    installed_ = false;
    if (ownsNormalIcon_ && normalIcon_) DestroyIcon(normalIcon_);
    if (recordingIcon_) DestroyIcon(recordingIcon_);
    normalIcon_ = recordingIcon_ = nullptr;
    showingRecording_ = false;
    Install(messageWindow_);
}

void TrayController::Modify(HICON icon, const std::wstring& tip) {
    NOTIFYICONDATAW data{sizeof(data)};
    data.hWnd = messageWindow_;
    data.uID = kTrayIconId;
    data.uFlags = NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    data.hIcon = icon;
    wcsncpy_s(data.szTip, tip.c_str(), _TRUNCATE);
    Shell_NotifyIconW(NIM_MODIFY, &data);
}

// A click opens the panel, or stops the recording while one is running. A right-click
// offers a menu, which is the only way to quit without opening the panel.
void TrayController::HandleCallback(WPARAM wParam, LPARAM lParam) {
    switch (LOWORD(lParam)) {
        case NIN_SELECT:
        case NIN_KEYSELECT:
            if (recording_.IsRecording()) {
                if (onStop) onStop();
            } else if (onOpen) {
                onOpen();
            }
            break;
        case WM_CONTEXTMENU:
            ShowMenu(POINT{GET_X_LPARAM(wParam), GET_Y_LPARAM(wParam)});
            break;
        default:
            break;
    }
}

void TrayController::ShowMenu(POINT anchor) {
    HMENU menu = CreatePopupMenu();
    if (recording_.IsRecording()) {
        AppendMenuW(menu, MF_STRING, kMenuStop, L"Stop Recording");
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    }
    AppendMenuW(menu, MF_STRING, kMenuOpen, L"Open Space");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kMenuQuit, L"Quit Space");
    SetMenuDefaultItem(menu, kMenuOpen, FALSE);

    // Without the foreground the menu would not close when clicking elsewhere.
    SetForegroundWindow(messageWindow_);
    UINT flags = TPM_RETURNCMD | TPM_RIGHTBUTTON |
                 (GetSystemMetrics(SM_MENUDROPALIGNMENT) ? TPM_RIGHTALIGN : TPM_LEFTALIGN) | TPM_BOTTOMALIGN;
    UINT command = TrackPopupMenuEx(menu, flags, anchor.x, anchor.y, messageWindow_, nullptr);
    PostMessageW(messageWindow_, WM_NULL, 0, 0);
    DestroyMenu(menu);

    switch (command) {
        case kMenuStop: if (onStop) onStop(); break;
        case kMenuOpen: if (onOpen) onOpen(); break;
        case kMenuQuit: if (onQuit) onQuit(); break;
        default: break;
    }
}

void TrayController::RecordingStateChanged() {
    if (recording_.IsRecording()) ShowRecordingState();
    else ShowNormalState();
}

void TrayController::ShowNormalState() {
    if (!showingRecording_) return;
    showingRecording_ = false;
    KillTimer(messageWindow_, kTickTimerId);
    if (pill_) ShowWindow(pill_, SW_HIDE);
    Modify(normalIcon_, L"Open Space");
}

// The notification area only has room for a square icon, so while recording the icon
// turns red and a pill with the elapsed time floats at the top of the recorded screen.
// Recordings leave the pill out.
void TrayController::ShowRecordingState() {
    if (showingRecording_) return;
    showingRecording_ = true;

    if (!pill_) {
        static bool registered = [] {
            WNDCLASSEXW windowClass{sizeof(windowClass)};
            windowClass.lpfnWndProc = &TrayController::PillProc;
            windowClass.hInstance = GetModuleHandleW(nullptr);
            windowClass.hCursor = LoadCursorW(nullptr, IDC_HAND);
            windowClass.lpszClassName = kPillWindowClass;
            return RegisterClassExW(&windowClass) != 0;
        }();
        if (registered) {
            pill_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_NOACTIVATE,
                                    kPillWindowClass, L"Space Recording", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
                                    GetModuleHandleW(nullptr), this);
            if (pill_) SetWindowDisplayAffinity(pill_, WDA_EXCLUDEFROMCAPTURE);
        }
    }

    UpdateRecordingIndicator();
    if (pill_) ShowWindow(pill_, SW_SHOWNOACTIVATE);
    // Ticks land on whole seconds because the timer starts with the recording.
    SetTimer(messageWindow_, kTickTimerId, 1000, nullptr);
}

void TrayController::HandleTick() {
    if (showingRecording_) UpdateRecordingIndicator();
}

void TrayController::UpdateRecordingIndicator() {
    ULONGLONG started = recording_.RecordingStartedAt();
    std::wstring text = ElapsedText(started ? GetTickCount64() - started : 0);
    Modify(recordingIcon_ ? recordingIcon_ : normalIcon_, L"Recording " + text + L". Click to stop.");
    RenderPill(text);
}

LRESULT CALLBACK TrayController::PillProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_NCCREATE) {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto* self = reinterpret_cast<TrayController*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (message) {
        case WM_MOUSEACTIVATE:
            return MA_NOACTIVATE;
        case WM_LBUTTONUP:
            if (self && self->onStop) self->onStop();
            return 0;
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

// Draws the pill into a per-pixel-alpha bitmap so its rounded ends stay smooth.
void TrayController::RenderPill(const std::wstring& text) {
    if (!pill_) return;

    HMONITOR monitor = recording_.TargetMonitor();
    MONITORINFO info{sizeof(info)};
    if (!GetMonitorInfoW(monitor, &info)) return;
    float scale = DpiScaleForMonitor(monitor);

    IDWriteTextFormat* format = gfx::TextFormat(12.5f * scale, DWRITE_FONT_WEIGHT_SEMI_BOLD);
    D2D1_SIZE_F textSize = gfx::MeasureText(text, format);
    float dotSpace = 16 * scale;
    int height = static_cast<int>(std::ceil(26 * scale));
    int width = static_cast<int>(std::ceil(textSize.width + dotSpace + 32 * scale));

    BITMAPINFO bitmapInfo{};
    bitmapInfo.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bitmapInfo.bmiHeader.biWidth = width;
    bitmapInfo.bmiHeader.biHeight = -height;
    bitmapInfo.bmiHeader.biPlanes = 1;
    bitmapInfo.bmiHeader.biBitCount = 32;
    bitmapInfo.bmiHeader.biCompression = BI_RGB;

    HDC screen = GetDC(nullptr);
    HDC memory = CreateCompatibleDC(screen);
    void* bits = nullptr;
    HBITMAP bitmap = CreateDIBSection(screen, &bitmapInfo, DIB_RGB_COLORS, &bits, nullptr, 0);
    HGDIOBJ previous = SelectObject(memory, bitmap);

    ComPtr<ID2D1DCRenderTarget> target;
    D2D1_RENDER_TARGET_PROPERTIES properties = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
        96.0f, 96.0f);
    RECT bounds{0, 0, width, height};
    if (bits && SUCCEEDED(gfx::D2DFactory()->CreateDCRenderTarget(&properties, &target)) &&
        SUCCEEDED(target->BindDC(memory, &bounds))) {
        gfx::Painter painter(target.Get());
        target->BeginDraw();
        target->Clear(D2D1::ColorF(0, 0, 0, 0));
        D2D1_RECT_F pill = D2D1::RectF(0, 0, static_cast<float>(width), static_cast<float>(height));
        painter.FillRounded(pill, height / 2.0f, gfx::Rgb(1.0f, 0.231f, 0.188f));
        float dotX = 16 * scale;
        painter.FillEllipse(D2D1::Point2F(dotX, height / 2.0f), 4 * scale, 4 * scale, gfx::Rgb(1, 1, 1));
        painter.Text(text, format, D2D1::RectF(dotX + dotSpace - 4 * scale, 0, pill.right - 12 * scale, pill.bottom),
                     gfx::Rgb(1, 1, 1), DWRITE_TEXT_ALIGNMENT_CENTER, DWRITE_PARAGRAPH_ALIGNMENT_CENTER, false, false);
        target->EndDraw();

        POINT position{info.rcMonitor.left + (info.rcMonitor.right - info.rcMonitor.left - width) / 2,
                       info.rcMonitor.top + static_cast<LONG>(8 * scale)};
        SIZE size{width, height};
        POINT origin{0, 0};
        BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
        UpdateLayeredWindow(pill_, screen, &position, &size, memory, &origin, 0, &blend, ULW_ALPHA);
    }

    SelectObject(memory, previous);
    if (bitmap) DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(nullptr, screen);
}

}  // namespace space
