// Purpose: Implements Open at Login through HKCU\...\Run, honouring the Startup apps switch
// that Settings and Task Manager keep under StartupApproved.

#include "login_item.h"

#include "settings.h"

#include <commctrl.h>
#include <shellapi.h>

namespace space {

namespace {

constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kStartupApprovedKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run";
constexpr char kHasPromptedKey[] = "hasPromptedForLoginItem";
constexpr int kOpenAtLoginButton = 100;

std::wstring RunCommand() {
    return L"\"" + ExecutablePath() + L"\"";
}

}  // namespace

LoginItemService::LoginItemService() {
    Refresh();
}

void LoginItemService::Refresh() {
    bool enabled = IsRegistered() && !IsDisabledInStartupApps();
    if (enabled != isEnabled_) {
        isEnabled_ = enabled;
        Changed();
    }
}

void LoginItemService::ClearMessage() {
    lastMessage_.clear();
    Changed();
}

bool LoginItemService::IsRegistered() const {
    DWORD size = 0;
    return RegGetValueW(HKEY_CURRENT_USER, kRunKey, kAppName, RRF_RT_REG_SZ, nullptr, nullptr, &size) == ERROR_SUCCESS;
}

// Settings > Apps > Startup and Task Manager record a switched-off entry as a binary value
// whose first byte is odd.
bool LoginItemService::IsDisabledInStartupApps() const {
    BYTE data[12] = {};
    DWORD size = sizeof(data);
    if (RegGetValueW(HKEY_CURRENT_USER, kStartupApprovedKey, kAppName, RRF_RT_REG_BINARY, nullptr, data, &size) !=
            ERROR_SUCCESS ||
        size == 0) {
        return false;
    }
    return (data[0] & 1) != 0;
}

void LoginItemService::SetEnabled(bool enabled) {
    LSTATUS status = ERROR_SUCCESS;
    if (enabled) {
        std::wstring command = RunCommand();
        status = RegSetKeyValueW(HKEY_CURRENT_USER, kRunKey, kAppName, REG_SZ, command.c_str(),
                                 static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
    } else {
        status = RegDeleteKeyValueW(HKEY_CURRENT_USER, kRunKey, kAppName);
        if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
    }

    lastMessage_ = status == ERROR_SUCCESS
        ? std::wstring()
        : std::wstring(L"Could not ") + (enabled ? L"enable" : L"disable") +
              L" Open at Login: " + HResultMessage(HRESULT_FROM_WIN32(status));

    isEnabled_ = IsRegistered() && !IsDisabledInStartupApps();

    // Once someone has switched the entry off under Startup apps, only that switch can
    // turn it back on.
    if (enabled && status == ERROR_SUCCESS && IsDisabledInStartupApps()) {
        lastMessage_ = L"Open at Login needs to be turned on in Settings > Apps > Startup.";
        if (onOpeningSettings) onOpeningSettings();
        ShellExecuteW(nullptr, L"open", L"ms-settings:startupapps", nullptr, nullptr, SW_SHOWNORMAL);
    }

    Changed();
}

void LoginItemService::PromptIfNeeded(Settings& settings) {
    if (settings.Flag(kHasPromptedKey)) return;
    settings.SetFlag(kHasPromptedKey, true);
    if (IsRegistered()) return;

    TASKDIALOG_BUTTON buttons[] = {
        {kOpenAtLoginButton, L"Open at Login"},
        {IDCANCEL, L"Not Now"},
    };
    TASKDIALOGCONFIG config{};
    config.cbSize = sizeof(config);
    config.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW;
    config.pszWindowTitle = kAppName;
    config.hInstance = GetModuleHandleW(nullptr);
    config.pszMainIcon = TD_INFORMATION_ICON;
    config.pszMainInstruction = L"Open Space at Login?";
    config.pszContent =
        L"Space lives in the notification area. Opening it at sign-in keeps the shortcuts working after a "
        L"restart. You can change this later on the Shortcuts tab.";
    config.pButtons = buttons;
    config.cButtons = ARRAYSIZE(buttons);
    config.nDefaultButton = kOpenAtLoginButton;

    int pressed = 0;
    if (SUCCEEDED(TaskDialogIndirect(&config, &pressed, nullptr, nullptr)) && pressed == kOpenAtLoginButton) {
        SetEnabled(true);
    }
}

void LoginItemService::Changed() {
    if (onChange) onChange();
}

}  // namespace space
