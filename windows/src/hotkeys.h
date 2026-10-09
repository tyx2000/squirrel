// Purpose: Defines the shortcut commands and key combinations, and registers them as
// system-wide hotkeys with RegisterHotKey.

#pragma once

#include "common.h"

#include <array>
#include <map>

namespace space {

class Settings;

enum class HotKeyCommand {
    ClipboardWindow,
    LeftHalf,
    RightHalf,
    CenterHalf,
    Fullscreen,
    MoveLeft,
    MoveCenter,
    MoveRight,
    LockScreen,
    CaptureArea,
    RecordWindow,
    Count,
};

inline constexpr size_t kHotKeyCommandCount = static_cast<size_t>(HotKeyCommand::Count);

const wchar_t* HotKeyCommandTitle(HotKeyCommand command);
const char* HotKeyCommandKey(HotKeyCommand command);

extern const std::array<HotKeyCommand, 8> kStandaloneCommands;
extern const std::array<HotKeyCommand, 3> kMoveCommands;

// Windows modifier flags as RegisterHotKey takes them: MOD_ALT, MOD_CONTROL, MOD_SHIFT,
// MOD_WIN. On the Mac these were Option, Control, Shift and Command.
struct HotKeyCombo {
    UINT virtualKey = 0;
    UINT modifiers = 0;

    bool operator==(const HotKeyCombo& other) const {
        return virtualKey == other.virtualKey && modifiers == other.modifiers;
    }
    bool operator!=(const HotKeyCombo& other) const { return !(*this == other); }

    // A global hotkey takes its combination away from every app on the system, so it
    // needs Ctrl, Alt, or Win. Shift alone would swallow ordinary typing: Shift-A would
    // stop producing a capital A anywhere.
    bool IsSafeGlobalShortcut() const { return (modifiers & (MOD_CONTROL | MOD_ALT | MOD_WIN)) != 0; }

    std::wstring DisplayString() const;
};

HotKeyCombo DefaultShortcut(HotKeyCommand command);
std::wstring KeyDisplayName(UINT virtualKey);

class HotKeyManager {
public:
    explicit HotKeyManager(Settings& settings);
    ~HotKeyManager();

    // Registers every shortcut against the window whose WM_HOTKEY messages are routed
    // back through HandleHotKey.
    void Attach(HWND window);

    void SetAction(HotKeyCommand command, std::function<void()> action);
    void UpdateShortcut(HotKeyCombo combo, HotKeyCommand command);
    HotKeyCombo Shortcut(HotKeyCommand command) const;

    void Suspend();
    void Resume();

    void ReportActionFailure(const std::wstring& message, std::optional<HotKeyCommand> command = std::nullopt);
    void HandleHotKey(WPARAM id);

    const std::wstring& RegistrationError() const { return registrationError_; }
    const std::wstring& LastEventMessage() const { return lastEventMessage_; }

    std::function<void()> onChange;

    struct Assignment {
        std::map<HotKeyCommand, HotKeyCombo> shortcuts;
        std::optional<HotKeyCommand> displaced;
    };
    // Assigns `combo` to `command`. A combination another command already holds would
    // make its second registration fail and silently disable one of the two, so they
    // swap: the other command takes over `command`'s previous combination.
    static Assignment Assigning(HotKeyCombo combo, HotKeyCommand command,
                                const std::map<HotKeyCommand, HotKeyCombo>& shortcuts);

private:
    void RegisterAll();
    void UnregisterAll();
    void Load();
    void Save();
    void Changed();

    Settings& settings_;
    HWND window_ = nullptr;
    std::map<HotKeyCommand, HotKeyCombo> shortcuts_;
    std::array<std::function<void()>, kHotKeyCommandCount> actions_{};
    std::array<bool, kHotKeyCommandCount> registered_{};
    bool suspended_ = false;
    std::optional<HotKeyCommand> lastPerformedCommand_;
    ULONGLONG lastPerformedAt_ = 0;
    std::wstring registrationError_;
    std::wstring lastEventMessage_;
};

}  // namespace space
