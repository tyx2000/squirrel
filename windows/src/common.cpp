// Purpose: Implements the shared string, file, time, process and focus helpers.

#include "common.h"

#include <objbase.h>
#include <shellscalingapi.h>
#include <shlobj.h>
#include <knownfolders.h>

#include <cstdarg>
#include <cwchar>

namespace space {

std::wstring Utf8ToWide(std::string_view text) {
    if (text.empty()) return {};
    int length = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
    std::wstring result(static_cast<size_t>(length), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), length);
    return result;
}

std::string WideToUtf8(std::wstring_view text) {
    if (text.empty()) return {};
    int length = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    std::string result(static_cast<size_t>(length), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), length, nullptr, nullptr);
    return result;
}

std::wstring FormatString(const wchar_t* format, ...) {
    va_list args;
    va_start(args, format);
    va_list copy;
    va_copy(copy, args);
    int length = _vscwprintf(format, copy);
    va_end(copy);
    std::wstring result;
    if (length > 0) {
        result.resize(static_cast<size_t>(length) + 1);
        _vsnwprintf_s(result.data(), result.size(), _TRUNCATE, format, args);
        result.resize(static_cast<size_t>(length));
    }
    va_end(args);
    return result;
}

bool IsBlank(std::wstring_view text) {
    for (wchar_t c : text) {
        if (!iswspace(c)) return false;
    }
    return true;
}

std::wstring LastPathComponent(const std::wstring& path) {
    size_t slash = path.find_last_of(L"\\/");
    return slash == std::wstring::npos ? path : path.substr(slash + 1);
}

std::wstring ExecutablePath() {
    std::wstring buffer(MAX_PATH, L'\0');
    for (;;) {
        DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
        if (length == 0) return {};
        if (length < buffer.size()) {
            buffer.resize(length);
            return buffer;
        }
        buffer.resize(buffer.size() * 2);
    }
}

static std::wstring KnownFolder(REFKNOWNFOLDERID id) {
    PWSTR path = nullptr;
    std::wstring result;
    if (SUCCEEDED(SHGetKnownFolderPath(id, KF_FLAG_CREATE, nullptr, &path)) && path) {
        result = path;
    }
    CoTaskMemFree(path);
    return result;
}

std::wstring AppDataDirectory() {
    // Local rather than roaming: history images would otherwise travel with the profile.
    std::wstring base = KnownFolder(FOLDERID_LocalAppData);
    if (base.empty()) return {};
    std::wstring directory = base + L"\\" + kAppName;
    EnsureDirectory(directory);
    return directory;
}

std::wstring DownloadsDirectory() {
    std::wstring downloads = KnownFolder(FOLDERID_Downloads);
    if (!downloads.empty()) return downloads;
    return KnownFolder(FOLDERID_Profile) + L"\\Downloads";
}

bool EnsureDirectory(const std::wstring& path) {
    if (path.empty()) return false;
    DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES) return (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    return SHCreateDirectoryExW(nullptr, path.c_str(), nullptr) == ERROR_SUCCESS;
}

bool FileExists(const std::wstring& path) {
    DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES && !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

std::optional<std::vector<uint8_t>> ReadFileBytes(const std::wstring& path) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return std::nullopt;

    std::optional<std::vector<uint8_t>> result;
    LARGE_INTEGER size{};
    if (GetFileSizeEx(file, &size) && size.QuadPart >= 0 && size.QuadPart < (1LL << 31)) {
        std::vector<uint8_t> bytes(static_cast<size_t>(size.QuadPart));
        DWORD read = 0;
        if (bytes.empty() || (ReadFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &read, nullptr) &&
                              read == bytes.size())) {
            result = std::move(bytes);
        }
    }
    CloseHandle(file);
    return result;
}

bool WriteFileAtomic(const std::wstring& path, const void* data, size_t size) {
    std::wstring temporary = path + L".tmp";
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;

    DWORD written = 0;
    bool ok = size == 0 || (WriteFile(file, data, static_cast<DWORD>(size), &written, nullptr) && written == size);
    ok = ok && FlushFileBuffers(file);
    CloseHandle(file);
    if (!ok) {
        DeleteFileW(temporary.c_str());
        return false;
    }
    if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(temporary.c_str());
        return false;
    }
    return true;
}

std::wstring NewUuidString() {
    GUID guid{};
    CoCreateGuid(&guid);
    return FormatString(L"%08lX-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                        static_cast<unsigned long>(guid.Data1), guid.Data2, guid.Data3, guid.Data4[0],
                        guid.Data4[1], guid.Data4[2], guid.Data4[3], guid.Data4[4], guid.Data4[5],
                        guid.Data4[6], guid.Data4[7]);
}

double UnixNow() {
    FILETIME now{};
    GetSystemTimePreciseAsFileTime(&now);
    ULARGE_INTEGER value{};
    value.LowPart = now.dwLowDateTime;
    value.HighPart = now.dwHighDateTime;
    // FILETIME counts 100ns intervals from 1601; Unix time starts 11644473600s later.
    return static_cast<double>(value.QuadPart) / 1e7 - 11644473600.0;
}

