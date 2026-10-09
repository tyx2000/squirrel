// Purpose: Implements the clipboard and shortcuts panel.

#include "main_window.h"

#include "app.h"
#include "capture.h"
#include "imaging.h"
#include "login_item.h"
#include "recording.h"
#include "resource.h"
#include "window_manager.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <thread>

namespace space {

namespace {

constexpr wchar_t kPanelWindowClass[] = L"SpacePanel";
constexpr float kWindowWidth = 1080;
constexpr float kWindowHeight = 720;
constexpr float kTabBarHeight = 56;
constexpr float kBannerHeight = 40;
constexpr float kListPadding = 14;
constexpr float kCardSpacing = 10;
constexpr float kCardPadding = 12;
constexpr float kCardMaxHeight = 300;
constexpr float kActionWidth = 82;
constexpr float kImageMaxHeight = 230;
constexpr int kMaxTextLines = 11;
constexpr size_t kMaxMeasuredCharacters = 3000;
constexpr size_t kMaxThumbnails = 24;
constexpr UINT_PTR kShowAnimationTimer = 1;
constexpr UINT_PTR kScrollAnimationTimer = 2;
constexpr ULONGLONG kShowAnimationMs = 160;
constexpr ULONGLONG kScrollAnimationMs = 160;
constexpr UINT WM_APP_HIDE_PANEL = WM_APP + 20;

namespace palette {
const D2D1_COLOR_F kWindowBackground = gfx::Rgb(0.965f, 0.969f, 0.976f);
const D2D1_COLOR_F kTopBarBackground = gfx::Rgb(0.992f, 0.992f, 0.996f);
const D2D1_COLOR_F kSelectedBackground = gfx::Rgb(0.918f, 0.949f, 1.0f);
const D2D1_COLOR_F kSeparator = gfx::Rgb(0.894f, 0.906f, 0.922f);
const D2D1_COLOR_F kSecondaryText = gfx::Rgb(0.478f, 0.506f, 0.549f);
const D2D1_COLOR_F kPrimaryText = gfx::Rgb(0.11f, 0.11f, 0.12f);
const D2D1_COLOR_F kCardBackground = gfx::Rgb(1, 1, 1, 0.82f);
const D2D1_COLOR_F kButtonHover = gfx::Rgb(0.929f, 0.949f, 0.969f);
const D2D1_COLOR_F kOrange = gfx::Rgb(0.92f, 0.47f, 0.0f);
const D2D1_COLOR_F kRed = gfx::Rgb(1.0f, 0.231f, 0.188f);
const D2D1_COLOR_F kBlue = gfx::Rgb(0.0f, 0.47f, 0.84f);
const D2D1_COLOR_F kGreen = gfx::Rgb(0.16f, 0.62f, 0.29f);
}  // namespace palette

IDWriteTextFormat* Body() { return gfx::TextFormat(14); }
IDWriteTextFormat* BodyMedium() { return gfx::TextFormat(14, DWRITE_FONT_WEIGHT_MEDIUM); }
IDWriteTextFormat* Secondary() { return gfx::TextFormat(12.5f); }
IDWriteTextFormat* SecondarySemibold() { return gfx::TextFormat(12.5f, DWRITE_FONT_WEIGHT_SEMI_BOLD); }
IDWriteTextFormat* Title() { return gfx::TextFormat(18, DWRITE_FONT_WEIGHT_MEDIUM); }
IDWriteTextFormat* Mono() { return gfx::TextFormat(13, DWRITE_FONT_WEIGHT_NORMAL, gfx::kMonoFamily); }

double EaseOutCubic(double progress) { return 1 - std::pow(1 - progress, 3); }
double EaseInOut(double progress) {
    return progress < 0.5 ? 2 * progress * progress : 1 - std::pow(-2 * progress + 2, 2) / 2;
}

bool IsModifierKey(UINT key) {
    switch (key) {
        case VK_SHIFT: case VK_LSHIFT: case VK_RSHIFT:
        case VK_CONTROL: case VK_LCONTROL: case VK_RCONTROL:
        case VK_MENU: case VK_LMENU: case VK_RMENU:
        case VK_LWIN: case VK_RWIN:
            return true;
        default:
            return false;
    }
}

}  // namespace

// Decodes display-sized thumbnails off the UI thread: full-size screenshots reach 16MP.
class ThumbnailLoader {
public:
    struct Result {
        std::wstring id;
        std::optional<imaging::Bitmap> bitmap;
    };

    explicit ThumbnailLoader(HWND reply) : reply_(reply), thread_([this] { Run(); }) {}

    ~ThumbnailLoader() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stop_ = true;
        }
        condition_.notify_all();
        thread_.join();
    }

    void Request(std::wstring id, std::wstring path, UINT maxWidth, UINT maxHeight) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            queue_.push_back(Job{std::move(id), std::move(path), maxWidth, maxHeight});
        }
        condition_.notify_one();
    }

private:
    struct Job {
        std::wstring id;
        std::wstring path;
        UINT maxWidth;
        UINT maxHeight;
    };

    void Run() {
        HRESULT init = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        for (;;) {
            Job job;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                condition_.wait(lock, [this] { return stop_ || !queue_.empty(); });
                if (stop_) break;
                job = std::move(queue_.front());
                queue_.pop_front();
            }
            auto* result = new Result{job.id, imaging::DecodeFileFitting(job.path, job.maxWidth, job.maxHeight)};
            if (!PostMessageW(reply_, WM_APP_THUMBNAIL_READY, 0, reinterpret_cast<LPARAM>(result))) delete result;
        }
        if (SUCCEEDED(init)) CoUninitialize();
    }

    HWND reply_;
    std::mutex mutex_;
    std::condition_variable condition_;
    std::deque<Job> queue_;
    bool stop_ = false;
    std::thread thread_;  // last, so everything it uses exists first
};

HHOOK MainWindow::keyboardHook_ = nullptr;
HWND MainWindow::hookTarget_ = nullptr;

MainWindow::MainWindow(App& app) : app_(app) {}

MainWindow::~MainWindow() {
    CancelRecording();
    thumbnailLoader_.reset();
    if (hwnd_) {
        SetWindowLongPtrW(hwnd_, GWLP_USERDATA, 0);
        DestroyWindow(hwnd_);
    }
}

bool MainWindow::Create() {
    static bool registered = [] {
        WNDCLASSEXW windowClass{sizeof(windowClass)};
        windowClass.style = CS_DROPSHADOW;
        windowClass.lpfnWndProc = &MainWindow::WindowProc;
        windowClass.hInstance = GetModuleHandleW(nullptr);
        windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        windowClass.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP));
        windowClass.lpszClassName = kPanelWindowClass;
        return RegisterClassExW(&windowClass) != 0;
    }();
    if (!registered) return false;

    // A tool window: no taskbar button and no Alt-Tab entry, like the Mac panel. Topmost
    // so it stays above the window of the app the user was in.
    hwnd_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kPanelWindowClass, kAppName, WS_POPUP | WS_CLIPCHILDREN,
                            CW_USEDEFAULT, CW_USEDEFAULT, 100, 100, nullptr, nullptr, GetModuleHandleW(nullptr), this);
    if (!hwnd_) return false;

    DWM_WINDOW_CORNER_PREFERENCE corners = DWMWCP_ROUND;
    DwmSetWindowAttribute(hwnd_, DWMWA_WINDOW_CORNER_PREFERENCE, &corners, sizeof(corners));
    scale_ = DpiScaleForWindow(hwnd_);

    tooltip_ = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nullptr, WS_POPUP | TTS_NOPREFIX | TTS_ALWAYSTIP,
                               CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, hwnd_, nullptr,
                               GetModuleHandleW(nullptr), nullptr);
    if (tooltip_) {
        TOOLINFOW info{};
        info.cbSize = sizeof(info);
        info.uFlags = TTF_SUBCLASS;
        info.hwnd = hwnd_;
        info.uId = 1;
        info.lpszText = const_cast<wchar_t*>(L"");
        SendMessageW(tooltip_, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&info));
    }

    thumbnailLoader_ = std::make_unique<ThumbnailLoader>(hwnd_);
    return true;
}

