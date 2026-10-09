// Purpose: Implements window layouts with SetWindowPos, compensating for the invisible
// resize borders Windows 10 and 11 put around most windows.

#include "window_manager.h"

#include <dwmapi.h>

#include <algorithm>
#include <cmath>

namespace space {

namespace {

constexpr ULONGLONG kAnimationDurationMs = 180;
constexpr UINT kAnimationIntervalMs = 15;

LONG Width(const RECT& rect) { return rect.right - rect.left; }
LONG Height(const RECT& rect) { return rect.bottom - rect.top; }

LONG Clamped(LONG value, LONG minimum, LONG maximum) {
    if (minimum > maximum) return minimum;
    return std::min(std::max(value, minimum), maximum);
}

double EaseOutCubic(double progress) {
    return 1 - std::pow(1 - progress, 3);
}

RECT Interpolate(const RECT& start, const RECT& end, double progress) {
    auto mix = [progress](LONG a, LONG b) { return static_cast<LONG>(std::lround(a + (b - a) * progress)); };
    return RECT{mix(start.left, end.left), mix(start.top, end.top), mix(start.right, end.right),
                mix(start.bottom, end.bottom)};
}

const wchar_t* LayoutTitle(WindowLayoutMode mode) {
    switch (mode) {
        case WindowLayoutMode::LeftHalf: return L"Left Two Thirds";
        case WindowLayoutMode::RightHalf: return L"Right Two Thirds";
        case WindowLayoutMode::CenterHalf: return L"Center Two Thirds";
    }
    return L"";
}

const wchar_t* PositionTitle(WindowMovePosition position) {
    switch (position) {
        case WindowMovePosition::Left: return L"left";
        case WindowMovePosition::Center: return L"center";
        case WindowMovePosition::Right: return L"right";
    }
    return L"";
}

bool WorkAreaForWindow(HWND hwnd, RECT& workArea) {
    MONITORINFO info{sizeof(info)};
    if (!GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &info)) return false;
    workArea = info.rcWork;
    return true;
}

}  // namespace

namespace layout {

RECT TargetFrame(WindowLayoutMode mode, const RECT& workArea) {
    LONG targetWidth = static_cast<LONG>(std::floor(Width(workArea) * 2.0 / 3.0));
    LONG left = workArea.left;
    switch (mode) {
        case WindowLayoutMode::LeftHalf: left = workArea.left; break;
        case WindowLayoutMode::RightHalf: left = workArea.right - targetWidth; break;
        case WindowLayoutMode::CenterHalf: left = workArea.left + (Width(workArea) - targetWidth) / 2; break;
    }
    return RECT{left, workArea.top, left + targetWidth, workArea.bottom};
}

RECT TargetFrame(WindowMovePosition position, const RECT& currentFrame, const RECT& workArea) {
    LONG width = Width(currentFrame);
    LONG height = Height(currentFrame);
    LONG left = workArea.left;
    switch (position) {
        case WindowMovePosition::Left: left = workArea.left; break;
        case WindowMovePosition::Center: left = workArea.left + (Width(workArea) - width) / 2; break;
        case WindowMovePosition::Right: left = workArea.right - width; break;
    }
    LONG top = Clamped(currentFrame.top, workArea.top, workArea.bottom - height);
    return RECT{left, top, left + width, top + height};
}

}  // namespace layout

bool VisibleFrame(HWND hwnd, RECT& frame) {
    if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &frame, sizeof(frame)))) return true;
    return GetWindowRect(hwnd, &frame) != FALSE;
}

std::wstring AppNameForWindow(HWND hwnd) {
    DWORD processId = 0;
    GetWindowThreadProcessId(hwnd, &processId);

    // Store apps draw inside a frame window owned by ApplicationFrameHost; the app itself
    // is the process behind its CoreWindow child.
    wchar_t className[64] = {};
    GetClassNameW(hwnd, className, 64);
    if (wcscmp(className, L"ApplicationFrameWindow") == 0) {
        struct Search {
            DWORD frameProcess;
            DWORD appProcess;
        } search{processId, 0};
        EnumChildWindows(
            hwnd,
            [](HWND child, LPARAM parameter) -> BOOL {
                auto* state = reinterpret_cast<Search*>(parameter);
                DWORD childProcess = 0;
                GetWindowThreadProcessId(child, &childProcess);
                if (childProcess != state->frameProcess) {
                    state->appProcess = childProcess;
                    return FALSE;
                }
                return TRUE;
            },
            reinterpret_cast<LPARAM>(&search));
        if (search.appProcess) processId = search.appProcess;
    }

    std::wstring name = ProcessDisplayName(processId);
    return name.empty() ? L"The current app" : name;
}

