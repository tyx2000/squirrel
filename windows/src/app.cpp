// Purpose: Implements app start-up, the hidden message window that receives hotkeys,
// clipboard and tray notifications, and the shortcut wiring.

#include "app.h"

#include "capture.h"
#include "clipboard_store.h"
#include "hotkeys.h"
#include "login_item.h"
#include "main_window.h"
#include "recording.h"
#include "tray.h"
#include "window_manager.h"

namespace space {

namespace {

constexpr char kHasLaunchedKey[] = "hasPresentedAtFirstLaunch";
// The panel is hidden first, so the target window needs a moment to take the keyboard
// back before the keystroke arrives.
constexpr UINT kFocusHandoverDelayMs = 120;

}  // namespace

App& App::Instance() {
    static App app;
    return app;
}

int App::Run(HINSTANCE instance) {
    WNDCLASSEXW windowClass{sizeof(windowClass)};
    windowClass.lpfnWndProc = &App::MessageProc;
    windowClass.hInstance = instance;
    windowClass.lpszClassName = kMessageWindowClass;
    if (!RegisterClassExW(&windowClass)) return 1;

    // A hidden top-level window rather than a message-only one: TaskbarCreated is
    // broadcast, and broadcasts skip message-only windows.
    messageWindow_ = CreateWindowExW(WS_EX_TOOLWINDOW, kMessageWindowClass, kAppName, WS_POPUP, 0, 0, 0, 0, nullptr,
                                     nullptr, instance, this);
    if (!messageWindow_) return 1;
    taskbarCreatedMessage_ = RegisterWindowMessageW(L"TaskbarCreated");
    ChangeWindowMessageFilterEx(messageWindow_, taskbarCreatedMessage_, MSGFLT_ALLOW, nullptr);

    settings_.Load();

    clipboard_ = std::make_unique<ClipboardStore>();
    clipboard_->onChange = [this] { StateChanged(); };
    clipboard_->StartMonitoring(messageWindow_);

    hotKeys_ = std::make_unique<HotKeyManager>(settings_);
    hotKeys_->onChange = [this] { StateChanged(); };

    windows_ = std::make_unique<WindowManager>();
    windows_->Attach(messageWindow_);
    windows_->onChange = [this] { StateChanged(); };
    // The panel's own focus is not a reliable signal: after one of our dialogs it can be
    // visible without being active, and then never loses activation. Another app coming
    // forward is.
    windows_->onOtherAppActivated = [this] {
        if (!presentationSuppressed_ && modalDepth_ == 0) HidePanel();
    };

    capture_ = std::make_unique<CaptureService>(
        *clipboard_, [this](bool suppressed) { presentationSuppressed_ = suppressed; }, [this] { return HidePanel(); });
    capture_->Attach(messageWindow_);
    capture_->onChange = [this] { StateChanged(); };

    recording_ = std::make_unique<RecordingService>([this] { return HidePanel(); });
    recording_->Attach(messageWindow_);
    recording_->onChange = [this] { StateChanged(); };
    recording_->onModal = [this](bool showing) { modalDepth_ += showing ? 1 : -1; };

    loginItem_ = std::make_unique<LoginItemService>();
    loginItem_->onChange = [this] { StateChanged(); };
    loginItem_->onOpeningSettings = [this] { HidePanel(); };

    tray_ = std::make_unique<TrayController>(*recording_);
    tray_->onOpen = [this] { OpenPanel(); };
    tray_->onStop = [this] { recording_->StopActive(); };
    tray_->onQuit = [this] { Quit(); };
    tray_->Install(messageWindow_);

    mainWindow_ = std::make_unique<MainWindow>(*this);

    ConfigureHotKeys();
    hotKeys_->Attach(messageWindow_);

    // After the first run the app starts quietly in the notification area, which matters
    // because it can open at sign-in: otherwise the panel would appear every time.
    if (!settings_.Flag(kHasLaunchedKey)) {
        settings_.SetFlag(kHasLaunchedKey, true);
        OpenPanel();
    }
    ++modalDepth_;
    loginItem_->PromptIfNeeded(settings_);
    --modalDepth_;
    // Give the keyboard back to the panel the prompt appeared over.
    if (mainWindow_->IsVisible()) mainWindow_->Show();

    MSG message;
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    recording_->Shutdown();
    tray_->Remove();
    clipboard_->StopMonitoring();
    mainWindow_.reset();
    tray_.reset();
    capture_.reset();
    recording_.reset();
    hotKeys_.reset();
    windows_.reset();
    loginItem_.reset();
    clipboard_.reset();
    return static_cast<int>(message.wParam);
}

void App::ConfigureHotKeys() {
    HotKeyManager& keys = *hotKeys_;
    keys.SetAction(HotKeyCommand::ClipboardWindow, [this] { OpenPanel(); });
    keys.SetAction(HotKeyCommand::LeftHalf, [this] { windows_->Apply(WindowLayoutMode::LeftHalf); });
    keys.SetAction(HotKeyCommand::RightHalf, [this] { windows_->Apply(WindowLayoutMode::RightHalf); });
    keys.SetAction(HotKeyCommand::CenterHalf, [this] { windows_->Apply(WindowLayoutMode::CenterHalf); });
    keys.SetAction(HotKeyCommand::Fullscreen, [this] { windows_->ToggleMaximize(); });
    keys.SetAction(HotKeyCommand::MoveLeft, [this] { windows_->Move(WindowMovePosition::Left); });
    keys.SetAction(HotKeyCommand::MoveCenter, [this] { windows_->Move(WindowMovePosition::Center); });
    keys.SetAction(HotKeyCommand::MoveRight, [this] { windows_->Move(WindowMovePosition::Right); });
    keys.SetAction(HotKeyCommand::LockScreen, [this] {
        if (!LockWorkStation()) {
            hotKeys_->ReportActionFailure(
                L"Lock Screen shortcut was triggered, but Windows did not accept the lock request.",
                HotKeyCommand::LockScreen);
        }
    });
    keys.SetAction(HotKeyCommand::CaptureArea, [this] {
        capture_->StartAreaCapture([this](const std::wstring& message) {
            hotKeys_->ReportActionFailure(message, HotKeyCommand::CaptureArea);
        });
    });
    keys.SetAction(HotKeyCommand::RecordWindow, [this] {
        recording_->Toggle([this](const std::wstring& message) {
            hotKeys_->ReportActionFailure(message, HotKeyCommand::RecordWindow);
        });
    });
}

void App::OpenPanel() {
    if (mainWindow_) mainWindow_->Show();
}

bool App::HidePanel() {
    return mainWindow_ && mainWindow_->Hide();
}

void App::PasteInto(HWND target) {
    if (!target || !IsWindow(target)) return;
    // Still the foreground process, so Windows lets this hand the foreground back.
    SetForegroundWindow(target);
    SetTimer(messageWindow_, kPasteTimerId, kFocusHandoverDelayMs, nullptr);
}

void App::SendPasteShortcut() {
    std::vector<INPUT> inputs;
    auto key = [&inputs](WORD virtualKey, bool up) {
        INPUT input{};
        input.type = INPUT_KEYBOARD;
        input.ki.wVk = virtualKey;
        input.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
        inputs.push_back(input);
    };
    // A modifier still held from opening the panel would turn Ctrl+V into something else.
    for (WORD held : {static_cast<WORD>(VK_MENU), static_cast<WORD>(VK_LWIN), static_cast<WORD>(VK_RWIN),
                      static_cast<WORD>(VK_SHIFT)}) {
        if (GetAsyncKeyState(held) < 0) key(held, true);
    }
    key(VK_CONTROL, false);
    key('V', false);
    key('V', true);
    key(VK_CONTROL, true);
    SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
}

void App::Quit() {
    if (quitting_) return;
    quitting_ = true;
    HidePanel();
    if (recording_) recording_->Shutdown();
    DestroyWindow(messageWindow_);
}

void App::StateChanged() {
    if (mainWindow_) mainWindow_->Refresh();
    if (tray_) tray_->RecordingStateChanged();
}

void App::HandleTimer(UINT_PTR id) {
    if (id == ClipboardStore::kRetryTimerId) {
        clipboard_->HandleRetryTimer();
    } else if (id == WindowManager::kAnimationTimerId) {
        windows_->HandleTimer();
    } else if (id == TrayController::kTickTimerId) {
        tray_->HandleTick();
    } else if (id == kPasteTimerId) {
        KillTimer(messageWindow_, kPasteTimerId);
        SendPasteShortcut();
    } else if (capture_) {
        capture_->HandleTimer(id);
    }
}

LRESULT CALLBACK App::MessageProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_NCCREATE) {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto* self = reinterpret_cast<App*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (!self) return DefWindowProcW(hwnd, message, wParam, lParam);
    return self->HandleMessage(hwnd, message, wParam, lParam);
}