bool MainWindow::IsVisible() const {
    return hwnd_ && IsWindowVisible(hwnd_);
}

void MainWindow::Show() {
    if (app_.IsPresentationSuppressed()) return;
    if (!hwnd_ && !Create()) return;

    // Remember where the user was typing, to give it the keyboard back and paste there.
    // Opening from the notification area puts the taskbar in front, so this skips shell
    // surfaces for the app window that was active before.
    if (HWND target = app_.Windows().TargetWindow()) previousForeground_ = target;

    bool wasVisible = IsVisible();
    tab_ = Tab::History;
    const auto& items = app_.Clipboard().Items();
    selectedId_ = items.empty() ? std::wstring() : items.front().id;
    scroll_[0] = 0;
    // Both can change in Settings while the panel is hidden.
    app_.LoginItem().Refresh();

    if (!wasVisible) {
        PlaceOnScreen();
        StartShowAnimation();
        ShowWindow(hwnd_, SW_SHOW);
    }
    BringToForeground(hwnd_);
    InvalidateRect(hwnd_, nullptr, FALSE);
}

bool MainWindow::Hide() {
    if (!IsVisible()) return false;
    CancelRecording();
    KillTimer(hwnd_, kShowAnimationTimer);
    KillTimer(hwnd_, kScrollAnimationTimer);
    thumbDragOffset_.reset();
    hover_ = {};
    pressed_ = {};
    UpdateTooltip(std::nullopt);
    ShowWindow(hwnd_, SW_HIDE);
    return true;
}

void MainWindow::Refresh() {
    const auto& items = app_.Clipboard().Items();
    bool selectionExists = std::any_of(items.begin(), items.end(),
                                       [this](const ClipboardItem& item) { return item.id == selectedId_; });
    // A deleted or pruned selection falls back to the newest entry.
    if (!selectionExists) selectedId_ = items.empty() ? std::wstring() : items.front().id;
    PruneThumbnails();
    if (IsVisible()) InvalidateRect(hwnd_, nullptr, FALSE);
}

