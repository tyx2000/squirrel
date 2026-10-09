// Purpose: Implements shortcut defaults, display names, persistence and RegisterHotKey
// registration with duplicate-press suppression.

#include "hotkeys.h"

#include "json.h"
#include "settings.h"

namespace space {

namespace {

constexpr ULONGLONG kDuplicateEventIntervalMs = 180;
constexpr int kHotKeyIdBase = 1;

constexpr UINT kCtrlAlt = MOD_CONTROL | MOD_ALT;
constexpr UINT kCtrlAltWin = MOD_CONTROL | MOD_ALT | MOD_WIN;
constexpr UINT kCtrlAltShift = MOD_CONTROL | MOD_ALT | MOD_SHIFT;

}  // namespace

const std::array<HotKeyCommand, 8> kStandaloneCommands = {
    HotKeyCommand::ClipboardWindow, HotKeyCommand::LeftHalf,   HotKeyCommand::RightHalf,
    HotKeyCommand::CenterHalf,      HotKeyCommand::Fullscreen, HotKeyCommand::LockScreen,
    HotKeyCommand::CaptureArea,     HotKeyCommand::RecordWindow,
};

const std::array<HotKeyCommand, 3> kMoveCommands = {
    HotKeyCommand::MoveLeft,
    HotKeyCommand::MoveCenter,
    HotKeyCommand::MoveRight,
};

const wchar_t* HotKeyCommandTitle(HotKeyCommand command) {
    switch (command) {
        case HotKeyCommand::ClipboardWindow: return L"Show Clipboard History";
        case HotKeyCommand::LeftHalf: return L"Window Left Two Thirds";
        case HotKeyCommand::RightHalf: return L"Window Right Two Thirds";
        case HotKeyCommand::CenterHalf: return L"Window Center Two Thirds";
        case HotKeyCommand::Fullscreen: return L"Toggle Maximize";
        case HotKeyCommand::MoveLeft: return L"Left";
        case HotKeyCommand::MoveCenter: return L"Center";
        case HotKeyCommand::MoveRight: return L"Right";
        case HotKeyCommand::LockScreen: return L"Lock Screen";
        case HotKeyCommand::CaptureArea: return L"Capture Area";
        case HotKeyCommand::RecordWindow: return L"Record Screen";
        case HotKeyCommand::Count: break;
    }
    return L"";
}

// The same keys the Mac build stores, so a settings file reads the same on both.
const char* HotKeyCommandKey(HotKeyCommand command) {
    switch (command) {
        case HotKeyCommand::ClipboardWindow: return "clipboardWindow";
        case HotKeyCommand::LeftHalf: return "leftHalf";
        case HotKeyCommand::RightHalf: return "rightHalf";
        case HotKeyCommand::CenterHalf: return "centerHalf";
        case HotKeyCommand::Fullscreen: return "fullscreen";
        case HotKeyCommand::MoveLeft: return "moveLeft";
        case HotKeyCommand::MoveCenter: return "moveCenter";
        case HotKeyCommand::MoveRight: return "moveRight";
        case HotKeyCommand::LockScreen: return "lockScreen";
        case HotKeyCommand::CaptureArea: return "captureArea";
        case HotKeyCommand::RecordWindow: return "recordWindow";
        case HotKeyCommand::Count: break;
    }
    return "";
}

// The Mac defaults with Control as Ctrl, Option as Alt and Command as Win.
HotKeyCombo DefaultShortcut(HotKeyCommand command) {
    switch (command) {
        case HotKeyCommand::ClipboardWindow: return {'V', kCtrlAlt};
        case HotKeyCommand::LeftHalf: return {VK_LEFT, kCtrlAltWin};
        case HotKeyCommand::RightHalf: return {VK_RIGHT, kCtrlAltWin};
        case HotKeyCommand::CenterHalf: return {VK_DOWN, kCtrlAltWin};
        case HotKeyCommand::Fullscreen: return {'F', kCtrlAltWin};
        case HotKeyCommand::MoveLeft: return {VK_LEFT, kCtrlAltShift};
        case HotKeyCommand::MoveCenter: return {VK_DOWN, kCtrlAltShift};
        case HotKeyCommand::MoveRight: return {VK_RIGHT, kCtrlAltShift};
        case HotKeyCommand::LockScreen: return {'L', kCtrlAltWin};
        case HotKeyCommand::CaptureArea: return {'C', kCtrlAltWin};
        case HotKeyCommand::RecordWindow: return {'R', kCtrlAltWin};
        case HotKeyCommand::Count: break;
    }
    return {};
}

std::wstring KeyDisplayName(UINT virtualKey) {
    switch (virtualKey) {
        case VK_LEFT: return L"←";
        case VK_RIGHT: return L"→";
        case VK_UP: return L"↑";
        case VK_DOWN: return L"↓";
        case VK_SPACE: return L"Space";
        case VK_RETURN: return L"Enter";
        case VK_ESCAPE: return L"Esc";
        case VK_TAB: return L"Tab";
        case VK_BACK: return L"Backspace";
        case VK_DELETE: return L"Delete";
        case VK_INSERT: return L"Insert";
        case VK_HOME: return L"Home";
        case VK_END: return L"End";
        case VK_PRIOR: return L"Page Up";
        case VK_NEXT: return L"Page Down";
        case VK_SNAPSHOT: return L"Print Screen";
        case VK_PAUSE: return L"Pause";
        default: break;
    }
    if ((virtualKey >= 'A' && virtualKey <= 'Z') || (virtualKey >= '0' && virtualKey <= '9')) {
        return std::wstring(1, static_cast<wchar_t>(virtualKey));
    }
    if (virtualKey >= VK_F1 && virtualKey <= VK_F24) {
        return FormatString(L"F%u", virtualKey - VK_F1 + 1);
    }
    if (virtualKey >= VK_NUMPAD0 && virtualKey <= VK_NUMPAD9) {
        return FormatString(L"Num %u", virtualKey - VK_NUMPAD0);
    }

    UINT scanCode = MapVirtualKeyW(virtualKey, MAPVK_VK_TO_VSC);
    if (scanCode != 0) {
        wchar_t name[64] = {};
        if (GetKeyNameTextW(static_cast<LONG>(scanCode << 16), name, 64) > 0) return name;
    }
    return FormatString(L"Key %u", virtualKey);
}

std::wstring HotKeyCombo::DisplayString() const {
    std::wstring output;
    if (modifiers & MOD_CONTROL) output += L"Ctrl+";
    if (modifiers & MOD_ALT) output += L"Alt+";
    if (modifiers & MOD_SHIFT) output += L"Shift+";
    if (modifiers & MOD_WIN) output += L"Win+";
    return output + KeyDisplayName(virtualKey);
}

HotKeyManager::HotKeyManager(Settings& settings) : settings_(settings) {
    Load();
}

HotKeyManager::~HotKeyManager() {
    UnregisterAll();
}

void HotKeyManager::Attach(HWND window) {
    window_ = window;
    RegisterAll();
}

void HotKeyManager::SetAction(HotKeyCommand command, std::function<void()> action) {
    actions_[static_cast<size_t>(command)] = std::move(action);
}

HotKeyCombo HotKeyManager::Shortcut(HotKeyCommand command) const {
    auto found = shortcuts_.find(command);
    return found != shortcuts_.end() ? found->second : DefaultShortcut(command);
}

HotKeyManager::Assignment HotKeyManager::Assigning(HotKeyCombo combo, HotKeyCommand command,
                                                   const std::map<HotKeyCommand, HotKeyCombo>& shortcuts) {
    auto current = [&](HotKeyCommand candidate) {
        auto found = shortcuts.find(candidate);
        return found != shortcuts.end() ? found->second : DefaultShortcut(candidate);
    };

    Assignment result{shortcuts, std::nullopt};
    for (size_t i = 0; i < kHotKeyCommandCount; ++i) {
        auto other = static_cast<HotKeyCommand>(i);
        if (other != command && current(other) == combo) {
            result.shortcuts[other] = current(command);
            result.displaced = other;
            break;
        }
    }
    result.shortcuts[command] = combo;
    return result;
}

void HotKeyManager::UpdateShortcut(HotKeyCombo combo, HotKeyCommand command) {
    HotKeyCombo previous = Shortcut(command);
    Assignment result = Assigning(combo, command, shortcuts_);
    shortcuts_ = std::move(result.shortcuts);
    if (result.displaced) {
        lastEventMessage_ = combo.DisplayString() + L" was used by " + HotKeyCommandTitle(*result.displaced) +
                            L", which now uses " + previous.DisplayString() + L".";
    }

    Save();
    if (!suspended_) RegisterAll();
    Changed();
}

void HotKeyManager::Suspend() {
    suspended_ = true;
    UnregisterAll();
}

void HotKeyManager::Resume() {
    suspended_ = false;
    RegisterAll();
    Changed();
}

void HotKeyManager::ReportActionFailure(const std::wstring& message, std::optional<HotKeyCommand> command) {
    if (command && lastPerformedCommand_ != command) return;
    lastEventMessage_ = message;
    Changed();
}

void HotKeyManager::HandleHotKey(WPARAM id) {
    int index = static_cast<int>(id) - kHotKeyIdBase;
    if (index < 0 || index >= static_cast<int>(kHotKeyCommandCount)) return;
    auto command = static_cast<HotKeyCommand>(index);

    ULONGLONG now = GetTickCount64();
    if (lastPerformedCommand_ == command && now - lastPerformedAt_ < kDuplicateEventIntervalMs) return;
    lastPerformedCommand_ = command;
    lastPerformedAt_ = now;

    auto& action = actions_[static_cast<size_t>(index)];
    if (!action) {
        lastEventMessage_ = std::wstring(HotKeyCommandTitle(command)) +
                            L" shortcut was triggered, but its action is not initialized.";
        Changed();
        return;
    }

    if (!lastEventMessage_.empty()) {
        lastEventMessage_.clear();
        Changed();
    }
    action();
}

void HotKeyManager::RegisterAll() {
    UnregisterAll();
    if (!window_) return;

    std::wstring failures;
    for (size_t i = 0; i < kHotKeyCommandCount; ++i) {
        auto command = static_cast<HotKeyCommand>(i);
        HotKeyCombo combo = Shortcut(command);
        if (RegisterHotKey(window_, kHotKeyIdBase + static_cast<int>(i), combo.modifiers | MOD_NOREPEAT,
                           combo.virtualKey)) {
            registered_[i] = true;
        } else {
            if (!failures.empty()) failures += L", ";
            failures += FormatString(L"%ls (%ls)", HotKeyCommandTitle(command), combo.DisplayString().c_str());
        }
    }

    registrationError_ = failures.empty()
        ? std::wstring()
        : L"Shortcut registration failed for " + failures + L". It may conflict with Windows or another app.";
}

void HotKeyManager::UnregisterAll() {
    for (size_t i = 0; i < kHotKeyCommandCount; ++i) {
        if (registered_[i] && window_) UnregisterHotKey(window_, kHotKeyIdBase + static_cast<int>(i));
        registered_[i] = false;
    }
}

void HotKeyManager::Load() {
    for (size_t i = 0; i < kHotKeyCommandCount; ++i) {
        auto command = static_cast<HotKeyCommand>(i);
        shortcuts_[command] = DefaultShortcut(command);
    }

    const json::Value* stored = settings_.Shortcuts();
    if (!stored || !stored->IsObject()) return;

    for (size_t i = 0; i < kHotKeyCommandCount; ++i) {
        auto command = static_cast<HotKeyCommand>(i);
        const json::Value* entry = stored->Find(HotKeyCommandKey(command));
        if (!entry || !entry->IsObject()) continue;
        const json::Value* key = entry->Find("keyCode");
        const json::Value* modifiers = entry->Find("modifiers");
        if (!key || !modifiers || !key->IsNumber() || !modifiers->IsNumber()) continue;

        HotKeyCombo combo{static_cast<UINT>(key->AsNumber()),
                          static_cast<UINT>(modifiers->AsNumber()) & (MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN)};
        if (combo.virtualKey == 0 || combo.virtualKey > 0xFE || !combo.IsSafeGlobalShortcut()) continue;
        shortcuts_[command] = combo;
    }
}

void HotKeyManager::Save() {
    json::Value object = json::Value::Object();
    for (const auto& [command, combo] : shortcuts_) {
        json::Value entry = json::Value::Object();
        entry.Set("keyCode", json::Value::Number(combo.virtualKey));
        entry.Set("modifiers", json::Value::Number(combo.modifiers));
        object.Set(HotKeyCommandKey(command), std::move(entry));
    }
    settings_.SetShortcuts(std::move(object));
}

void HotKeyManager::Changed() {
    if (onChange) onChange();
}

}  // namespace space