WindowManager* WindowManager::instance_ = nullptr;

WindowManager::WindowManager() {
    instance_ = this;
    hook_ = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr, &WindowManager::ForegroundChanged,
                            0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    HWND foreground = GetForegroundWindow();
    if (IsArrangeable(foreground)) lastTarget_ = foreground;
}

WindowManager::~WindowManager() {
    if (hook_) UnhookWinEvent(hook_);
    if (instance_ == this) instance_ = nullptr;
}

void WindowManager::Attach(HWND timerWindow) {
    timerWindow_ = timerWindow;
}

void CALLBACK WindowManager::ForegroundChanged(HWINEVENTHOOK, DWORD, HWND hwnd, LONG objectId, LONG, DWORD, DWORD) {
    if (!instance_ || objectId != OBJID_WINDOW) return;
    HWND root = hwnd ? GetAncestor(hwnd, GA_ROOT) : nullptr;
    if (IsArrangeable(root)) instance_->lastTarget_ = root;
    // The hook skips this process, so this is always some other app.
    if (instance_->onOtherAppActivated) instance_->onOtherAppActivated();
}

bool WindowManager::IsArrangeable(HWND hwnd) {
    if (!hwnd || !IsWindow(hwnd) || !IsWindowVisible(hwnd)) return false;

    DWORD processId = 0;
    GetWindowThreadProcessId(hwnd, &processId);
    if (processId == GetCurrentProcessId()) return false;
    if (GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) return false;

    wchar_t className[64] = {};
    GetClassNameW(hwnd, className, 64);
    static const wchar_t* const kShellClasses[] = {
        L"Progman", L"WorkerW", L"Shell_TrayWnd", L"Shell_SecondaryTrayWnd", L"NotifyIconOverflowWindow",
        L"Windows.UI.Core.CoreWindow", L"XamlExplorerHostIslandWindow",
    };
    for (const wchar_t* shellClass : kShellClasses) {
        if (wcscmp(className, shellClass) == 0) return false;
    }

    DWORD cloaked = 0;
    if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) && cloaked) return false;
    return true;
}

HWND WindowManager::TargetWindow() {
    HWND foreground = GetForegroundWindow();
    HWND root = foreground ? GetAncestor(foreground, GA_ROOT) : nullptr;
    if (IsArrangeable(root)) {
        lastTarget_ = root;
        return root;
    }
    if (lastTarget_ && IsArrangeable(lastTarget_)) return lastTarget_;
    return nullptr;
}

bool WindowManager::PrepareWindow(HWND window, const std::wstring& appName) {
    if (IsHungAppWindow(window)) {
        SetMessage(appName + L" is not responding.");
        return false;
    }
    if (IsIconic(window) || IsZoomed(window)) {
        ShowWindow(window, SW_RESTORE);
    }
    return true;
}

bool WindowManager::BeginAnimation(HWND window, const RECT& visibleTarget, bool resizes, const std::wstring& appName,
                                   const std::wstring& failureVerb) {
    RECT windowRect{}, visible{};
    if (!GetWindowRect(window, &windowRect) || !VisibleFrame(window, visible)) {
        SetMessage(L"No available screen was found.");
        return false;
    }

    Animation next;
    next.window = window;
    next.start = visible;
    next.target = visibleTarget;
    next.resizes = resizes;
    next.insets = RECT{visible.left - windowRect.left, visible.top - windowRect.top, windowRect.right - visible.right,
                       windowRect.bottom - visible.bottom};
    next.startedAt = GetTickCount64();

    if (EqualRect(&visible, &visibleTarget)) return true;

    // The first step is synchronous so a refusal is reported; an app that refuses it
    // will refuse the rest too. Later steps are asynchronous so a slow app never stalls
    // Space.
    double progress = EaseOutCubic(static_cast<double>(kAnimationIntervalMs) / kAnimationDurationMs);
    RECT frame = Interpolate(next.start, next.target, progress);
    UINT flags = SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER | (resizes ? 0 : SWP_NOSIZE);
    SetLastError(ERROR_SUCCESS);
    if (!SetWindowPos(window, nullptr, frame.left - next.insets.left, frame.top - next.insets.top,
                      Width(frame) + next.insets.left + next.insets.right,
                      Height(frame) + next.insets.top + next.insets.bottom, flags)) {
        DWORD error = GetLastError();
        if (error == ERROR_ACCESS_DENIED) {
            SetMessage(appName + L" is running as administrator, so Space cannot " + failureVerb +
                       L" its windows unless Space runs as administrator too.");
        } else {
            SetMessage(appName + L" does not allow " + failureVerb + L" this window (" +
                       HResultMessage(HRESULT_FROM_WIN32(error)) + L").");
        }
        return false;
    }

    // Newer layout commands replace the steps still queued for older ones.
    animation_ = next;
    if (timerWindow_) SetTimer(timerWindow_, kAnimationTimerId, kAnimationIntervalMs, nullptr);
    return true;
}