void MainWindow::PlaceOnScreen() {
    HMONITOR monitor = nullptr;
    if (previousForeground_ && IsWindow(previousForeground_)) {
        monitor = MonitorFromWindow(previousForeground_, MONITOR_DEFAULTTONEAREST);
    } else {
        POINT cursor{};
        GetCursorPos(&cursor);
        monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
    }
    MONITORINFO info{sizeof(info)};
    if (!GetMonitorInfoW(monitor, &info)) return;
    const RECT& work = info.rcWork;

    // Move onto the monitor first so a DPI change lands before the size is worked out.
    SetWindowPos(hwnd_, HWND_TOPMOST, work.left, work.top, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
    scale_ = DpiScaleForWindow(hwnd_);
    if (target_) target_->SetDpi(96.0f * scale_, 96.0f * scale_);

    int width = std::min(static_cast<int>(std::lround(kWindowWidth * scale_)), static_cast<int>(work.right - work.left));
    int height = std::min(static_cast<int>(std::lround(kWindowHeight * scale_)), static_cast<int>(work.bottom - work.top));
    targetPosition_ = POINT{work.left + (work.right - work.left - width) / 2, work.top + (work.bottom - work.top - height) / 2};
    SetWindowPos(hwnd_, HWND_TOPMOST, targetPosition_.x, targetPosition_.y, width, height, SWP_NOACTIVATE);
}

void MainWindow::StartShowAnimation() {
    SetWindowLongPtrW(hwnd_, GWL_EXSTYLE, GetWindowLongPtrW(hwnd_, GWL_EXSTYLE) | WS_EX_LAYERED);
    SetLayeredWindowAttributes(hwnd_, 0, 0, LWA_ALPHA);
    SetWindowPos(hwnd_, nullptr, targetPosition_.x, targetPosition_.y + static_cast<int>(10 * scale_), 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    showAnimationStart_ = GetTickCount64();
    SetTimer(hwnd_, kShowAnimationTimer, 10, nullptr);
}

void MainWindow::StepShowAnimation() {
    double progress = std::min(1.0, static_cast<double>(GetTickCount64() - showAnimationStart_) / kShowAnimationMs);
    double eased = EaseOutCubic(progress);
    SetLayeredWindowAttributes(hwnd_, 0, static_cast<BYTE>(std::lround(255 * eased)), LWA_ALPHA);
    SetWindowPos(hwnd_, nullptr, targetPosition_.x,
                 targetPosition_.y + static_cast<int>(std::lround(10 * scale_ * (1 - eased))), 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    if (progress >= 1.0) {
        KillTimer(hwnd_, kShowAnimationTimer);
        SetWindowLongPtrW(hwnd_, GWL_EXSTYLE, GetWindowLongPtrW(hwnd_, GWL_EXSTYLE) & ~WS_EX_LAYERED);
        RedrawWindow(hwnd_, nullptr, nullptr, RDW_INVALIDATE | RDW_FRAME | RDW_ALLCHILDREN);
    }
}

LRESULT CALLBACK MainWindow::WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_NCCREATE) {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
        auto* self = static_cast<MainWindow*>(create->lpCreateParams);
        self->hwnd_ = hwnd;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    }
    auto* self = reinterpret_cast<MainWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (!self) return DefWindowProcW(hwnd, message, wParam, lParam);
    return self->Handle(message, wParam, lParam);
}

LRESULT MainWindow::Handle(UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
        case WM_PAINT: {
            PAINTSTRUCT paint;
            BeginPaint(hwnd_, &paint);
            Paint();
            EndPaint(hwnd_, &paint);
            return 0;
        }
        case WM_ERASEBKGND:
            return 1;
        case WM_SIZE:
            if (target_) target_->Resize(D2D1::SizeU(LOWORD(lParam), HIWORD(lParam)));
            InvalidateRect(hwnd_, nullptr, FALSE);
            return 0;
        case WM_DPICHANGED: {
            scale_ = HIWORD(wParam) / 96.0f;
            if (target_) target_->SetDpi(static_cast<float>(HIWORD(wParam)), static_cast<float>(HIWORD(wParam)));
            textHeights_.clear();
            const RECT* suggested = reinterpret_cast<const RECT*>(lParam);
            SetWindowPos(hwnd_, nullptr, suggested->left, suggested->top, suggested->right - suggested->left,
                         suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
            return 0;
        }
        case WM_NCHITTEST: {
            LRESULT hit = DefWindowProcW(hwnd_, message, wParam, lParam);
            if (hit != HTCLIENT) return hit;
            POINT point{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
            ScreenToClient(hwnd_, &point);
            float x = point.x / scale_, y = point.y / scale_;
            // The top bar drags the window, as the Mac panel's background does.
            if (y >= BannerHeight() && y < BannerHeight() + kTabBarHeight && !HitAt(x, y)) return HTCAPTION;
            return HTCLIENT;
        }
        case WM_NCLBUTTONDBLCLK:
            return 0;
        case WM_MOUSEMOVE:
            if (!trackingMouse_) {
                TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, hwnd_, 0};
                trackingMouse_ = TrackMouseEvent(&track) != FALSE;
            }
            MouseMove(GET_X_LPARAM(lParam) / scale_, GET_Y_LPARAM(lParam) / scale_);
            return 0;
        case WM_MOUSELEAVE:
            trackingMouse_ = false;
            if (hover_.kind != HitKind::None) {
                hover_ = {};
                InvalidateRect(hwnd_, nullptr, FALSE);
            }
            return 0;
        case WM_LBUTTONDOWN:
            SetCapture(hwnd_);
            MouseDown(GET_X_LPARAM(lParam) / scale_, GET_Y_LPARAM(lParam) / scale_);
            return 0;
        case WM_LBUTTONUP:
            if (GetCapture() == hwnd_) ReleaseCapture();
            MouseUp(GET_X_LPARAM(lParam) / scale_, GET_Y_LPARAM(lParam) / scale_);
            return 0;
        case WM_MOUSEWHEEL:
            Wheel(GET_WHEEL_DELTA_WPARAM(wParam));
            return 0;
        case WM_KEYDOWN:
            KeyDown(static_cast<UINT>(wParam));
            return 0;
        case WM_TIMER:
            if (wParam == kShowAnimationTimer) StepShowAnimation();
            else if (wParam == kScrollAnimationTimer) StepScrollAnimation();
            return 0;
        case WM_ACTIVATE:
            // Whatever takes the keyboard away ends the visit, unless it is a capture or a
            // dialog of ours.
            if (LOWORD(wParam) == WA_INACTIVE && !app_.IsPresentationSuppressed() && !app_.IsShowingModal()) {
                PostMessageW(hwnd_, WM_APP_HIDE_PANEL, 0, 0);
            }
            break;  // the default handling gives the window keyboard focus
        case WM_APP_HIDE_PANEL:
            if (GetForegroundWindow() != hwnd_ && !app_.IsShowingModal()) Hide();
            return 0;
        case WM_APP_THUMBNAIL_READY:
            ThumbnailReady(lParam);
            return 0;
        case WM_APP_SHORTCUT_KEY:
            HandleRecordedKey(static_cast<UINT>(wParam), static_cast<UINT>(lParam));
            return 0;
        case WM_APP_SHORTCUT_CANCEL:
            CancelRecording();
            return 0;
        case WM_CLOSE:
            Hide();
            return 0;
        default:
            break;
    }
    return DefWindowProcW(hwnd_, message, wParam, lParam);
}

// ---------------------------------------------------------------------------------------
// Drawing

bool MainWindow::EnsureTarget() {
    if (target_) return true;
    RECT client{};
    GetClientRect(hwnd_, &client);
    D2D1_RENDER_TARGET_PROPERTIES properties = D2D1::RenderTargetProperties();
    properties.dpiX = properties.dpiY = 96.0f * scale_;
    return SUCCEEDED(gfx::D2DFactory()->CreateHwndRenderTarget(
        properties, D2D1::HwndRenderTargetProperties(hwnd_, D2D1::SizeU(client.right, client.bottom)), &target_));
}

void MainWindow::DiscardDeviceResources() {
    target_.Reset();
    thumbnails_.clear();
    thumbnailOrder_.clear();
    thumbnailRequested_.clear();
}

float MainWindow::BannerHeight() const {
    return app_.Clipboard().LastError().empty() ? 0.0f : kBannerHeight;
}

D2D1_RECT_F MainWindow::ContentRect() const {
    RECT client{};
    GetClientRect(hwnd_, &client);
    return D2D1::RectF(0, BannerHeight() + kTabBarHeight + 1, client.right / scale_, client.bottom / scale_);
}

void MainWindow::AddHit(const D2D1_RECT_F& rect, HitId id, std::wstring tooltip) {
    hits_.push_back(HitRegion{rect, std::move(id), std::move(tooltip)});
}

void MainWindow::Paint() {
    if (!EnsureTarget()) return;
    hits_.clear();
    gfx::Painter painter(target_.Get());

    target_->BeginDraw();
    target_->SetTransform(D2D1::Matrix3x2F::Identity());
    target_->Clear(palette::kWindowBackground);

    DrawBanner(painter);
    DrawTabBar(painter);

    D2D1_RECT_F content = ContentRect();
    painter.Fill(D2D1::RectF(content.left, content.top - 1, content.right, content.top), palette::kSeparator);
    viewportHeight_ = content.bottom - content.top;

    target_->PushAxisAlignedClip(content, D2D1_ANTIALIAS_MODE_ALIASED);
    size_t firstContentHit = hits_.size();
    if (tab_ == Tab::History) DrawHistory(painter, content);
    else DrawShortcuts(painter, content);
    target_->PopAxisAlignedClip();

    // What scrolled out of view cannot be clicked.
    for (size_t i = firstContentHit; i < hits_.size(); ++i) {
        D2D1_RECT_F& rect = hits_[i].rect;
        rect.top = std::max(rect.top, content.top);
        rect.bottom = std::min(rect.bottom, content.bottom);
    }
    DrawScrollbar(painter, content);

    if (target_->EndDraw() == D2DERR_RECREATE_TARGET) {
        DiscardDeviceResources();
        InvalidateRect(hwnd_, nullptr, FALSE);
    }
}

void MainWindow::DrawBanner(gfx::Painter& painter) {
    const std::wstring& error = app_.Clipboard().LastError();
    if (error.empty()) return;
    RECT client{};
    GetClientRect(hwnd_, &client);
    float width = client.right / scale_;

    D2D1_RECT_F banner = D2D1::RectF(0, 0, width, kBannerHeight);
    painter.Fill(banner, gfx::WithAlpha(palette::kOrange, 0.1f));
    painter.Glyph(gfx::glyph::kErrorBadge, 15, gfx::Rect(12, 0, 18, kBannerHeight), palette::kOrange);
    painter.Text(error, Secondary(), D2D1::RectF(42, 2, width - 48, kBannerHeight - 2), palette::kPrimaryText,
                 DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_PARAGRAPH_ALIGNMENT_CENTER, true, true);

    D2D1_RECT_F dismiss = gfx::Rect(width - 40, 6, 28, 28);
    bool hovered = hover_.kind == HitKind::DismissError;
    if (hovered) painter.FillRounded(dismiss, 14, gfx::Rgb(0, 0, 0, 0.06f));
    painter.Glyph(gfx::glyph::kCancel, 11, dismiss, palette::kSecondaryText);
    AddHit(dismiss, HitId{HitKind::DismissError}, L"Dismiss");
}

void MainWindow::DrawTabBar(gfx::Painter& painter) {
    RECT client{};
    GetClientRect(hwnd_, &client);
    float width = client.right / scale_;
    float top = BannerHeight();
    float centerY = top + kTabBarHeight / 2;
    painter.Fill(D2D1::RectF(0, top, width, top + kTabBarHeight), palette::kTopBarBackground);

    struct TabSpec {
        Tab tab;
        wchar_t glyph;
        const wchar_t* title;
    };
    const TabSpec tabs[] = {{Tab::History, gfx::glyph::kClipboard, L"Clipboard"},
                            {Tab::Shortcuts, gfx::glyph::kKeyboard, L"Shortcuts"}};
    float widths[2];
    float total = 12;
    for (int i = 0; i < 2; ++i) {
        float textWidth = gfx::MeasureText(tabs[i].title, BodyMedium()).width;
        widths[i] = std::max(116.0f, 16 + 8 + textWidth) + 24;
        total += widths[i];
    }

    float x = (width - total) / 2;
    for (int i = 0; i < 2; ++i) {
        bool selected = tab_ == tabs[i].tab;
        bool hovered = hover_.kind == HitKind::Tab && hover_.index == i;
        D2D1_RECT_F rect = D2D1::RectF(x, centerY - 18, x + widths[i], centerY + 18);
        if (selected) painter.FillRounded(rect, 8, palette::kSelectedBackground);
        else if (hovered) painter.FillRounded(rect, 8, gfx::WithAlpha(palette::kButtonHover, 0.8f));

        D2D1_COLOR_F ink = selected ? gfx::AccentColor() : palette::kPrimaryText;
        float textWidth = gfx::MeasureText(tabs[i].title, BodyMedium()).width;
        float contentLeft = x + (widths[i] - (16 + 8 + textWidth)) / 2;
        painter.Glyph(tabs[i].glyph, 15, gfx::Rect(contentLeft, rect.top, 16, 36), ink);
        painter.Text(tabs[i].title, BodyMedium(), D2D1::RectF(contentLeft + 24, rect.top, rect.right, rect.bottom), ink);
        AddHit(rect, HitId{HitKind::Tab, i});
        x += widths[i] + 12;
    }

    // Close (hide) and Quit on the right.
    D2D1_RECT_F close = gfx::Rect(width - 18 - 34, centerY - 15, 34, 30);
    bool closeHovered = hover_.kind == HitKind::Close;
    if (closeHovered) painter.FillRounded(close, 15, palette::kButtonHover);
    painter.Glyph(gfx::glyph::kClose, 11, close, palette::kSecondaryText);
    AddHit(close, HitId{HitKind::Close}, L"Close (Esc)");

    D2D1_RECT_F quit = gfx::Rect(close.left - 8 - 34, centerY - 15, 34, 30);
    bool quitHovered = hover_.kind == HitKind::Quit;
    if (quitHovered) painter.FillRounded(quit, 15, gfx::WithAlpha(palette::kRed, 0.92f));
    painter.Glyph(gfx::glyph::kPower, 14, quit, quitHovered ? gfx::Rgb(1, 1, 1) : palette::kRed);
    AddHit(quit, HitId{HitKind::Quit}, L"Quit");
}

std::optional<D2D1_SIZE_U> MainWindow::ImageSize(const ClipboardItem& item) {
    auto found = imageSizes_.find(item.id);
    if (found != imageSizes_.end()) return found->second;
    UINT width = 0, height = 0;
    if (!imaging::ImageFileSize(app_.Clipboard().ImagePath(item), width, height) || width == 0 || height == 0) {
        return std::nullopt;
    }
    imageSizes_[item.id] = D2D1::SizeU(width, height);
    return D2D1::SizeU(width, height);
}

float MainWindow::TextHeight(const std::wstring& text, IDWriteTextFormat* format, float width, int maxLines) {
    std::wstring measured = text.size() > kMaxMeasuredCharacters ? text.substr(0, kMaxMeasuredCharacters) : text;
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(gfx::DWriteFactory()->CreateTextLayout(measured.c_str(), static_cast<UINT32>(measured.size()), format,
                                                      std::max(1.0f, width), 100000.0f, &layout))) {
        return 20;
    }
    layout->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);
    UINT32 lineCount = 0;
    layout->GetLineMetrics(nullptr, 0, &lineCount);
    std::vector<DWRITE_LINE_METRICS> lines(lineCount);
    if (lineCount == 0 || FAILED(layout->GetLineMetrics(lines.data(), lineCount, &lineCount))) return 20;

    float height = 0;
    for (UINT32 i = 0; i < lineCount && static_cast<int>(i) < maxLines; ++i) height += lines[i].height;
    return std::ceil(height);
}

