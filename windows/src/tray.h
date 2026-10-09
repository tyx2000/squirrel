// Purpose: The notification-area icon that reopens the panel (there is no taskbar button),
// and, while the screen is recorded, a red pill showing the elapsed time that stops the
// recording when clicked.

#pragma once

#include "common.h"

namespace space {

class RecordingService;

class TrayController {
public:
    static constexpr UINT_PTR kTickTimerId = 0x5401;

    explicit TrayController(RecordingService& recording);
    ~TrayController();

    void Install(HWND messageWindow);
    void Remove();

    // WM_APP_TRAY from the notification area.
    void HandleCallback(WPARAM wParam, LPARAM lParam);
    // The shell restarted (TaskbarCreated) and forgot the icon.
    void HandleTaskbarCreated();
    void RecordingStateChanged();
    void HandleTick();

    std::function<void()> onOpen;
    std::function<void()> onStop;
    std::function<void()> onQuit;

private:
    void ShowNormalState();
    void ShowRecordingState();
    void UpdateRecordingIndicator();
    void ShowMenu(POINT anchor);
    void Modify(HICON icon, const std::wstring& tip);
    void RenderPill(const std::wstring& text);

    static LRESULT CALLBACK PillProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);

    RecordingService& recording_;
    HWND messageWindow_ = nullptr;
    HWND pill_ = nullptr;
    bool installed_ = false;
    bool showingRecording_ = false;
    HICON normalIcon_ = nullptr;
    HICON recordingIcon_ = nullptr;
    bool ownsNormalIcon_ = false;
};

std::wstring ElapsedText(ULONGLONG milliseconds);

}  // namespace space
