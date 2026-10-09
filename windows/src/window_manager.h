// Purpose: Arranges the last active app window: two-thirds layouts, left/center/right moves
// and maximize toggling, with a short eased animation.

#pragma once

#include "common.h"

namespace space {

enum class WindowLayoutMode { LeftHalf, RightHalf, CenterHalf };
enum class WindowMovePosition { Left, Center, Right };

// Shortcut names promise two-thirds placement; keeping the math here keeps labels and
// window movement from drifting into different behaviour. Rects are visible frames.
namespace layout {
RECT TargetFrame(WindowLayoutMode mode, const RECT& workArea);
RECT TargetFrame(WindowMovePosition position, const RECT& currentFrame, const RECT& workArea);
}  // namespace layout

class WindowManager {
public:
    static constexpr UINT_PTR kAnimationTimerId = 0x5201;

    WindowManager();
    ~WindowManager();

    // The window that receives the animation timer.
    void Attach(HWND timerWindow);

    void Apply(WindowLayoutMode mode);
    void ToggleMaximize();
    void Move(WindowMovePosition position);
    void HandleTimer();

    // The foreground app window, or the last one if a shell surface (the taskbar, the
    // desktop) or Space itself is in front.
    HWND TargetWindow();

    const std::wstring& LastMessage() const { return lastMessage_; }
    std::function<void()> onChange;
    // Another app's window came to the foreground.
    std::function<void()> onOtherAppActivated;

private:
    struct Animation {
        HWND window = nullptr;
        RECT start{};
        RECT target{};
        RECT insets{};  // invisible resize borders around the visible frame
        bool resizes = false;
        ULONGLONG startedAt = 0;
    };

    static void CALLBACK ForegroundChanged(HWINEVENTHOOK hook, DWORD event, HWND hwnd, LONG objectId, LONG childId,
                                           DWORD thread, DWORD time);
    static bool IsArrangeable(HWND hwnd);

    // Restores a minimized or maximized window and checks it can be moved; on failure
    // sets lastMessage_ and returns false.
    bool PrepareWindow(HWND window, const std::wstring& appName);
    bool BeginAnimation(HWND window, const RECT& visibleTarget, bool resizes, const std::wstring& appName,
                        const std::wstring& failureVerb);
    void SetMessage(std::wstring message);

    static WindowManager* instance_;
    HWINEVENTHOOK hook_ = nullptr;
    HWND timerWindow_ = nullptr;
    HWND lastTarget_ = nullptr;
    Animation animation_;
    std::wstring lastMessage_;
};

std::wstring AppNameForWindow(HWND hwnd);
bool VisibleFrame(HWND hwnd, RECT& frame);

}  // namespace space