float MainWindow::CardHeight(const ClipboardItem& item, float width) {
    float inner = width - kCardPadding * 2;
    float contentWidth = inner - 12 - kActionWidth;
    float headerHeight = std::ceil(gfx::MeasureText(L"Ag", SecondarySemibold()).height);

    float contentHeight = 0;
    if (item.IsImage()) {
        auto size = ImageSize(item);
        contentHeight = size ? std::min(kImageMaxHeight, contentWidth * size->height / std::max<UINT32>(size->width, 1))
                             : 120.0f;
        contentHeight = std::max(contentHeight, 40.0f);
    } else {
        if (textHeightWidth_ != contentWidth) {
            textHeights_.clear();
            textHeightWidth_ = contentWidth;
        }
        auto found = textHeights_.find(item.id);
        if (found == textHeights_.end()) {
            found = textHeights_.emplace(item.id, TextHeight(item.text, Body(), contentWidth, kMaxTextLines)).first;
        }
        contentHeight = found->second;
    }

    float body = std::max(contentHeight, 30.0f);
    return std::min(kCardMaxHeight, kCardPadding + headerHeight + 12 + body + kCardPadding);
}

std::vector<MainWindow::CardLayout> MainWindow::LayoutCards(float width) {
    std::vector<CardLayout> layout;
    float top = kListPadding;
    for (const auto& item : app_.Clipboard().Items()) {
        float height = CardHeight(item, width);
        layout.push_back(CardLayout{item.id, top, height});
        top += height + kCardSpacing;
    }
    return layout;
}

void MainWindow::DrawHistory(gfx::Painter& painter, const D2D1_RECT_F& content) {
    const auto& items = app_.Clipboard().Items();
    if (items.empty()) {
        contentHeight_[0] = 0;
        float centerY = (content.top + content.bottom) / 2;
        painter.Glyph(gfx::glyph::kClipboard, 40, D2D1::RectF(content.left, centerY - 70, content.right, centerY - 20),
                      palette::kSecondaryText);
        painter.Text(L"No Clipboard History", Title(), D2D1::RectF(content.left, centerY - 12, content.right, centerY + 14),
                     palette::kPrimaryText, DWRITE_TEXT_ALIGNMENT_CENTER);
        painter.Text(L"Copied text and images will appear here automatically.", Body(),
                     D2D1::RectF(content.left, centerY + 18, content.right, centerY + 40), palette::kSecondaryText,
                     DWRITE_TEXT_ALIGNMENT_CENTER);
        return;
    }

    float width = content.right - content.left - kListPadding * 2;
    auto layout = LayoutCards(width);
    contentHeight_[0] = layout.back().top + layout.back().height + kListPadding;
    scroll_[0] = std::min(std::max(scroll_[0], 0.0f), MaxScroll());

    for (size_t i = 0; i < layout.size(); ++i) {
        float top = content.top + layout[i].top - scroll_[0];
        if (top > content.bottom || top + layout[i].height < content.top) continue;
        D2D1_RECT_F rect = gfx::Rect(content.left + kListPadding, top, width, layout[i].height);
        DrawCard(painter, items[i], rect, items[i].id == selectedId_);
    }
}