LRESULT App::HandleMessage(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == taskbarCreatedMessage_ && taskbarCreatedMessage_ != 0) {
        if (tray_) tray_->HandleTaskbarCreated();
        return 0;
    }

    switch (message) {
        case WM_HOTKEY:
            if (hotKeys_) hotKeys_->HandleHotKey(wParam);
            return 0;
        case WM_CLIPBOARDUPDATE:
            if (clipboard_) clipboard_->HandleClipboardUpdate();
            return 0;
        case WM_TIMER:
            HandleTimer(wParam);
            return 0;
        case WM_APP_OPEN_PANEL:
            OpenPanel();
            return 0;
        case WM_APP_TRAY:
            if (tray_) tray_->HandleCallback(wParam, lParam);
            return 0;
        case WM_APP_RECORDING_EVENT:
            if (recording_) recording_->HandleEvent(wParam, lParam);
            else delete reinterpret_cast<std::wstring*>(lParam);
            return 0;
        case WM_QUERYENDSESSION:
            return TRUE;
        case WM_ENDSESSION:
            // Signing out: write out a recording in progress rather than lose it.
            if (wParam && recording_) recording_->Shutdown();
            return 0;
        case WM_CLOSE:
            // Sent by the installer and uninstaller to close a running copy.
            Quit();
            return 0;
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

}  // namespace space