void WindowManager::HandleTimer() {
    Animation& a = animation_;
    if (!a.window || !IsWindow(a.window)) {
        KillTimer(timerWindow_, kAnimationTimerId);
        a.window = nullptr;
        return;
    }

    double linear = std::min(1.0, static_cast<double>(GetTickCount64() - a.startedAt) / kAnimationDurationMs);
    RECT frame = Interpolate(a.start, a.target, EaseOutCubic(linear));
    UINT flags = SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_ASYNCWINDOWPOS | (a.resizes ? 0 : SWP_NOSIZE);
    SetWindowPos(a.window, nullptr, frame.left - a.insets.left, frame.top - a.insets.top,
                 Width(frame) + a.insets.left + a.insets.right, Height(frame) + a.insets.top + a.insets.bottom, flags);

    if (linear >= 1.0) {
        KillTimer(timerWindow_, kAnimationTimerId);
        a.window = nullptr;
    }
}

void WindowManager::Apply(WindowLayoutMode mode) {
    HWND window = TargetWindow();
    if (!window) {
        SetMessage(L"No frontmost app was found.");
        return;
    }
    std::wstring appName = AppNameForWindow(window);
    if (!PrepareWindow(window, appName)) return;

    RECT workArea{};
    if (!WorkAreaForWindow(window, workArea)) {
        SetMessage(L"No available screen was found.");
        return;
    }

    RECT target = layout::TargetFrame(mode, workArea);
    if (BeginAnimation(window, target, true, appName, L"adjusting")) {
        SetMessage(std::wstring(L"Applied ") + LayoutTitle(mode) + L" to " + appName + L".");
    }
}

void WindowManager::Move(WindowMovePosition position) {
    HWND window = TargetWindow();
    if (!window) {
        SetMessage(L"No frontmost app was found.");
        return;
    }
    std::wstring appName = AppNameForWindow(window);
    if (!PrepareWindow(window, appName)) return;

    RECT workArea{}, current{};
    if (!WorkAreaForWindow(window, workArea) || !VisibleFrame(window, current)) {
        SetMessage(L"No available screen was found.");
        return;
    }

    RECT target = layout::TargetFrame(position, current, workArea);
    if (BeginAnimation(window, target, false, appName, L"moving")) {
        SetMessage(L"Moved " + appName + L" to " + PositionTitle(position) + L".");
    }
}

void WindowManager::ToggleMaximize() {
    HWND window = TargetWindow();
    if (!window) {
        SetMessage(L"No frontmost app was found.");
        return;
    }
    std::wstring appName = AppNameForWindow(window);
    if (IsHungAppWindow(window)) {
        SetMessage(appName + L" is not responding.");
        return;
    }

    LONG_PTR style = GetWindowLongPtrW(window, GWL_STYLE);
    if (!(style & (WS_MAXIMIZEBOX | WS_THICKFRAME))) {
        SetMessage(appName + L" does not allow maximizing this window.");
        return;
    }

    bool maximize = !IsZoomed(window);
    ShowWindowAsync(window, maximize ? SW_MAXIMIZE : SW_RESTORE);
    SetMessage(std::wstring(maximize ? L"Maximized " : L"Restored ") + appName + L".");
}

void WindowManager::SetMessage(std::wstring message) {
    lastMessage_ = std::move(message);
    if (onChange) onChange();
}

}  // namespace space