void MainWindow::DrawCard(gfx::Painter& painter, const ClipboardItem& item, const D2D1_RECT_F& rect, bool selected) {
    painter.FillRounded(rect, 8, selected ? palette::kSelectedBackground : palette::kCardBackground);
    painter.StrokeRounded(rect, 8, selected ? gfx::AccentColor() : gfx::WithAlpha(palette::kSeparator, 0.75f),
                          selected ? 2.0f : 1.0f);
    AddHit(rect, HitId{HitKind::Card, 0, item.id});

    D2D1_RECT_F inner = gfx::Inset(rect, kCardPadding, kCardPadding);
    float headerHeight = std::ceil(gfx::MeasureText(L"Ag", SecondarySemibold()).height);

    std::wstring source = item.sourceApplicationName.empty() ? L"Unknown App" : item.sourceApplicationName;
    float sourceWidth = std::min(gfx::MeasureText(source, SecondarySemibold()).width + 1, (inner.right - inner.left) / 2);
    painter.Text(source, SecondarySemibold(), gfx::Rect(inner.left, inner.top, sourceWidth, headerHeight),
                 palette::kPrimaryText);
    painter.Text(FormatTimestamp(item.createdAt), Secondary(),
                 D2D1::RectF(inner.left + sourceWidth + 16, inner.top, inner.right, inner.top + headerHeight),
                 palette::kSecondaryText);

    float contentTop = inner.top + headerHeight + 12;
    D2D1_RECT_F contentRect = D2D1::RectF(inner.left, contentTop, inner.right - 12 - kActionWidth, inner.bottom);
    if (item.IsImage()) {
        DrawImagePreview(painter, item, contentRect);
    } else {
        painter.Text(item.text.size() > kMaxMeasuredCharacters ? item.text.substr(0, kMaxMeasuredCharacters) : item.text,
                     Body(), contentRect, palette::kPrimaryText, DWRITE_TEXT_ALIGNMENT_LEADING,
                     DWRITE_PARAGRAPH_ALIGNMENT_NEAR, true, true);
    }

    bool canUse = item.IsImage() || !IsBlank(item.text);
    struct Action {
        HitKind kind;
        wchar_t glyph;
        D2D1_COLOR_F color;
        const wchar_t* tip;
        bool enabled;
    };
    const Action actions[] = {{HitKind::CardCopy, gfx::glyph::kCopy, palette::kBlue, L"Copy and paste", canUse},
                              {HitKind::CardDelete, gfx::glyph::kDelete, palette::kRed, L"Delete", true}};
    float x = inner.right - 34 - 8 - 34;
    for (const auto& action : actions) {
        D2D1_RECT_F button = gfx::Rect(x, contentTop, 34, 30);
        HitId id{action.kind, 0, item.id};
        bool hovered = hover_ == id && action.enabled;
        if (hovered) painter.FillRounded(button, 15, gfx::WithAlpha(action.color, 0.92f));
        D2D1_COLOR_F ink = hovered ? gfx::Rgb(1, 1, 1) : gfx::WithAlpha(action.color, action.enabled ? 1.0f : 0.35f);
        painter.Glyph(action.glyph, 14, button, ink);
        if (action.enabled) AddHit(button, id, action.tip);
        x += 34 + 8;
    }
}

