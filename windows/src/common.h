// Purpose: Shared Windows includes, COM helpers, string and path utilities, and the app's
// private window messages.

#pragma once

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <wrl/client.h>

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace space {

// Private messages. The app's hidden message window receives the WM_APP_* ones; the
// others go to the window named beside them.
enum : UINT {
    WM_APP_OPEN_PANEL = WM_APP + 1,       // message window: show the clipboard panel
    WM_APP_TRAY = WM_APP + 2,             // message window: notification-area callback
    WM_APP_RECORDING_EVENT = WM_APP + 3,  // message window: wParam is a RecordingEvent
    WM_APP_THUMBNAIL_READY = WM_APP + 4,  // main window: lParam owns a ThumbnailResult
    WM_APP_SHORTCUT_KEY = WM_APP + 5,     // main window: wParam vk, lParam modifiers
    WM_APP_SHORTCUT_CANCEL = WM_APP + 6,  // main window: a bare Escape while recording
};

inline constexpr wchar_t kAppName[] = L"Space";
inline constexpr wchar_t kMessageWindowClass[] = L"SpaceMessageWindow";

std::wstring Utf8ToWide(std::string_view text);
std::string WideToUtf8(std::wstring_view text);
// printf-style; use %ls for wide strings, which means the same under MSVC and MinGW.
std::wstring FormatString(const wchar_t* format, ...);

bool IsBlank(std::wstring_view text);
std::wstring LastPathComponent(const std::wstring& path);

std::wstring ExecutablePath();
std::wstring AppDataDirectory();      // %LOCALAPPDATA%\Space, created on demand
std::wstring DownloadsDirectory();
bool EnsureDirectory(const std::wstring& path);
std::optional<std::vector<uint8_t>> ReadFileBytes(const std::wstring& path);
// Writes beside the target and renames over it, so a crash never leaves half a file.
bool WriteFileAtomic(const std::wstring& path, const void* data, size_t size);
bool FileExists(const std::wstring& path);

std::wstring NewUuidString();
double UnixNow();
// "yyyy/MM/dd HH:mm:ss" in local time.
std::wstring FormatTimestamp(double unixSeconds);
// "yyyyMMddHHmmss" in local time, for file names.
std::wstring CompactTimestamp();

// The name a person would recognise for a process: its file description, else the
// executable's name without extension.
std::wstring ProcessDisplayName(DWORD processId);

float DpiScaleForWindow(HWND hwnd);
float DpiScaleForMonitor(HMONITOR monitor);

// SetForegroundWindow, falling back to briefly attaching to the foreground thread's
// input queue when Windows refuses the plain call.
void BringToForeground(HWND hwnd);

std::wstring HResultMessage(HRESULT hr);

}  // namespace space

#define SPACE_RETURN_IF_FAILED(expr)        \
    do {                                    \
        HRESULT space_hr_ = (expr);         \
        if (FAILED(space_hr_)) return space_hr_; \
    } while (0)
