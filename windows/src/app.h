// Purpose: Owns the long-lived services and the hidden message window, and wires global
// shortcuts to clipboard, window, lock, capture and recording actions.

#pragma once

#include "common.h"
#include "settings.h"

#include <memory>

namespace space {

class CaptureService;
class ClipboardStore;
class HotKeyManager;
class LoginItemService;
class MainWindow;
class RecordingService;
class TrayController;
class WindowManager;

class App {
public:
    static App& Instance();

    int Run(HINSTANCE instance);

    ClipboardStore& Clipboard() { return *clipboard_; }
    HotKeyManager& HotKeys() { return *hotKeys_; }
    WindowManager& Windows() { return *windows_; }
    CaptureService& Capture() { return *capture_; }
    RecordingService& Recording() { return *recording_; }
    LoginItemService& LoginItem() { return *loginItem_; }

    // While a capture is on screen the panel must not appear over it.
    bool IsPresentationSuppressed() const { return presentationSuppressed_; }
    // While a dialog of ours is up, the panel losing focus to it must not hide it.
    bool IsShowingModal() const { return modalDepth_ > 0; }

    void OpenPanel();
    bool HidePanel();
    // Gives the keyboard back to `target` and pastes into it.
    void PasteInto(HWND target);
    void Quit();

private:
    App() = default;

    static LRESULT CALLBACK MessageProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
    LRESULT HandleMessage(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
    void ConfigureHotKeys();
    void HandleTimer(UINT_PTR id);
    void StateChanged();
    void SendPasteShortcut();

    static constexpr UINT_PTR kPasteTimerId = 0x5501;

    HWND messageWindow_ = nullptr;
    UINT taskbarCreatedMessage_ = 0;
    bool presentationSuppressed_ = false;
    int modalDepth_ = 0;
    bool quitting_ = false;

    Settings settings_;
    std::unique_ptr<ClipboardStore> clipboard_;
    std::unique_ptr<HotKeyManager> hotKeys_;
    std::unique_ptr<WindowManager> windows_;
    std::unique_ptr<CaptureService> capture_;
    std::unique_ptr<RecordingService> recording_;
    std::unique_ptr<LoginItemService> loginItem_;
    std::unique_ptr<TrayController> tray_;
    std::unique_ptr<MainWindow> mainWindow_;
};

}  // namespace space