void MainWindow::DrawImagePreview(gfx::Painter& painter, const ClipboardItem& item, const D2D1_RECT_F& available) {
    auto size = ImageSize(item);
    float width = available.right - available.left;
    float height = size ? std::min(kImageMaxHeight, width * size->height / std::max<UINT32>(size->width, 1)) : 120.0f;
    height = std::min(std::max(height, 40.0f), available.bottom - available.top);
    D2D1_RECT_F frame = gfx::Rect(available.left, available.top, width, height);

    ComPtr<ID2D1RoundedRectangleGeometry> clip;
    gfx::D2DFactory()->CreateRoundedRectangleGeometry(D2D1::RoundedRect(frame, 6, 6), &clip);
    if (clip) target_->PushLayer(D2D1::LayerParameters(D2D1::InfiniteRect(), clip.Get()), nullptr);
    painter.Fill(frame, gfx::Rgb(1, 1, 1, 0.55f));

    auto found = thumbnails_.find(item.id);
    if (found != thumbnails_.end() && found->second) {
        D2D1_SIZE_F bitmapSize = found->second->GetPixelSize().width > 0
            ? D2D1::SizeF(static_cast<float>(found->second->GetPixelSize().width),
                          static_cast<float>(found->second->GetPixelSize().height))
            : D2D1::SizeF(1, 1);
        float fit = std::min(width / bitmapSize.width, height / bitmapSize.height);
        D2D1_RECT_F image = gfx::Rect(frame.left, frame.top + (height - bitmapSize.height * fit) / 2,
                                      bitmapSize.width * fit, bitmapSize.height * fit);
        target_->DrawBitmap(found->second.Get(), image, 1.0f, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
    } else {
        painter.Glyph(gfx::glyph::kPicture, 20, frame, palette::kSecondaryText);
        RequestThumbnail(item, frame);
    }
    if (clip) target_->PopLayer();
}

void MainWindow::DrawButton(gfx::Painter& painter, const D2D1_RECT_F& rect, const std::wstring& title, HitId id,
                            bool emphasized) {
    bool hovered = hover_ == id;
    painter.FillRounded(rect, 6, emphasized ? gfx::WithAlpha(gfx::AccentColor(), 0.12f)
                                            : (hovered ? palette::kButtonHover : gfx::Rgb(1, 1, 1)));
    painter.StrokeRounded(rect, 6, emphasized ? gfx::AccentColor() : palette::kSeparator, emphasized ? 1.5f : 1.0f);
    painter.Text(title, Body(), rect, palette::kPrimaryText, DWRITE_TEXT_ALIGNMENT_CENTER);
    AddHit(rect, std::move(id));
}

float MainWindow::DrawRecorderButton(gfx::Painter& painter, HotKeyCommand command, float right, float centerY,
                                     bool compact) {
    bool recording = recordingCommand_ == command;
    std::wstring text = recording ? L"Press New Shortcut" : app_.HotKeys().Shortcut(command).DisplayString();
    float buttonWidth = std::ceil(gfx::MeasureText(text, Mono()).width) + 24;
    D2D1_RECT_F button = D2D1::RectF(right - buttonWidth, centerY - 14, right, centerY + 14);

    HitId id{HitKind::ShortcutButton, static_cast<int>(command)};
    bool hovered = hover_ == id;
    painter.FillRounded(button, 6, recording ? gfx::WithAlpha(gfx::AccentColor(), 0.12f)
                                             : (hovered ? palette::kButtonHover : gfx::Rgb(1, 1, 1)));
    painter.StrokeRounded(button, 6, recording ? gfx::AccentColor() : palette::kSeparator, recording ? 1.5f : 1.0f);
    painter.Text(text, Mono(), button, recording ? gfx::AccentColor() : palette::kPrimaryText,
                 DWRITE_TEXT_ALIGNMENT_CENTER);
    hits_.push_back(HitRegion{button, id, recording ? L"Press Esc to keep the current shortcut"
                                                    : L"Click, then press the new shortcut"});

    float used = buttonWidth;
    if (compact) {
        std::wstring title = HotKeyCommandTitle(command);
        float labelWidth = std::ceil(gfx::MeasureText(title, Secondary()).width) + 1;
        painter.Text(title, Secondary(),
                     D2D1::RectF(button.left - 6 - labelWidth, centerY - 10, button.left - 6, centerY + 10),
                     palette::kSecondaryText);
        used += 6 + labelWidth;
    }
    return used;
}

float MainWindow::DrawStatusRow(gfx::Painter& painter, float top, float left, float right, wchar_t glyph,
                                D2D1_COLOR_F color, const std::wstring& text, HitKind dismiss) {
    float dismissWidth = dismiss != HitKind::None ? 84.0f : 0.0f;
    float textLeft = left + 26;
    float textRight = right - dismissWidth;
    float height = std::max(28.0f, TextHeight(text, Body(), textRight - textLeft, 6) + 6);

    painter.Glyph(glyph, 15, gfx::Rect(left, top + (height - 20) / 2, 18, 20), color);
    painter.Text(text, Body(), D2D1::RectF(textLeft, top, textRight, top + height), color,
                 DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_PARAGRAPH_ALIGNMENT_CENTER, true, true);
    if (dismiss != HitKind::None) {
        DrawButton(painter, D2D1::RectF(right - 72, top + (height - 28) / 2, right, top + (height + 28) / 2),
                   L"Dismiss", HitId{dismiss});
    }
    return height;
}

void MainWindow::DrawShortcuts(gfx::Painter& painter, const D2D1_RECT_F& content) {
    const float rowHeight = 30, spacing = 14;
    float left = content.left + 28, right = content.right - 28;
    float y = content.top + 24 - scroll_[1];

    for (HotKeyCommand command : kStandaloneCommands) {
        painter.Text(HotKeyCommandTitle(command), Body(), D2D1::RectF(left, y, right - 260, y + rowHeight),
                     palette::kPrimaryText);
        DrawRecorderButton(painter, command, right, y + rowHeight / 2, false);
        y += rowHeight + spacing;
    }

    painter.Text(L"Move Window", Body(), D2D1::RectF(left, y, right, y + rowHeight), palette::kPrimaryText);
    float x = right;
    for (auto it = kMoveCommands.rbegin(); it != kMoveCommands.rend(); ++it) {
        x -= DrawRecorderButton(painter, *it, x, y + rowHeight / 2, true) + 12;
    }
    y += rowHeight + spacing;

    painter.Fill(D2D1::RectF(left, y, right, y + 1), palette::kSeparator);
    y += 1 + spacing;

    y += DrawStatusRow(painter, y, left, right, gfx::glyph::kInfo, palette::kSecondaryText,
                       L"Windows of apps running as administrator can be arranged only while Space also runs as "
                       L"administrator.",
                       HitKind::None) + spacing;

    // Open at Login: a switch, then Check.
    LoginItemService& login = app_.LoginItem();
    {
        D2D1_RECT_F toggle = gfx::Rect(left, y + 4, 40, 22);
        bool on = login.IsEnabled();
        painter.FillRounded(toggle, 11, on ? gfx::AccentColor() : gfx::Rgb(0.78f, 0.79f, 0.81f));
        float knobX = on ? toggle.right - 11 : toggle.left + 11;
        painter.FillEllipse(D2D1::Point2F(knobX, (toggle.top + toggle.bottom) / 2), 8.5f, 8.5f, gfx::Rgb(1, 1, 1));
        painter.Glyph(gfx::glyph::kPower, 14, gfx::Rect(toggle.right + 12, y, 18, rowHeight), palette::kPrimaryText);
        float labelWidth = gfx::MeasureText(L"Open Space at Login", Body()).width + 2;
        painter.Text(L"Open Space at Login", Body(), gfx::Rect(toggle.right + 38, y, labelWidth, rowHeight),
                     palette::kPrimaryText);
        AddHit(D2D1::RectF(toggle.left, y, toggle.right + 38 + labelWidth, y + rowHeight), HitId{HitKind::LoginToggle});
        DrawButton(painter, D2D1::RectF(right - 72, y + 1, right, y + rowHeight - 1), L"Check", HitId{HitKind::LoginCheck});
        y += rowHeight + spacing;
    }

    if (!login.LastMessage().empty()) {
        y += DrawStatusRow(painter, y, left, right, gfx::glyph::kWarning, palette::kOrange, login.LastMessage(),
                           HitKind::DismissLogin) + spacing;
    }
    if (!app_.HotKeys().RegistrationError().empty()) {
        y += DrawStatusRow(painter, y, left, right, gfx::glyph::kWarning, palette::kOrange,
                           app_.HotKeys().RegistrationError(), HitKind::None) + spacing;
    }
    if (!app_.HotKeys().LastEventMessage().empty()) {
        y += DrawStatusRow(painter, y, left, right, gfx::glyph::kKeyboard, palette::kOrange,
                           app_.HotKeys().LastEventMessage(), HitKind::None) + spacing;
    }
    if (!app_.Capture().LastMessage().empty()) {
        y += DrawStatusRow(painter, y, left, right, gfx::glyph::kPicture, palette::kOrange, app_.Capture().LastMessage(),
                           HitKind::DismissCapture) + spacing;
    }

    RecordingService& recording = app_.Recording();
    {
        bool active = recording.IsRecording();
        std::wstring fileName = LastPathComponent(recording.OutputPath());
        float nameWidth = fileName.empty() ? 0 : std::min(gfx::MeasureText(fileName, Secondary()).width + 2, 320.0f);
        DrawStatusRow(painter, y, left, right - nameWidth - 12, gfx::glyph::kVideo,
                      active ? palette::kRed : palette::kSecondaryText,
                      active ? L"Recording in progress" : L"Screen recording is idle", HitKind::None);
        if (!fileName.empty()) {
            painter.Text(fileName, Secondary(), D2D1::RectF(right - nameWidth, y, right, y + 28), palette::kSecondaryText,
                         DWRITE_TEXT_ALIGNMENT_TRAILING);
        }
        y += 28 + spacing;
    }
    if (!recording.LastMessage().empty()) {
        y += DrawStatusRow(painter, y, left, right, gfx::glyph::kVideo,
                           recording.IsRecording() ? palette::kRed : palette::kSecondaryText, recording.LastMessage(),
                           HitKind::DismissRecording) + spacing;
    }
    if (!app_.Windows().LastMessage().empty()) {
        float height = TextHeight(app_.Windows().LastMessage(), Secondary(), right - left, 4) + 4;
        painter.Text(app_.Windows().LastMessage(), Secondary(), D2D1::RectF(left, y, right, y + height),
                     palette::kSecondaryText, DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_PARAGRAPH_ALIGNMENT_NEAR, true, true);
        y += height + spacing;
    }

    contentHeight_[1] = y - spacing + 24 + scroll_[1] - content.top;
    scroll_[1] = std::min(std::max(scroll_[1], 0.0f), MaxScroll());
}

void MainWindow::DrawScrollbar(gfx::Painter& painter, const D2D1_RECT_F& viewport) {
    int index = tab_ == Tab::History ? 0 : 1;
    float viewportHeight = viewport.bottom - viewport.top;
    if (contentHeight_[index] <= viewportHeight + 0.5f) return;

    float thumbHeight = std::max(30.0f, viewportHeight * viewportHeight / contentHeight_[index]);
    float maxScroll = MaxScroll();
    float thumbTop = viewport.top + (viewportHeight - thumbHeight) * (maxScroll > 0 ? scroll_[index] / maxScroll : 0);
    bool active = hover_.kind == HitKind::ScrollThumb || thumbDragOffset_.has_value();
    float thumbWidth = active ? 8.0f : 5.0f;
    D2D1_RECT_F thumb = gfx::Rect(viewport.right - thumbWidth - 3, thumbTop + 2, thumbWidth, thumbHeight - 4);
    painter.FillRounded(thumb, thumbWidth / 2, gfx::Rgb(0, 0, 0, active ? 0.4f : 0.22f));
    AddHit(D2D1::RectF(viewport.right - 14, thumbTop, viewport.right, thumbTop + thumbHeight), HitId{HitKind::ScrollThumb});
}

// ---------------------------------------------------------------------------------------
// Interaction

std::optional<MainWindow::HitRegion> MainWindow::HitAt(float x, float y) const {
    for (auto it = hits_.rbegin(); it != hits_.rend(); ++it) {
        if (gfx::Contains(it->rect, x, y)) return *it;
    }
    return std::nullopt;
}

float MainWindow::MaxScroll() const {
    int index = tab_ == Tab::History ? 0 : 1;
    return std::max(0.0f, contentHeight_[index] - viewportHeight_);
}

void MainWindow::UpdateTooltip(const std::optional<HitRegion>& region) {
    if (!tooltip_) return;
    static std::wstring text;
    text = region ? region->tooltip : std::wstring();

    TOOLINFOW info{};
    info.cbSize = sizeof(info);
    info.hwnd = hwnd_;
    info.uId = 1;
    if (region && !text.empty()) {
        info.rect = RECT{static_cast<LONG>(region->rect.left * scale_), static_cast<LONG>(region->rect.top * scale_),
                         static_cast<LONG>(region->rect.right * scale_), static_cast<LONG>(region->rect.bottom * scale_)};
    }
    info.lpszText = text.data();
    SendMessageW(tooltip_, TTM_NEWTOOLRECTW, 0, reinterpret_cast<LPARAM>(&info));
    SendMessageW(tooltip_, TTM_UPDATETIPTEXTW, 0, reinterpret_cast<LPARAM>(&info));
    if (text.empty()) SendMessageW(tooltip_, TTM_POP, 0, 0);
}

void MainWindow::MouseMove(float x, float y) {
    if (thumbDragOffset_) {
        D2D1_RECT_F content = ContentRect();
        float viewportHeight = content.bottom - content.top;
        int index = tab_ == Tab::History ? 0 : 1;
        float thumbHeight = std::max(30.0f, viewportHeight * viewportHeight / std::max(contentHeight_[index], 1.0f));
        float track = viewportHeight - thumbHeight;
        float thumbTop = y - *thumbDragOffset_ - content.top;
        if (track > 0) ScrollTo(thumbTop / track * MaxScroll(), false);
        return;
    }

    auto region = HitAt(x, y);
    HitId id = region ? region->id : HitId{};
    if (id != hover_) {
        hover_ = id;
        UpdateTooltip(region);
        InvalidateRect(hwnd_, nullptr, FALSE);
    }
}

void MainWindow::MouseDown(float x, float y) {
    auto region = HitAt(x, y);
    pressed_ = region ? region->id : HitId{};
    if (pressed_.kind == HitKind::ScrollThumb) thumbDragOffset_ = y - region->rect.top;
}

void MainWindow::MouseUp(float x, float y) {
    if (thumbDragOffset_) {
        thumbDragOffset_.reset();
        pressed_ = {};
        InvalidateRect(hwnd_, nullptr, FALSE);
        return;
    }
    auto region = HitAt(x, y);
    HitId pressed = pressed_;
    pressed_ = {};
    if (region && region->id == pressed) Activate(pressed);
}

void MainWindow::Activate(const HitId& id) {
    switch (id.kind) {
        case HitKind::Close: Hide(); return;
        case HitKind::Tab: SelectTab(id.index == 0 ? Tab::History : Tab::Shortcuts); return;
        case HitKind::Quit: app_.Quit(); return;
        case HitKind::DismissError: app_.Clipboard().ClearError(); return;
        case HitKind::Card:
            selectedId_ = id.itemId;
            InvalidateRect(hwnd_, nullptr, FALSE);
            return;
        case HitKind::CardCopy:
            selectedId_ = id.itemId;
            Pick(id.itemId);
            return;
        case HitKind::CardDelete: app_.Clipboard().Delete(id.itemId); return;
        case HitKind::ShortcutButton: StartRecording(static_cast<HotKeyCommand>(id.index)); return;
        case HitKind::LoginToggle: app_.LoginItem().SetEnabled(!app_.LoginItem().IsEnabled()); return;
        case HitKind::LoginCheck: app_.LoginItem().Refresh(); InvalidateRect(hwnd_, nullptr, FALSE); return;
        case HitKind::DismissLogin: app_.LoginItem().ClearMessage(); return;
        case HitKind::DismissCapture: app_.Capture().ClearMessage(); return;
        case HitKind::DismissRecording: app_.Recording().ClearMessage(); return;
        case HitKind::ScrollThumb:
        case HitKind::None: return;
    }
}

void MainWindow::Wheel(int delta) {
    UINT lines = 3;
    SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
    if (lines == WHEEL_PAGESCROLL) lines = 12;
    int index = tab_ == Tab::History ? 0 : 1;
    ScrollTo(scroll_[index] - static_cast<float>(delta) / WHEEL_DELTA * lines * 20.0f, false);
}

void MainWindow::ScrollTo(float offset, bool animated) {
    int index = tab_ == Tab::History ? 0 : 1;
    offset = std::min(std::max(offset, 0.0f), MaxScroll());
    if (!animated) {
        KillTimer(hwnd_, kScrollAnimationTimer);
        scroll_[index] = offset;
        InvalidateRect(hwnd_, nullptr, FALSE);
        return;
    }
    scrollAnimationFrom_ = scroll_[index];
    scrollAnimationTo_ = offset;
    scrollAnimationStart_ = GetTickCount64();
    SetTimer(hwnd_, kScrollAnimationTimer, 10, nullptr);
}

void MainWindow::StepScrollAnimation() {
    double progress = std::min(1.0, static_cast<double>(GetTickCount64() - scrollAnimationStart_) / kScrollAnimationMs);
    int index = tab_ == Tab::History ? 0 : 1;
    scroll_[index] = static_cast<float>(scrollAnimationFrom_ + (scrollAnimationTo_ - scrollAnimationFrom_) * EaseInOut(progress));
    if (progress >= 1.0) KillTimer(hwnd_, kScrollAnimationTimer);
    InvalidateRect(hwnd_, nullptr, FALSE);
}

void MainWindow::ScrollSelectionIntoView() {
    D2D1_RECT_F content = ContentRect();
    float width = content.right - content.left - kListPadding * 2;
    for (const auto& card : LayoutCards(width)) {
        if (card.id != selectedId_) continue;
        ScrollTo(card.top + card.height / 2 - viewportHeight_ / 2, true);
        return;
    }
}

void MainWindow::SelectTab(Tab tab) {
    if (tab_ == tab) return;
    tab_ = tab;
    hover_ = {};
    InvalidateRect(hwnd_, nullptr, FALSE);
}

void MainWindow::KeyDown(UINT key) {
    switch (key) {
        case VK_ESCAPE:
            Hide();
            return;
        case VK_UP:
            if (tab_ == Tab::History) MoveSelection(-1);
            return;
        case VK_DOWN:
            if (tab_ == Tab::History) MoveSelection(1);
            return;
        case VK_RETURN:
            if (tab_ == Tab::History && !selectedId_.empty()) Pick(selectedId_);
            return;
        default:
            return;
    }
}

void MainWindow::MoveSelection(int offset) {
    const auto& items = app_.Clipboard().Items();
    if (items.empty()) return;
    auto current = std::find_if(items.begin(), items.end(), [this](const ClipboardItem& item) {
        return item.id == selectedId_;
    });
    if (current == items.end()) {
        selectedId_ = items.front().id;
    } else {
        int index = static_cast<int>(current - items.begin()) + offset;
        index = std::min(std::max(index, 0), static_cast<int>(items.size()) - 1);
        selectedId_ = items[static_cast<size_t>(index)].id;
    }
    ScrollSelectionIntoView();
    InvalidateRect(hwnd_, nullptr, FALSE);
}

// Copies an entry, moves it to the top, and pastes it into the window the panel was
// opened over. Enter and the card's copy button both end here.
void MainWindow::Pick(const std::wstring& id) {
    if (!app_.Clipboard().CopyToClipboard(id)) return;
    app_.Clipboard().Promote(id);
    HWND target = previousForeground_;
    Hide();
    app_.PasteInto(target);
}

// ---------------------------------------------------------------------------------------
// Shortcut recording

// While a recorder waits, a low-level hook takes every key so that combinations Windows
// would otherwise act on (Win+arrows, for one) reach the recorder instead.
LRESULT CALLBACK MainWindow::KeyboardHook(int code, WPARAM wParam, LPARAM lParam) {
    if (code == HC_ACTION && hookTarget_) {
        const auto* info = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lParam);
        if (!(info->flags & LLKHF_INJECTED) && !IsModifierKey(info->vkCode)) {
            if (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN) {
                UINT modifiers = 0;
                if (GetAsyncKeyState(VK_CONTROL) < 0) modifiers |= MOD_CONTROL;
                if (GetAsyncKeyState(VK_MENU) < 0) modifiers |= MOD_ALT;
                if (GetAsyncKeyState(VK_SHIFT) < 0) modifiers |= MOD_SHIFT;
                if (GetAsyncKeyState(VK_LWIN) < 0 || GetAsyncKeyState(VK_RWIN) < 0) modifiers |= MOD_WIN;

                if (modifiers & MOD_WIN) {
                    // A Win press with nothing after it opens Start; a masking key press
                    // tells Windows the Win key was used in a combination.
                    INPUT mask[2] = {};
                    mask[0].type = mask[1].type = INPUT_KEYBOARD;
                    mask[0].ki.wVk = mask[1].ki.wVk = 0xE8;
                    mask[1].ki.dwFlags = KEYEVENTF_KEYUP;
                    SendInput(2, mask, sizeof(INPUT));
                }

                bool bareEscape = info->vkCode == VK_ESCAPE && modifiers == 0;
                PostMessageW(hookTarget_, bareEscape ? WM_APP_SHORTCUT_CANCEL : WM_APP_SHORTCUT_KEY, info->vkCode,
                             modifiers);
            }
            return 1;
        }
    }
    return CallNextHookEx(nullptr, code, wParam, lParam);
}