static bool LocalTimeFromUnix(double unixSeconds, SYSTEMTIME& local) {
    ULARGE_INTEGER value{};
    value.QuadPart = static_cast<ULONGLONG>((unixSeconds + 11644473600.0) * 1e7);
    FILETIME utc{value.LowPart, value.HighPart};
    SYSTEMTIME utcTime{};
    return FileTimeToSystemTime(&utc, &utcTime) &&
           SystemTimeToTzSpecificLocalTime(nullptr, &utcTime, &local);
}

std::wstring FormatTimestamp(double unixSeconds) {
    SYSTEMTIME local{};
    if (!LocalTimeFromUnix(unixSeconds, local)) return {};
    return FormatString(L"%04u/%02u/%02u %02u:%02u:%02u", local.wYear, local.wMonth, local.wDay, local.wHour,
                        local.wMinute, local.wSecond);
}

std::wstring CompactTimestamp() {
    SYSTEMTIME local{};
    GetLocalTime(&local);
    return FormatString(L"%04u%02u%02u%02u%02u%02u", local.wYear, local.wMonth, local.wDay, local.wHour,
                        local.wMinute, local.wSecond);
}

static std::wstring VersionString(const std::vector<uint8_t>& info, const wchar_t* name) {
    struct Translation {
        WORD language;
        WORD codePage;
    };
    Translation* translations = nullptr;
    UINT length = 0;
    std::vector<std::wstring> candidates;
    if (VerQueryValueW(info.data(), L"\\VarFileInfo\\Translation", reinterpret_cast<void**>(&translations), &length)) {
        for (UINT i = 0; i < length / sizeof(Translation); ++i) {
            candidates.push_back(FormatString(L"\\StringFileInfo\\%04x%04x\\%ls", translations[i].language,
                                              translations[i].codePage, name));
        }
    }
    candidates.push_back(FormatString(L"\\StringFileInfo\\040904b0\\%ls", name));
    candidates.push_back(FormatString(L"\\StringFileInfo\\040904e4\\%ls", name));

    for (const auto& query : candidates) {
        wchar_t* value = nullptr;
        UINT valueLength = 0;
        if (VerQueryValueW(info.data(), query.c_str(), reinterpret_cast<void**>(&value), &valueLength) &&
            value && valueLength > 1) {
            std::wstring text(value);
            if (!IsBlank(text)) return text;
        }
    }
    return {};
}

std::wstring ProcessDisplayName(DWORD processId) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, processId);
    if (!process) return {};

    std::wstring path(1024, L'\0');
    DWORD size = static_cast<DWORD>(path.size());
    bool ok = QueryFullProcessImageNameW(process, 0, path.data(), &size);
    CloseHandle(process);
    if (!ok) return {};
    path.resize(size);

    DWORD handle = 0;
    DWORD infoSize = GetFileVersionInfoSizeW(path.c_str(), &handle);
    if (infoSize > 0) {
        std::vector<uint8_t> info(infoSize);
        if (GetFileVersionInfoW(path.c_str(), 0, infoSize, info.data())) {
            std::wstring description = VersionString(info, L"FileDescription");
            if (description.empty()) description = VersionString(info, L"ProductName");
            if (!description.empty()) return description;
        }
    }

    std::wstring name = LastPathComponent(path);
    size_t dot = name.find_last_of(L'.');
    return dot == std::wstring::npos ? name : name.substr(0, dot);
}

float DpiScaleForWindow(HWND hwnd) {
    UINT dpi = hwnd ? GetDpiForWindow(hwnd) : 0;
    if (dpi == 0) dpi = GetDpiForSystem();
    return static_cast<float>(dpi) / 96.0f;
}

float DpiScaleForMonitor(HMONITOR monitor) {
    UINT dpiX = 96, dpiY = 96;
    if (!monitor || FAILED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY))) {
        dpiX = GetDpiForSystem();
    }
    return static_cast<float>(dpiX) / 96.0f;
}

void BringToForeground(HWND hwnd) {
    if (!hwnd) return;
    if (SetForegroundWindow(hwnd) && GetForegroundWindow() == hwnd) return;

    HWND foreground = GetForegroundWindow();
    DWORD foregroundThread = foreground ? GetWindowThreadProcessId(foreground, nullptr) : 0;
    DWORD currentThread = GetCurrentThreadId();
    if (foregroundThread && foregroundThread != currentThread) {
        AttachThreadInput(currentThread, foregroundThread, TRUE);
        SetForegroundWindow(hwnd);
        SetFocus(hwnd);
        AttachThreadInput(currentThread, foregroundThread, FALSE);
    }
}

std::wstring HResultMessage(HRESULT hr) {
    wchar_t* buffer = nullptr;
    DWORD length = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                                      FORMAT_MESSAGE_IGNORE_INSERTS,
                                  nullptr, static_cast<DWORD>(hr), 0, reinterpret_cast<wchar_t*>(&buffer), 0,
                                  nullptr);
    std::wstring message;
    if (length && buffer) {
        message.assign(buffer, length);
        while (!message.empty() && (message.back() == L'\n' || message.back() == L'\r' || message.back() == L' ' ||
                                    message.back() == L'.')) {
            message.pop_back();
        }
    }
    LocalFree(buffer);
    if (message.empty()) message = FormatString(L"error 0x%08lX", static_cast<unsigned long>(hr));
    return message;
}

}  // namespace space