void MainWindow::StartRecording(HotKeyCommand command) {
    if (recordingCommand_ == command) return;
    // Hotkey suspension is shared, so end any other recorder before starting this one.
    CancelRecording();

    app_.HotKeys().Suspend();
    hookTarget_ = hwnd_;
    keyboardHook_ = SetWindowsHookExW(WH_KEYBOARD_LL, &MainWindow::KeyboardHook, GetModuleHandleW(nullptr), 0);
    recordingCommand_ = command;
    InvalidateRect(hwnd_, nullptr, FALSE);
}

void MainWindow::FinishRecording() {
    if (!recordingCommand_) return;
    if (keyboardHook_) UnhookWindowsHookEx(keyboardHook_);
    keyboardHook_ = nullptr;
    hookTarget_ = nullptr;
    recordingCommand_.reset();
    app_.HotKeys().Resume();
    if (hwnd_) InvalidateRect(hwnd_, nullptr, FALSE);
}

void MainWindow::CancelRecording() {
    FinishRecording();
}

void MainWindow::HandleRecordedKey(UINT virtualKey, UINT modifiers) {
    if (!recordingCommand_) return;
    HotKeyCombo combo{virtualKey, modifiers};
    if (!combo.IsSafeGlobalShortcut()) {
        MessageBeep(MB_ICONWARNING);
        return;
    }
    HotKeyCommand command = *recordingCommand_;
    FinishRecording();
    app_.HotKeys().UpdateShortcut(combo, command);
}

// ---------------------------------------------------------------------------------------
// Thumbnails

void MainWindow::RequestThumbnail(const ClipboardItem& item, const D2D1_RECT_F& rect) {
    if (thumbnailRequested_.count(item.id)) return;
    thumbnailRequested_[item.id] = true;
    // Decode only as many pixels as the preview shows.
    UINT maxWidth = static_cast<UINT>(std::ceil((rect.right - rect.left) * scale_));
    UINT maxHeight = static_cast<UINT>(std::ceil(kImageMaxHeight * scale_));
    thumbnailLoader_->Request(item.id, app_.Clipboard().ImagePath(item), maxWidth, maxHeight);
}

void MainWindow::ThumbnailReady(LPARAM payload) {
    std::unique_ptr<ThumbnailLoader::Result> result(reinterpret_cast<ThumbnailLoader::Result*>(payload));
    if (!result || !app_.Clipboard().Find(result->id)) return;
    if (!result->bitmap || !EnsureTarget()) return;

    ComPtr<ID2D1Bitmap> bitmap;
    const imaging::Bitmap& pixels = *result->bitmap;
    if (FAILED(target_->CreateBitmap(D2D1::SizeU(pixels.width, pixels.height), pixels.pixels.data(), pixels.width * 4,
                                     D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                                                                              D2D1_ALPHA_MODE_PREMULTIPLIED)),
                                     &bitmap))) {
        return;
    }
    thumbnails_[result->id] = bitmap;
    thumbnailOrder_.push_back(result->id);
    while (thumbnailOrder_.size() > kMaxThumbnails) {
        std::wstring oldest = thumbnailOrder_.front();
        thumbnailOrder_.pop_front();
        thumbnails_.erase(oldest);
        thumbnailRequested_.erase(oldest);
    }
    if (IsVisible()) InvalidateRect(hwnd_, nullptr, FALSE);
}

void MainWindow::PruneThumbnails() {
    auto exists = [this](const std::wstring& id) { return app_.Clipboard().Find(id) != nullptr; };
    for (auto it = thumbnails_.begin(); it != thumbnails_.end();) {
        it = exists(it->first) ? std::next(it) : thumbnails_.erase(it);
    }
    for (auto it = thumbnailRequested_.begin(); it != thumbnailRequested_.end();) {
        it = exists(it->first) ? std::next(it) : thumbnailRequested_.erase(it);
    }
    for (auto it = imageSizes_.begin(); it != imageSizes_.end();) {
        it = exists(it->first) ? std::next(it) : imageSizes_.erase(it);
    }
    for (auto it = textHeights_.begin(); it != textHeights_.end();) {
        it = exists(it->first) ? std::next(it) : textHeights_.erase(it);
    }
    thumbnailOrder_.erase(std::remove_if(thumbnailOrder_.begin(), thumbnailOrder_.end(),
                                         [&](const std::wstring& id) { return !exists(id); }),
                          thumbnailOrder_.end());
}

}  // namespace space
